defmodule PhoenixKit.Integration.Users.UsersAdminRussianTest do
  @moduledoc """
  The users admin in Russian (2026-11-09, from a client: some places stayed in
  English). Each check is one of the places that did: role names printed raw,
  the system roles' seeded descriptions, permission labels looked up at runtime
  but never extracted, country names, and the notifications bell on pages that
  did not hand the layout their language.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Utils.Routes

  setup do
    Settings.update_setting("enable_organization_accounts", "true")
    Settings.update_setting("languages_enabled", "true")

    Settings.update_json_setting("languages_config", %{
      "languages" => [
        %{"code" => "en", "name" => "English", "is_default" => true, "is_enabled" => true},
        %{"code" => "ru", "name" => "Russian", "is_default" => false, "is_enabled" => true}
      ]
    })

    {_actor, admin} = F.admin_actor()
    %{conn: log_in_user(build_conn(), admin)}
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, Routes.path(path, locale: "ru"))
    view
  end

  test "the users list names roles in Russian, in the table and the cards", %{conn: conn} do
    F.person(%{email: "ru-probe@example.com"})
    view = open(conn, "/admin/users?q=ru-probe")

    assert render(view) =~ "Пользователь"

    html = render_click(view, "set_view_mode", %{"mode" => "card"})
    assert html =~ "Пользователь"
    refute html =~ ~r/>\s*User\s*</
  end

  test "a user's page names the country in Russian", %{conn: conn} do
    person = F.person(%{country: "AT"})
    view = open(conn, "/admin/users/view/#{person.uuid}")

    assert has_element?(view, "#user-info-country", "Австрия")
  end

  test "the system roles' descriptions are translated while nobody has rewritten them",
       %{conn: conn} do
    html = render(open(conn, "/admin/users/roles"))

    assert html =~ "Администратор с расширенными правами"
    refute html =~ "Administrator with elevated privileges"
  end

  test "a system role saved with its English text untouched still reads in Russian; a rewritten one as written",
       %{conn: conn} do
    admin_role = Roles.get_role_by_name("Admin")

    {:ok, _} =
      Roles.update_role(admin_role, %{
        "label" => "Admin",
        "description" => "Administrator with elevated privileges"
      })

    user_role = Roles.get_role_by_name("User")
    {:ok, _} = Roles.update_role(user_role, %{"description" => "Our customers"})

    html = render(open(conn, "/admin/users/roles"))

    assert html =~ "Администратор с расширенными правами"
    refute html =~ "Administrator with elevated privileges"
    assert html =~ "Our customers"
    saved = Roles.get_role_by_name("Admin")
    assert saved.data != nil
    assert Roles.display_name(saved, "ru") =~ "Администратор"
  end

  test "permission labels are translated, the sub-permissions too", %{conn: conn} do
    html = render(open(conn, "/admin/users/permissions"))

    assert html =~ "Управление хранилищем"
    assert html =~ "Полный доступ (суперадминистратор)"
    refute html =~ "Manage storage"
  end

  test "the notifications bell speaks the page's language on every page", %{conn: conn} do
    for path <- ["/admin/users/relationship-types", "/admin/users/new/managed"] do
      view = open(conn, path)
      [bell] = live_children(view)

      assert render(bell) =~ "Уведомления", path
      refute render(bell) =~ "Notifications", path
    end
  end
end
