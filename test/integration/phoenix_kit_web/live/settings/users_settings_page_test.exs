defmodule PhoenixKitWeb.Live.Settings.UsersSettingsPageTest do
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Utils.Routes

  test "users settings page renders the auth settings controls", %{conn: conn} do
    {admin, _token} = create_admin_user()
    conn = log_in_user(conn, admin)

    {:ok, _lv, html} = live(conn, Routes.path("/admin/settings/users"))

    assert html =~ ~s(name="settings[require_email_confirmation]")
    assert html =~ ~s(name="settings[remember_me_enabled]")
    assert html =~ ~s(name="settings[remember_me_default]")
    assert html =~ ~s(name="settings[after_login_path]")
    assert html =~ ~s(name="settings[after_registration_path]")
  end

  test "saving the auth settings round-trips through the form", %{conn: conn} do
    {admin, _token} = create_admin_user()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, Routes.path("/admin/settings/users"))

    lv
    |> form("#user_settings_form", %{
      "settings" => %{
        "remember_me_enabled" => "true",
        "remember_me_default" => "false",
        "require_email_confirmation" => "false",
        "after_login_path" => "/welcome",
        "after_registration_path" => "/onboarding"
      }
    })
    |> render_submit()

    assert PhoenixKit.Settings.get_setting("remember_me_default") == "false"
    assert PhoenixKit.Settings.get_setting("require_email_confirmation") == "false"
    assert PhoenixKit.Settings.get_setting("after_login_path") == "/welcome"
    assert PhoenixKit.Settings.get_setting("after_registration_path") == "/onboarding"
  end

  # <.checkbox> pairs the box with an un-disabled hidden "false" input, so a
  # `disabled` box still submits "false". Saving with persistence off must not
  # silently rewrite the stored default.
  test "saving while persistence is off preserves remember_me_default", %{conn: conn} do
    PhoenixKit.Settings.update_setting("remember_me_enabled", "false")
    PhoenixKit.Settings.update_setting("remember_me_default", "true")

    {admin, _token} = create_admin_user()
    conn = log_in_user(conn, admin)

    {:ok, lv, html} = live(conn, Routes.path("/admin/settings/users"))

    # The control stays submittable rather than disabled.
    assert html =~ ~s(name="settings[remember_me_default]")

    lv |> form("#user_settings_form") |> render_submit()

    assert PhoenixKit.Settings.get_setting("remember_me_default") == "true"
  end

  test "the form rejects a non-local redirect path", %{conn: conn} do
    {admin, _token} = create_admin_user()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, Routes.path("/admin/settings/users"))

    html =
      lv
      |> form("#user_settings_form", %{
        "settings" => %{"after_login_path" => "https://evil.example"}
      })
      |> render_submit()

    assert html =~ "local path"
    refute PhoenixKit.Settings.get_setting("after_login_path") == "https://evil.example"
  end
end
