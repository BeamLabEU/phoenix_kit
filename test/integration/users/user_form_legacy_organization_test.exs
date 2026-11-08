defmodule PhoenixKit.Integration.Users.UserFormLegacyOrganizationTest do
  @moduledoc """
  The admin's user form and the older single company tie
  (`users.organization_uuid`, 2026-11-08): its selector stays only for a person
  who still has that tie, to change it or let it go. Companies are attached on
  the user's page now, so a person without one gets a link there instead, and
  saving the form without the selector never clears a tie set meanwhile.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Utils.Routes

  setup do
    Settings.update_setting("enable_organization_accounts", "true")
    {_actor, admin} = F.admin_actor()
    own = F.organization(%{organization_name: "Birch AS", managed_by_members: false})
    %{admin: admin, own: own}
  end

  defp open(admin, path) do
    {:ok, view, _html} = live(log_in_user(build_conn(), admin), Routes.path(path))
    view
  end

  defp edit(admin, person), do: open(admin, "/admin/users/edit/#{person.uuid}")

  test "a person without the tie gets no selector, only the way to the user's page",
       %{admin: admin} do
    person = F.person()
    view = edit(admin, person)

    refute has_element?(view, "#user-form-legacy-organization")
    refute has_element?(view, ~s(select[name="user[organization_uuid]"]))

    assert has_element?(
             view,
             ~s(a#user-form-organizations-hint[href="#{Routes.path("/admin/users/view/#{person.uuid}")}"])
           )
  end

  test "a new user's form has neither", %{admin: admin} do
    view = open(admin, "/admin/users/new")

    refute has_element?(view, "#user-form-legacy-organization")
    refute has_element?(view, "#user-form-organizations-hint")
  end

  test "a person with the tie keeps the selector, and can let the tie go",
       %{admin: admin, own: own} do
    person = F.person(%{organization_uuid: own.uuid})
    view = edit(admin, person)

    assert has_element?(view, "#user-form-legacy-organization")
    refute has_element?(view, "#user-form-organizations-hint")

    view
    |> form("#user_form", %{"user" => %{"organization_uuid" => ""}})
    |> render_submit()

    assert Repo.get!(AuthCtx.User, person.uuid).organization_uuid == nil
  end

  test "saving without the selector leaves a tie set meanwhile alone",
       %{admin: admin, own: own} do
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
end
