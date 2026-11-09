defmodule PhoenixKitWeb.Users.OrganizationPeopleTest do
  @moduledoc """
  The People row on an organization's admin page (2026-11-09, from WoodMatrix),
  the mirror of a person's Organizations row: who acts for it and what each may
  do there, attached from a search, detached from a chip, invited by email;
  read-only with the reason when the session may not change it. Also the People
  tab, which a session that may not manage used to see empty.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.ManagedOrganizations.Actor
  alias PhoenixKit.Users.OrganizationInvitation
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.ManageNotice

  @row "#organization-people"

  setup do
    Settings.update_setting("enable_organization_accounts", "true")
    {_actor, admin} = F.admin_actor()
    %{admin: admin, org: F.organization(%{organization_name: "Oak Trading"})}
  end

  defp open(conn_or_admin, org, query \\ "")

  defp open(%Plug.Conn{} = conn, org, query) do
    {:ok, view, _html} = live(conn, Routes.path("/admin/users/view/#{org.uuid}") <> query)
    view
  end

  defp open(admin, org, query), do: open(log_in_user(build_conn(), admin), org, query)

  defp open_search(view) do
    view |> element("#{@row}-open") |> render_click()
    view
  end

  defp type_in(view, term, type \\ nil) do
    params = if type, do: %{"term" => term, "type" => type}, else: %{"term" => term}
    view |> form("#{@row}-form", params) |> render_change()
  end

  defp people(org) do
    org.uuid
    |> OrganizationManagers.people_of()
    |> Enum.map(&{&1.person.email, &1.type.key})
  end

  defp named(attrs), do: F.person(Map.merge(%{first_name: "Ann", last_name: "Lee"}, attrs))

  # An Admin who signed in as a user that may see the Users pages but is neither
  # an Owner nor an Admin: a borrowed account acts as that user (2026-11-09), so
  # the page is read-only, as it is for them.
  defp switched_conn do
    {_actor, root} = F.admin_actor()
    viewer = F.person()
    {:ok, _} = Roles.assign_role(viewer, F.role(["users"]).name)
    stacked_conn(root, viewer, own?: false)
  end

  # `active` sits second in a stack opened by `root`; with `own?: true` it was
  # added with its own password (the case WoodMatrix met: an Owner signed in to
  # the switcher after a test account).
  defp stacked_conn(root, active, own?: own?) do
    {root_token, _} = F.session(root)
    {token, _} = F.session(active)

    init_test_session(build_conn(), %{
      user_token: token,
      pk_session_accounts: [root_token, token],
      pk_own_tokens: if(own?, do: [token], else: [])
    })
  end

  describe "the row" do
    test "lists each person with what they can do, and the older tie as Member",
         %{admin: admin, org: org} do
      buyer = F.role(["users"], org)
      ann = named(%{email: "ann@example.com"})
      F.manager(org, ann)
      bob = F.person(%{email: "bob@example.com", first_name: "Bob"})
      F.narrowed_link(org, bob, [buyer])
      cy = F.person(%{email: "cy@example.com", first_name: "Cy"})
      F.narrowed_link(org, cy, [])
      dee = F.person(%{email: "dee@example.com", first_name: "Dee", organization_uuid: org.uuid})

      view = open(admin, org)

      assert has_element?(view, "#{@row}-person-#{ann.uuid}", "Ann Lee")
      assert has_element?(view, "#{@row}-person-#{ann.uuid}", "Manager")
      assert has_element?(view, "#{@row}-person-#{ann.uuid}", "All roles")
      assert has_element?(view, "#{@row}-person-#{bob.uuid}", buyer.name)
      assert has_element?(view, "#{@row}-person-#{cy.uuid}", "No roles")
      assert has_element?(view, "#{@row}-person-#{dee.uuid}", "Member")

      assert has_element?(
               view,
               ~s(#{@row}-person-#{ann.uuid} a[href="#{Routes.path("/admin/users/view/#{ann.uuid}")}"])
             )
    end

    test "shows five, then how many more, opening the People tab", %{admin: admin, org: org} do
      for n <- 1..7, do: F.manager(org, F.person(%{first_name: "P#{n}"}))

      view = open(admin, org)

      assert view |> element("#{@row}-more") |> render() =~ "+2 more"

      assert has_element?(
               view,
               ~s(#{@row}-more[href="#{Routes.path("/admin/users/view/#{org.uuid}?tab=people")}"])
             )
    end

    test "is not on a person's page", %{admin: admin} do
      refute has_element?(open(admin, F.person()), @row)
    end
  end

  describe "attaching" do
    test "typing finds a person by name or email, and Enter attaches the first as manager",
         %{admin: admin, org: org} do
      ann = named(%{email: "ann.lee@example.com"})
      named(%{email: "zed@example.com", first_name: "Zed", last_name: "Annson"})

      view = admin |> open(org) |> open_search()
      assert type_in(view, "ann") =~ ~r/ann\.lee@example\.com.*zed@example\.com/s

      view |> form("#{@row}-form", %{"term" => "ann"}) |> render_submit()

      assert people(org) == [{"ann.lee@example.com", "manager"}]
      assert has_element?(view, "#{@row}-person-#{ann.uuid}")
      refute has_element?(view, "#{@row}-form")
    end

    test "as another type", %{admin: admin, org: org} do
      ann = named(%{email: "ann@example.com"})
      view = admin |> open(org) |> open_search()

      type_in(view, "ann@", "staff")
      view |> element("#{@row}-pick-#{ann.uuid}") |> render_click()

      assert people(org) == [{"ann@example.com", "staff"}]
    end

    test "to an organization with its own login, through the older tie", %{admin: admin} do
      own = F.organization(%{organization_name: "Birch AS", managed_by_members: false})
      ann = named(%{email: "ann@example.com"})
      view = admin |> open(own) |> open_search()

      type_in(view, "ann@")
      view |> element("#{@row}-pick-#{ann.uuid}") |> render_click()

      assert Repo.get!(AuthCtx.User, ann.uuid).organization_uuid == own.uuid
      assert has_element?(view, "#{@row}-person-#{ann.uuid}", "Member")
    end

    test "an address nobody has an account at is invited, on Enter too", %{admin: admin, org: org} do
      view = admin |> open(org) |> open_search()

      type_in(view, "new.person@example.com")
      assert has_element?(view, "#{@row}-invite")

      view |> form("#{@row}-form", %{"term" => "new.person@example.com"}) |> render_submit()

      assert [%OrganizationInvitation{email: "new.person@example.com"}] =
               Repo.all(
                 from(i in OrganizationInvitation, where: i.organization_uuid == ^org.uuid)
               )
    end

    test "nobody is offered twice", %{admin: admin, org: org} do
      ann = named(%{email: "ann@example.com"})
      F.manager(org, ann)
      view = admin |> open(org) |> open_search()

      refute type_in(view, "ann@") =~ "#{@row |> String.trim_leading("#")}-pick-#{ann.uuid}"
    end
  end

  describe "detaching" do
    test "× asks once, then removes", %{admin: admin, org: org} do
      F.manager(org, F.person())
      ann = named(%{email: "ann@example.com"})
      F.manager(org, ann)
      view = open(admin, org)

      view |> element("#{@row}-remove-#{ann.uuid}") |> render_click()
      assert has_element?(view, "#{@row}-person-#{ann.uuid}", "Remove Ann Lee?")

      view |> element("#{@row}-detach-#{ann.uuid}") |> render_click()

      refute Repo.get_by(OrganizationManager, organization_uuid: org.uuid, user_uuid: ann.uuid)
      refute has_element?(view, "#{@row}-person-#{ann.uuid}")
    end

    test "the last manager stays unless the admin says remove anyway", %{admin: admin, org: org} do
      ann = named(%{email: "ann@example.com"})
      F.manager(org, ann)
      view = open(admin, org)

      view |> element("#{@row}-remove-#{ann.uuid}") |> render_click()
      view |> element("#{@row}-detach-#{ann.uuid}") |> render_click()

      assert has_element?(view, "#{@row}-person-#{ann.uuid}", "nobody could manage")
      assert Repo.get_by(OrganizationManager, organization_uuid: org.uuid, user_uuid: ann.uuid)

      view |> element("#{@row}-detach-anyway-#{ann.uuid}") |> render_click()

      refute Repo.get_by(OrganizationManager, organization_uuid: org.uuid, user_uuid: ann.uuid)
    end
  end

  describe "a session that may not change it" do
    test "signed in as a user who may not, the people show read-only, and why", %{org: org} do
      ann = named(%{email: "ann@example.com"})
      F.manager(org, ann)

      view = open(switched_conn(), org)

      assert has_element?(view, "#{@row}-person-#{ann.uuid}")
      refute has_element?(view, "#{@row}-open")
      refute has_element?(view, "#{@row}-remove-#{ann.uuid}")
      assert has_element?(view, "#{@row}-notice", "Only an Owner or Admin")

      # Forged events change nothing.
      view
      |> with_target(@row)
      |> render_click("detach", %{"uuid" => ann.uuid, "anyway" => "true"})

      assert Repo.get_by(OrganizationManager, organization_uuid: org.uuid, user_uuid: ann.uuid)
    end

    test "the People tab lists them read-only instead of staying empty", %{org: org} do
      ann = named(%{email: "ann@example.com"})
      F.manager(org, ann)

      view = open(switched_conn(), org, "?tab=people")

      assert has_element?(
               view,
               "#organization-managers-read-only",
               "Only an Owner or Admin"
             )

      assert has_element?(view, "#organization-managers-read-only-#{ann.uuid}", "Ann Lee")
      assert has_element?(view, "#organization-managers-read-only-#{ann.uuid}", "All roles")
    end

    test "someone who is not an Owner or Admin is told so", %{org: org} do
      F.manager(org, named(%{email: "ann@example.com"}))
      viewer = F.person()
      {:ok, _} = Roles.assign_role(viewer, F.role(["users"]).name)

      view = open(viewer, org, "?tab=people")

      assert has_element?(view, "#{@row}-notice", "Only an Owner or Admin")
      assert has_element?(view, "#organization-managers-read-only", "Only an Owner or Admin")
    end

    test "the person page's Organizations row says why too", %{org: org} do
      ann = named(%{email: "ann@example.com"})
      F.manager(org, ann)

      view = open(switched_conn(), ann)

      refute has_element?(view, "#person-organizations-open")
      assert has_element?(view, "#person-organizations-notice", "Only an Owner or Admin")
    end

    test "signed in as an Admin (an Owner may), the page is that Admin's to change",
         %{org: org} do
      {_actor, root} = F.admin_actor()
      {_actor, admin} = F.admin_actor()

      view = open(stacked_conn(root, admin, own?: false), org)

      assert has_element?(view, "#{@row}-open")
      refute has_element?(view, "#{@row}-notice")
    end
  end

  describe "an account the person added with its own password" do
    test "an Admin there manages the people as in a first account", %{org: org} do
      {_actor, admin} = F.admin_actor()
      ann = named(%{email: "ann@example.com"})
      conn = stacked_conn(F.person(), admin, own?: true)

      view = open(conn, org)

      refute has_element?(view, "#{@row}-notice")
      view |> open_search() |> type_in("ann@")
      view |> element("#{@row}-pick-#{ann.uuid}") |> render_click()

      assert people(org) == [{"ann@example.com", "manager"}]
      assert has_element?(open(conn, org, "?tab=people"), "#organization-managers")
      refute has_element?(open(conn, org, "?tab=people"), "#organization-managers-read-only")
    end

    test "the person page's Organizations row is editable there too" do
      {_actor, admin} = F.admin_actor()
      view = open(stacked_conn(F.person(), admin, own?: true), F.person())

      assert has_element?(view, "#person-organizations-open")
      refute has_element?(view, "#person-organizations-notice")
    end

    test "one that is not an Owner or Admin is told so, not to switch back", %{org: org} do
      viewer = F.person()
      {:ok, _} = Roles.assign_role(viewer, F.role(["users"]).name)
      {_actor, admin} = F.admin_actor()

      view = open(stacked_conn(admin, viewer, own?: true), org)

      assert has_element?(view, "#{@row}-notice", "Only an Owner or Admin")
    end

    test "the Actor stands on the account shown, added or borrowed" do
      {_actor, root} = F.admin_actor()
      {_actor, other} = F.admin_actor()
      {root_token, _} = F.session(root)
      {token, _} = F.session(other)
      session = %{"user_token" => token, "pk_session_accounts" => [root_token, token]}

      assert {:ok, %Actor{current: same, root: same}} =
               Actor.from_session(Map.put(session, "pk_own_tokens", [token]))

      assert {:ok, %Actor{current: same, root: same}} = Actor.from_session(session)
      assert {_row, uuid} = same
      assert uuid == other.uuid
      refute uuid == root.uuid
    end
  end

  describe "ManageNotice.reason/2" do
    test "tells the session shapes apart" do
      own = {Ecto.UUID.generate(), Ecto.UUID.generate()}
      org_uuid = Ecto.UUID.generate()

      assert ManageNotice.reason(%Actor{current: own, root: own}, org_uuid) == :not_admin

      assert ManageNotice.reason(
               %Actor{current: {Ecto.UUID.generate(), org_uuid}, root: own},
               org_uuid
             ) ==
               :acting

      assert ManageNotice.reason(
               %Actor{current: {Ecto.UUID.generate(), Ecto.UUID.generate()}, root: own},
               org_uuid
             ) == :switched

      assert ManageNotice.reason(nil, org_uuid) == :no_session
    end
  end
end
