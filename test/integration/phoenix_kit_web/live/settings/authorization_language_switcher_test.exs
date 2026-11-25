defmodule PhoenixKitWeb.Live.Settings.AuthorizationLanguageSwitcherTest do
  @moduledoc """
  The Authorization settings page carries the checkbox for the language
  switcher shown under the sign-in and registration forms, saves it both ways,
  and the change shows on the rendered auth pages.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @key "auth_language_switcher_enabled"
  @checkbox ~s(input[type="checkbox"][name="settings[#{@key}]"])
  @switcher "#language-switcher-dropdown"

  setup do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("ja")
    :ok
  end

  defp admin_conn(conn) do
    {admin, _token} = create_admin_user()
    log_in_user(conn, admin)
  end

  defp save(view, value) do
    view
    |> form("#authorization_settings_form", %{"settings" => %{@key => value}})
    |> render_submit()
  end

  defp auth_page_has_switcher?(conn, path) do
    {:ok, view, _html} = live(conn, Routes.path(path))
    has_element?(view, @switcher)
  end

  test "the checkbox is on the page, ticked by default", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), Routes.path("/admin/settings/authorization"))

    assert has_element?(view, @checkbox)
    assert has_element?(view, @checkbox <> "[checked]")
  end

  test "saving it off, then on again, is stored and shown on the page", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), Routes.path("/admin/settings/authorization"))

    save(view, "false")
    assert Settings.get_setting(@key) == "false"
    refute has_element?(view, @checkbox <> "[checked]")

    save(view, "true")
    assert Settings.get_setting(@key) == "true"
    assert has_element?(view, @checkbox <> "[checked]")
  end

  test "the change takes effect on the sign-in and registration pages", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), Routes.path("/admin/settings/authorization"))
    guest = Phoenix.ConnTest.build_conn()

    assert auth_page_has_switcher?(guest, "/users/log-in")
    assert auth_page_has_switcher?(guest, "/users/register")

    save(view, "false")

    refute auth_page_has_switcher?(guest, "/users/log-in")
    refute auth_page_has_switcher?(guest, "/users/register")

    save(view, "true")

    assert auth_page_has_switcher?(guest, "/users/log-in")
    assert auth_page_has_switcher?(guest, "/users/register")
  end
end
