defmodule PhoenixKitWeb.Users.PersonOrganizationsTest do
  @moduledoc """
  The Organizations row on a person's admin page (2026-11-08): attach to a
  company from a search, detach from a chip, or create a company by name with
  the person as its manager, without leaving the page.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Users.PersonOrganizations
  alias PhoenixKit.Utils.Routes

  @row "#person-organizations"

  setup do
    Settings.update_setting("enable_organization_accounts", "true")
    {_actor, admin} = F.admin_actor()
    %{admin: admin, person: F.person()}
  end

  defp open_page(admin, person) do
    {:ok, view, _html} =
      live(log_in_user(build_conn(), admin), Routes.path("/admin/users/view/#{person.uuid}"))

    view
  end

  defp open_search(view) do
    view |> element("#{@row}-open") |> render_click()
    view
  end

  defp type_in(view, term, type \\ nil) do
    params = if type, do: %{"term" => term, "type" => type}, else: %{"term" => term}
    view |> form("#{@row}-form", params) |> render_change()
  end

  defp links(person),
    do:
      person.uuid
      |> OrganizationManagers.organizations_of()
      |> Enum.map(&{&1.organization.organization_name, &1.type.key})

  defp reload(person), do: Repo.get!(AuthCtx.User, person.uuid)

  test "the person's companies are chips, both kinds", %{admin: admin, person: person} do
    linked = F.organization(%{organization_name: "Oak Trading"})
    F.manager(linked, person)
    own = F.organization(%{organization_name: "Birch AS", managed_by_members: false})
    {:ok, person} = AuthCtx.set_organization(person, own.uuid)

    view = open_page(admin, person)

    assert has_element?(view, "#{@row}-org-#{linked.uuid}", "Oak Trading")
    assert has_element?(view, "#{@row}-org-#{linked.uuid}", "Manager")
    assert has_element?(view, "#{@row}-org-#{own.uuid}", "Member")
  end

  test "typing finds a company and Enter attaches the first match as manager",
       %{admin: admin, person: person} do
    oak = F.organization(%{organization_name: "Oak Trading"})
    F.organization(%{organization_name: "Pine Oakwood"})

    view = admin |> open_page(person) |> open_search()
    html = type_in(view, "oak")

    # Starting with the term comes first.
    assert html =~ ~r/Oak Trading.*Pine Oakwood/s

    view |> form("#{@row}-form", %{"term" => "oak"}) |> render_submit()

    assert links(person) == [{"Oak Trading", "manager"}]
    assert has_element?(view, "#{@row}-org-#{oak.uuid}")
    refute has_element?(view, "#{@row}-form")
  end

  test "a link can be another type", %{admin: admin, person: person} do
    oak = F.organization(%{organization_name: "Oak Trading"})
    view = admin |> open_page(person) |> open_search()

    type_in(view, "Oak", "staff")
    view |> element("#{@row}-pick-#{oak.uuid}") |> render_click()

    assert links(person) == [{"Oak Trading", "staff"}]
  end

  test "a company with its own login gets the older tie", %{admin: admin, person: person} do
    own = F.organization(%{organization_name: "Birch AS", managed_by_members: false})
    view = admin |> open_page(person) |> open_search()

    assert type_in(view, "Birch") =~ "own login"
    view |> element("#{@row}-pick-#{own.uuid}") |> render_click()

    assert reload(person).organization_uuid == own.uuid
    assert links(person) == []
  end

  test "a new name creates the company with the person as its manager",
       %{admin: admin, person: person} do
    view = admin |> open_page(person) |> open_search()

    type_in(view, "  Brand New Timber  ")
    assert has_element?(view, "#{@row}-create")
    view |> element("#{@row}-new") |> render_click()

    assert [{"Brand New Timber", "manager"}] = links(person)

    [org] =
      Repo.all(
        from(u in AuthCtx.User, where: u.organization_name == "Brand New Timber", select: u)
      )

    assert org.managed_by_members
    assert org.created_by_uuid == admin.uuid
  end

  test "Enter with no match creates the company too", %{admin: admin, person: person} do
    view = admin |> open_page(person) |> open_search()
    view |> form("#{@row}-form", %{"term" => "Larch Mill"}) |> render_submit()

    assert [{"Larch Mill", "manager"}] = links(person)
  end

  test "an existing name is offered, never created again", %{admin: admin, person: person} do
    F.organization(%{organization_name: "Oak Trading"})
    view = admin |> open_page(person) |> open_search()

    type_in(view, "oak trading")
    refute has_element?(view, "#{@row}-create")
    assert has_element?(view, "#{@row}-new[disabled]")

    # A forged create is refused as well.
    view |> with_target(@row) |> render_click("create", %{})

    assert Repo.aggregate(
             from(u in AuthCtx.User, where: ilike(u.organization_name, "oak trading")),
             :count
           ) == 1
  end

  test "× asks once, then detaches", %{admin: admin, person: person} do
    oak = F.organization(%{organization_name: "Oak Trading"})
    other_manager = F.person()
    F.manager(oak, other_manager)
    F.manager(oak, person)
    view = open_page(admin, person)

    view |> element("#{@row}-remove-#{oak.uuid}") |> render_click()
    assert has_element?(view, "#{@row}-org-#{oak.uuid}", "Remove from Oak Trading?")
    assert links(person) != []

    view |> element("#{@row}-detach-#{oak.uuid}") |> render_click()

    assert links(person) == []
    refute has_element?(view, "#{@row}-org-#{oak.uuid}")
  end

  test "the last manager is kept unless the admin says remove anyway",
       %{admin: admin, person: person} do
    oak = F.organization(%{organization_name: "Oak Trading"})
    F.manager(oak, person)
    view = open_page(admin, person)

    view |> element("#{@row}-remove-#{oak.uuid}") |> render_click()
    view |> element("#{@row}-detach-#{oak.uuid}") |> render_click()

    assert has_element?(view, "#{@row}-org-#{oak.uuid}", "would have no manager")
    assert Repo.get_by(OrganizationManager, organization_uuid: oak.uuid, user_uuid: person.uuid)

    view |> element("#{@row}-detach-anyway-#{oak.uuid}") |> render_click()

    refute Repo.get_by(OrganizationManager, organization_uuid: oak.uuid, user_uuid: person.uuid)
  end

  test "the older tie detaches the same way", %{admin: admin, person: person} do
    own = F.organization(%{organization_name: "Birch AS", managed_by_members: false})
    {:ok, person} = AuthCtx.set_organization(person, own.uuid)
    view = open_page(admin, person)

    view |> element("#{@row}-remove-#{own.uuid}") |> render_click()
    view |> element("#{@row}-detach-#{own.uuid}") |> render_click()

    assert reload(person).organization_uuid == nil
  end

  test "legacy ties require a live admin actor in the context", %{person: person} do
    own = F.organization(%{managed_by_members: false})
    {actor, admin} = F.admin_actor()

    assert {:error, :forbidden} = PersonOrganizations.attach(nil, person, own.uuid)
    assert reload(person).organization_uuid == nil

    assert {:ok, person} = PersonOrganizations.attach(actor, person, own.uuid)
    assert {:error, :forbidden} = PersonOrganizations.detach(nil, person, own.uuid)
    assert reload(person).organization_uuid == own.uuid

    {:ok, _} = Roles.remove_role(admin, "Admin")

    assert {:error, :forbidden} = PersonOrganizations.detach(actor, person, own.uuid)
    assert reload(person).organization_uuid == own.uuid

    other = F.organization(%{managed_by_members: false})
    assert {:error, :forbidden} = PersonOrganizations.attach(actor, person, other.uuid)
    assert reload(person).organization_uuid == own.uuid
  end

  test "someone who is not an Owner or Admin sees the chips and changes nothing",
       %{person: person} do
    oak = F.organization(%{organization_name: "Oak Trading"})
    F.manager(oak, person)

    viewer = F.person()
    role = F.role(["users"])
    {:ok, _} = Roles.assign_role(viewer, role.name)
    view = open_page(viewer, person)

    assert has_element?(view, "#{@row}-org-#{oak.uuid}")
    refute has_element?(view, "#{@row}-open")
    refute has_element?(view, "#{@row}-remove-#{oak.uuid}")

    view |> with_target(@row) |> render_click("detach", %{"uuid" => oak.uuid, "anyway" => "true"})
    view |> with_target(@row) |> render_click("create", %{})

    assert links(person) == [{"Oak Trading", "manager"}]
  end

  test "not on a company's own page", %{admin: admin} do
    oak = F.organization(%{organization_name: "Oak Trading"})
    view = open_page(admin, oak)

    refute has_element?(view, @row)
  end
end
