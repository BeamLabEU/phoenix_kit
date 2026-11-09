defmodule PhoenixKitWeb.Users.PeoplePanelTest do
  @moduledoc """
  The People panel and what surrounds it: who can see and do what, on the real pages. What
  the panel offers is for show, so every refusal is also tried with params the form never
  offers. The rules themselves are `PhoenixKit.Users.OrganizationLinksTest`.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.OrganizationInvitation
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Users.RelationshipTypes
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @panel "#profile-user-settings-managers-managers"

  setup do
    Settings.update_setting("enable_organization_accounts", "true")

    previous = Application.get_env(:swoosh, :shared_test_process)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:swoosh, :shared_test_process, previous),
        else: Application.delete_env(:swoosh, :shared_test_process)
    end)

    organization = F.organization(%{organization_name: "Oak Trading"})
    buyer = F.role(["users"], organization)
    supplier = F.role(["media"], organization)
    staff = RelationshipTypes.get_type_by_key("staff")

    %{organization: organization, buyer: buyer, supplier: supplier, staff: staff}
  end

  defp acting(organization, link_fun) do
    person = F.person()
    s = F.enter(organization, person, link_fun.(person))

    conn =
      init_test_session(build_conn(), %{
        user_token: s.token,
        pk_session_accounts: [s.root_token, s.token],
        pk_organization_token: s.token
      })

    Map.put(s, :conn, conn)
  end

  defp manager(organization), do: acting(organization, &F.manager(organization, &1))

  defp narrowed_manager(organization, roles),
    do: acting(organization, &F.narrowed_link(organization, &1, roles))

  defp staff_member(organization, staff, roles \\ []) do
    acting(organization, fn person ->
      F.narrowed_link(organization, person, roles, %{relationship_type_uuid: staff.uuid})
    end)
  end

  defp admin_view(organization) do
    {_actor, admin} = F.admin_actor()

    {:ok, view, html} =
      live(
        log_in_user(build_conn(), admin),
        Routes.path("/admin/users/view/#{organization.uuid}?tab=people")
      )

    {view, html, admin}
  end

  defp settings(conn, tab \\ "managers"), do: live(conn, Routes.path("/profile/settings/#{tab}"))

  defp link_of(organization, person_uuid) do
    OrganizationManager
    |> Repo.get_by!(organization_uuid: organization.uuid, user_uuid: person_uuid)
    |> Repo.preload([:relationship_type, role_links: :role])
  end

  defp role_names(link), do: link.role_links |> Enum.map(& &1.role.name) |> Enum.sort()

  describe "the company page" do
    test "has a People tab, and the panel is not on the other tabs", ctx do
      manager(ctx.organization)
      {_actor, admin} = F.admin_actor()
      conn = log_in_user(build_conn(), admin)

      {:ok, view, html} =
        live(conn, Routes.path("/admin/users/view/#{ctx.organization.uuid}"))

      assert html =~ "People"
      refute html =~ "Add person"

      assert render_click(view, "change_tab", %{tab: "people"}) =~ "Add person"
    end

    test "shows each person's type, roles, and who added them and when", ctx do
      added_by = F.person(%{first_name: "Maria", last_name: "Tamm"})
      person = F.person()

      {:ok, _} =
        OrganizationManagers.host_add(ctx.organization.uuid, person.uuid, added_by,
          type: ctx.staff,
          roles: [ctx.buyer]
        )

      manager(ctx.organization)
      {_view, html, _admin} = admin_view(ctx.organization)

      assert html =~ person.email
      assert html =~ "Staff"
      assert html =~ ctx.buyer.name
      assert html =~ "Manager"
      assert html =~ "All roles"
      assert html =~ "Added by Maria Tamm on"
    end

    test "says plainly when someone has no roles", ctx do
      F.narrowed_link(ctx.organization, F.person(), [])
      {_view, html, _admin} = admin_view(ctx.organization)
      assert html =~ "No roles"
    end

    test "shows the translated role name, not the key", ctx do
      data = %{"_primary_language" => "en", "en" => %{"_label" => "Purchasing"}}
      {:ok, role} = Roles.update_role(ctx.buyer, %{data: data})
      F.narrowed_link(ctx.organization, F.person(), [role])

      {_view, html, _admin} = admin_view(ctx.organization)
      assert html =~ "Purchasing"
      refute html =~ role.name
    end

    test "hides the older Members tab from a managed company that has no members", ctx do
      {_view, html, _admin} = admin_view(ctx.organization)
      refute html =~ ">Members<"
      refute html =~ "\nMembers\n"
    end
  end

  describe "adding someone" do
    test "an admin finds a person and picks the level and roles in one dialog", ctx do
      manager(ctx.organization)
      {view, _html, _admin} = admin_view(ctx.organization)
      person = F.person()

      render_click(element(view, "button[phx-click=open_add]"))

      assert view
             |> form("#organization-managers-search", %{query: person.email})
             |> render_change() =~ person.email

      render_click(
        element(view, "button[phx-click=select_person][phx-value-person_uuid='#{person.uuid}']")
      )

      view
      |> form("#organization-managers-invite", %{type: "staff", access: "some"})
      |> render_change()

      html =
        view
        |> form("#organization-managers-invite", %{
          type: "staff",
          access: "some",
          roles: [ctx.buyer.name]
        })
        |> render_submit()

      assert html =~ "Person added"

      link = link_of(ctx.organization, person.uuid)
      assert link.relationship_type.key == "staff"
      assert role_names(link) == [ctx.buyer.name]
    end

    test "defaults to the lowest level", ctx do
      manager(ctx.organization)
      {view, _html, _admin} = admin_view(ctx.organization)

      html = render_click(element(view, "button[phx-click=open_add]"))
      assert html =~ ~s(<option selected="" value="staff">) or html =~ ~s(value="staff" selected)
    end

    test "a manager invites by email and cannot search for people", ctx do
      s = manager(ctx.organization)
      {:ok, view, _} = settings(s.conn)

      html = render_click(element(view, "button[phx-click=open_add]"))
      assert html =~ "Invite someone by email"
      refute html =~ "Find someone with an account"

      view
      |> form("#{@panel}-invite", %{email: "new@example.com", type: "staff", access: "some"})
      |> render_change()

      view
      |> form("#{@panel}-invite", %{
        email: "new@example.com",
        type: "staff",
        access: "some",
        roles: [ctx.supplier.name]
      })
      |> render_submit()

      invitation = Repo.get_by!(OrganizationInvitation, email: "new@example.com")
      assert invitation.relationship_type_uuid == ctx.staff.uuid
      assert invitation.role_uuids == [ctx.supplier.uuid]

      html = render(view)
      assert html =~ "new@example.com"
      assert html =~ "Invited"
      assert html =~ ctx.supplier.name
    end

    test "what was typed survives changing the access", ctx do
      s = manager(ctx.organization)
      {:ok, view, _} = settings(s.conn)
      render_click(element(view, "button[phx-click=open_add]"))

      html =
        view
        |> form("#{@panel}-invite", %{email: "kept@example.com", access: "some"})
        |> render_change()

      assert html =~ ~s(value="kept@example.com")
      assert html =~ ctx.buyer.name
    end
  end

  describe "editing someone" do
    test "changes the level and roles", ctx do
      manager(ctx.organization)
      person = F.person()
      link = F.narrowed_link(ctx.organization, person, [ctx.buyer])
      {view, _html, _admin} = admin_view(ctx.organization)

      render_click(element(view, "button[phx-click=open_edit][phx-value-uuid='#{link.uuid}']"))

      html =
        view
        |> form("#organization-managers-edit", %{
          type: "staff",
          access: "some",
          roles: [ctx.supplier.name]
        })
        |> render_submit()

      assert html =~ "Access updated"

      updated = link_of(ctx.organization, person.uuid)
      assert updated.relationship_type.key == "staff"
      assert role_names(updated) == [ctx.supplier.name]
    end

    test "nobody gets an Edit button for their own link", ctx do
      s = manager(ctx.organization)
      other = F.narrowed_link(ctx.organization, F.person(), [])
      {:ok, view, _} = settings(s.conn)

      refute has_element?(view, "button[phx-click=open_edit][phx-value-uuid='#{s.manager.uuid}']")
      assert has_element?(view, "button[phx-click=open_edit][phx-value-uuid='#{other.uuid}']")
    end

    test "a role the manager may not hand out stays locked and is kept on save", ctx do
      s = narrowed_manager(ctx.organization, [ctx.buyer])
      person = F.person()
      link = F.narrowed_link(ctx.organization, person, [ctx.supplier])
      {:ok, view, _} = settings(s.conn)

      html =
        render_click(element(view, "button[phx-click=open_edit][phx-value-uuid='#{link.uuid}']"))

      assert html =~ "Only someone who has this role can change it."

      render_submit(element(view, "#{@panel}-edit"), %{
        "type" => "manager",
        "access" => "some",
        "roles" => [ctx.supplier.name, ctx.buyer.name]
      })

      assert role_names(link_of(ctx.organization, person.uuid)) ==
               Enum.sort([ctx.buyer.name, ctx.supplier.name])
    end

    test "a narrowed manager is not offered all roles", ctx do
      s = narrowed_manager(ctx.organization, [ctx.buyer])
      {:ok, view, _} = settings(s.conn)

      html = render_click(element(view, "button[phx-click=open_add]"))
      assert html =~ "Only someone with all roles can give this."
      assert has_element?(view, "input[name=access][value=all][disabled]")
    end
  end

  describe "params the form never offers" do
    test "a narrowed manager cannot give all roles by forging the form", ctx do
      s = narrowed_manager(ctx.organization, [ctx.buyer])
      person = F.person()
      link = F.narrowed_link(ctx.organization, person, [])
      {:ok, view, _} = settings(s.conn)

      render_click(element(view, "button[phx-click=open_edit][phx-value-uuid='#{link.uuid}']"))

      html =
        render_submit(element(view, "#{@panel}-edit"), %{
          "type" => "manager",
          "access" => "all"
        })

      assert html =~ "You can only hand out roles you have yourself."
      refute link_of(ctx.organization, person.uuid).all_roles
    end

    test "a manager cannot add a role above their own, or a role the company lacks", ctx do
      s = narrowed_manager(ctx.organization, [ctx.buyer])
      elsewhere = F.role(["sitemap"])
      person = F.person()
      link = F.narrowed_link(ctx.organization, person, [])
      {:ok, view, _} = settings(s.conn)

      render_click(element(view, "button[phx-click=open_edit][phx-value-uuid='#{link.uuid}']"))

      for {role, message} <- [
            {ctx.supplier, "You can only hand out roles you have yourself."},
            {elsewhere, "doesn&#39;t have that role"}
          ] do
        html =
          render_submit(element(view, "#{@panel}-edit"), %{
            "access" => "some",
            "roles" => [role.name]
          })

        assert html =~ message
      end

      assert role_names(link_of(ctx.organization, person.uuid)) == []
    end

    test "a manager cannot search for people or add them directly", ctx do
      s = manager(ctx.organization)
      person = F.person()
      {:ok, view, _} = settings(s.conn)

      render_click(with_target(view, @panel), "search", %{query: person.email})
      refute render(view) =~ person.email

      render_click(with_target(view, @panel), "add", %{person_uuid: person.uuid})
      refute Repo.get_by(OrganizationManager, user_uuid: person.uuid)
    end

    test "a forged type or malformed roles change nothing", ctx do
      manager(ctx.organization)
      person = F.person()
      link = F.narrowed_link(ctx.organization, person, [ctx.buyer])
      {view, _html, _admin} = admin_view(ctx.organization)

      render_click(element(view, "button[phx-click=open_edit][phx-value-uuid='#{link.uuid}']"))

      for params <- [
            %{"type" => "no-such-type", "access" => "some", "roles" => [ctx.buyer.name]},
            %{"access" => "some", "roles" => ["No such role"]},
            %{"access" => "some", "roles" => %{"a" => "b"}}
          ] do
        assert render_submit(element(view, "#organization-managers-edit"), params) =~
                 "This change is not available"
      end

      assert role_names(link_of(ctx.organization, person.uuid)) == [ctx.buyer.name]
    end

    test "a person who just lost management is refused at once", ctx do
      s = manager(ctx.organization)
      manager(ctx.organization)
      person = F.person()
      link = F.narrowed_link(ctx.organization, person, [])
      {:ok, view, _} = settings(s.conn)
      render_click(element(view, "button[phx-click=open_edit][phx-value-uuid='#{link.uuid}']"))

      {:ok, _} =
        OrganizationManagers.host_update(
          ctx.organization.uuid,
          s.person.uuid,
          [type: ctx.staff],
          F.person()
        )

      render_submit(element(view, "#{@panel}-edit"), %{"access" => "all"})
      refute link_of(ctx.organization, person.uuid).all_roles
    end
  end

  describe "staff" do
    test "are not offered the People tab, and its URL sends them away", ctx do
      manager(ctx.organization)
      s = staff_member(ctx.organization, ctx.staff)

      {:ok, view, html} = settings(s.conn, "notifications")
      refute html =~ "/profile/settings/managers"
      refute has_element?(view, "a[href$='/profile/settings/managers']")

      assert {:error, {:live_redirect, _}} = settings(s.conn)
    end

    test "do not see the company's name and custom fields to edit", ctx do
      manager(ctx.organization)
      s = staff_member(ctx.organization, ctx.staff)

      {:ok, _view, html} = settings(s.conn, "account")
      refute html =~ ~s(name="user[username]")
    end

    test "a manager does", ctx do
      s = manager(ctx.organization)

      {:ok, _view, html} = settings(s.conn, "account")
      assert html =~ ~s(name="user[username]")
    end

    test "cannot change the company's profile by forging the event", ctx do
      manager = manager(ctx.organization)
      staff = staff_member(ctx.organization, ctx.staff)
      # An organization's own field: it has a name, not a first and a last one.
      forged = %{"user" => %{"organization_name" => "Forged Co"}}
      name = Repo.get!(User, ctx.organization.uuid).organization_name

      {:ok, view, _} = settings(staff.conn, "account")
      render_click(with_target(view, "[data-phx-component='1']"), "update_profile", forged)
      assert Repo.get!(User, ctx.organization.uuid).organization_name == name

      # The same event from a manager goes through, so the refusal above is the gate.
      {:ok, view, _} = settings(manager.conn, "account")
      render_click(with_target(view, "[data-phx-component='1']"), "update_profile", forged)
      assert Repo.get!(User, ctx.organization.uuid).organization_name == "Forged Co"
    end

    test "keep their preferences", ctx do
      manager(ctx.organization)
      s = staff_member(ctx.organization, ctx.staff)

      {:ok, _view, html} = settings(s.conn, "notifications")
      assert html =~ "Notifications"
    end
  end

  describe "a person's page" do
    test "lists the organizations they can act for in the top card, with no tab of its own",
         ctx do
      other = F.organization(%{organization_name: "Pine Works"})
      person = F.person()
      F.narrowed_link(ctx.organization, person, [ctx.buyer])
      F.manager(other, person)
      {_actor, admin} = F.admin_actor()

      {:ok, view, _html} =
        live(log_in_user(build_conn(), admin), Routes.path("/admin/users/view/#{person.uuid}"))

      row = view |> element("#person-organizations") |> render()
      assert row =~ "Oak Trading"
      assert row =~ "Pine Works"
      assert row =~ ctx.buyer.name
      assert row =~ "All roles"

      # The top card says it all; the old read-only tab repeated it.
      refute render(view) =~ "hero-building-office-2"
    end
  end

  describe "the invitation banner" do
    defp person_conn(person) do
      {token, _row} = F.session(person)
      init_test_session(build_conn(), %{user_token: token, pk_session_accounts: [token]})
    end

    test "says join for staff, and manage for a manager", ctx do
      s = manager(ctx.organization)
      actor = F.acting_actor(s)
      staff = F.person()
      new_manager = F.person()

      {:ok, _, _} =
        Invitations.create_invitation(ctx.organization, staff.email, actor,
          kind: :manager,
          type: ctx.staff,
          roles: []
        )

      {:ok, _, _} =
        Invitations.create_invitation(ctx.organization, new_manager.email, actor,
          kind: :manager,
          type: "manager"
        )

      {:ok, _view, html} = live(person_conn(staff), Routes.path("/profile/settings/account"))
      assert html =~ "invited you to join their organization"

      {:ok, _view, html} =
        live(person_conn(new_manager), Routes.path("/profile/settings/account"))

      assert html =~ "invited you to manage their organization"
    end
  end
end
