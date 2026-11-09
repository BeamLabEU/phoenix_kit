defmodule PhoenixKit.Integration.Users.UserFormOrganizationsTest do
  @moduledoc """
  The admin's user form and a person's companies (2026-11-09): the same
  Organizations row as on the user's page, saved straight away apart from the
  form. It replaced the older single-company selector, whose tie shows in the
  row as "Member", and saving the form never clears a tie set meanwhile.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Utils.Routes

  @row "#person-organizations"

  setup do
    Settings.update_setting("enable_organization_accounts", "true")
    {_actor, admin} = F.admin_actor()
    own = F.organization(%{organization_name: "Birch AS", managed_by_members: false})
    %{admin: admin, own: own}
  end

  defp open(conn_or_admin, path)

  defp open(%Plug.Conn{} = conn, path) do
    {:ok, view, _html} = live(conn, Routes.path(path))
    view
  end

  defp open(admin, path), do: open(log_in_user(build_conn(), admin), path)

  defp edit(who, person), do: open(who, "/admin/users/edit/#{person.uuid}")

  test "a person's form has the Organizations row, and a company is added from it",
       %{admin: admin} do
    oak = F.organization(%{organization_name: "Oak Trading"})
    person = F.person()
    view = edit(admin, person)

    assert has_element?(view, "#user-form-organizations #{@row}")
    refute has_element?(view, ~s(select[name="user[organization_uuid]"]))

    view |> element("#{@row}-open") |> render_click()
    view |> form("#{@row}-form", %{"term" => "Oak"}) |> render_submit()

    assert [%{organization: %{uuid: uuid}}] = OrganizationManagers.organizations_of(person.uuid)
    assert uuid == oak.uuid
    assert has_element?(view, "#{@row}-org-#{oak.uuid}", "Manager")
    assert has_element?(view, "#{@row}-org-#{oak.uuid}", "All roles")
  end

  test "the older tie is a Member chip, and × lets it go", %{admin: admin, own: own} do
    person = F.person(%{organization_uuid: own.uuid})
    view = edit(admin, person)

    assert has_element?(view, "#{@row}-org-#{own.uuid}", "Member")

    view |> element("#{@row}-remove-#{own.uuid}") |> render_click()
    view |> element("#{@row}-detach-#{own.uuid}") |> render_click()

    assert Repo.get!(AuthCtx.User, person.uuid).organization_uuid == nil
    refute has_element?(view, "#{@row}-org-#{own.uuid}")
  end

  test "a new user's form and an organization's form have no row", %{admin: admin, own: own} do
    refute has_element?(open(admin, "/admin/users/new"), "#user-form-organizations")
    refute has_element?(edit(admin, own), "#user-form-organizations")
  end

  test "someone who is not an Owner or Admin sees the row read-only, and why",
       %{own: own} do
    person = F.person(%{organization_uuid: own.uuid})
    viewer = F.person()
    {:ok, _} = Roles.assign_role(viewer, F.role(["users"]).name)

    view = edit(viewer, person)

    assert has_element?(view, "#{@row}-org-#{own.uuid}")
    refute has_element?(view, "#{@row}-open")
    assert has_element?(view, "#{@row}-notice", "Only an Owner or Admin")
  end

  test "saving the form leaves a tie set meanwhile alone", %{admin: admin, own: own} do
    person = F.person(%{first_name: "Ann"})
    view = edit(admin, person)

    # Attached from the user's page while this form was open.
    {:ok, _} = AuthCtx.set_organization(person, own.uuid)

    view
    |> form("#user_form", %{"user" => %{"first_name" => "Anna"}})
    |> render_submit()

    saved = Repo.get!(AuthCtx.User, person.uuid)
    assert saved.first_name == "Anna"
    assert saved.organization_uuid == own.uuid
  end

  test "saving the form after × in the row keeps the tie let go", %{admin: admin, own: own} do
    person = F.person(%{first_name: "Ann", organization_uuid: own.uuid})
    view = edit(admin, person)

    view |> element("#{@row}-remove-#{own.uuid}") |> render_click()
    view |> element("#{@row}-detach-#{own.uuid}") |> render_click()

    view
    |> form("#user_form", %{"user" => %{"first_name" => "Anna"}})
    |> render_submit()

    saved = Repo.get!(AuthCtx.User, person.uuid)
    assert saved.first_name == "Anna"
    assert saved.organization_uuid == nil
  end
end
