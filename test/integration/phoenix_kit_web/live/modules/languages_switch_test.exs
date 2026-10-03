defmodule PhoenixKitWeb.Live.Modules.LanguagesSwitchTest do
  @moduledoc """
  The site's multi-language switch, on Settings → Languages.

  Languages is core and always on; what the page's first card switches is
  `Languages.enabled?/0`. The page has to stay reachable while the switch is off
  (it used to be refused as a disabled module, which made the switch impossible
  to reach from here), and with the switch off nothing below the card is shown.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Dashboard.AdminTabs
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @languages_path Routes.path("/admin/settings/languages")
  @toggle "input#languages-enabled-toggle"

  setup do
    Settings.update_setting("languages_enabled", "false")
    on_exit(fn -> Settings.update_setting("languages_enabled", "false") end)
    :ok
  end

  defp mount_as_admin(conn) do
    {user, _token} = create_admin_user()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> log_in_user(user)

    live(conn, @languages_path)
  end

  defp mount_as_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash()
    |> log_in_user(user)
    |> live(@languages_path)
  end

  defp switch_checked?(view) do
    Regex.match?(~r/<input\b[^>]*\bchecked\b[^>]*>/, view |> element(@toggle) |> render())
  end

  describe "with the switch off" do
    test "the page is reachable and shows the switch, off", %{conn: conn} do
      refute Languages.enabled?()

      {:ok, view, html} = mount_as_admin(conn)

      assert html =~ "Multiple languages"
      assert html =~ "the site is served in its default language only"
      refute switch_checked?(view)
    end

    test "nothing below the switch is shown, and no default is presented as enabled", %{
      conn: conn
    } do
      {:ok, _view, html} = mount_as_admin(conn)

      refute html =~ "Languages Enabled"
      refute html =~ "URL Behavior"
      refute html =~ "Frontend Language Switcher"
      refute html =~ "Default Language Without Prefix"
    end

    test "turning it on persists, seeds English and reveals the configuration", %{conn: conn} do
      {:ok, view, _html} = mount_as_admin(conn)

      html = view |> element(@toggle) |> render_click()

      assert Languages.enabled?()
      assert [%{code: "en-US"}] = Languages.get_enabled_languages()
      assert switch_checked?(view)
      assert html =~ "Languages Enabled"
      assert html =~ "URL Behavior"
      refute html =~ "the site is served in its default language only"
    end
  end

  describe "with the switch on" do
    setup do
      {:ok, _} = Languages.enable_system()
      :ok
    end

    test "the switch is on and the configuration is shown", %{conn: conn} do
      {:ok, view, html} = mount_as_admin(conn)

      assert switch_checked?(view)
      assert html =~ "Languages Enabled"
      assert html =~ "URL Behavior"
    end

    test "turning it off hides the configuration and keeps the languages", %{conn: conn} do
      {:ok, _} = Languages.add_language("ja")
      {:ok, view, _html} = mount_as_admin(conn)

      html = view |> element(@toggle) |> render_click()

      refute Languages.enabled?()
      refute switch_checked?(view)
      refute html =~ "URL Behavior"
      assert html =~ "the site is served in its default language only"

      # Off hides every language from the site, but the configuration is kept.
      assert Languages.get_enabled_languages() == []
      {:ok, _} = Languages.enable_system()
      assert "ja" in Enum.map(Languages.get_enabled_languages(), & &1.code)
    end
  end

  describe "restoring configuration" do
    test "turning it on preserves the default, order and disabled languages", %{conn: conn} do
      {:ok, _} = Languages.enable_system()
      {:ok, _} = Languages.add_language("ja")
      {:ok, _} = Languages.set_default_language("ja")
      {:ok, _} = Languages.disable_language("en-US")
      {:ok, _} = Languages.reorder_languages(["ja", "en-US"])
      before = Settings.get_json_setting("languages_config")
      {:ok, _} = Languages.disable_system()
      {:ok, view, _} = mount_as_admin(conn)

      html = view |> element(@toggle) |> render_click()

      assert Settings.get_json_setting("languages_config") == before
      assert Languages.get_default_language().code == "ja"
      assert Enum.map(Languages.get_languages(), & &1.code) == ["ja", "en-US"]
      refute html =~ "with English as the default"
    end
  end

  describe "page access while off" do
    test "Owner can reach the switch", %{conn: conn} do
      user = Auth.get_user_by_email("seed-owner@phoenixkit.test")
      {:ok, view, _} = mount_as_user(conn, user)
      assert has_element?(view, @toggle)
    end

    test "an Admin whose languages grant is revoked cannot mount", %{conn: conn} do
      {user, _} = create_admin_user()
      role = Roles.get_role_by_name("Admin")
      :ok = Permissions.revoke_permission(role.uuid, "languages")
      assert {:error, {:redirect, _}} = mount_as_user(conn, user)
    end
  end

  describe "custom roles" do
    test "full operator access requires languages even when multilingual support is off" do
      required =
        MapSet.difference(
          Permissions.enabled_module_keys(),
          MapSet.new(Permissions.admin_baseline_exclusions())
        )

      scope = %Scope{
        authenticated?: true,
        cached_roles: ["Custom"],
        cached_permissions: MapSet.delete(required, "languages")
      }

      refute Scope.holds_all_enabled_permissions?(scope)
      assert Scope.holds_all_enabled_permissions?(%{scope | cached_permissions: required})
    end
  end

  describe "preview controls" do
    test "each option changes the generated code, and unrelated setting keys are ignored", %{
      conn: conn
    } do
      {:ok, _} = Languages.enable_system()
      {:ok, view, _} = mount_as_admin(conn)

      for {setting, code} <- [
            {"switcher_show_flags", "show_flags={true}"},
            {"switcher_show_names", "show_names={true}"},
            {"switcher_show_native_names", "show_native_names={true}"},
            {"switcher_goto_home", "goto_home={true}"},
            {"switcher_hide_current", "hide_current={true}"}
          ] do
        before = view |> element("pre") |> render()

        view
        |> element("input[phx-value-setting='#{setting}']")
        |> render_click()

        after_click = view |> element("pre") |> render()
        assert before =~ code != (after_click =~ code)
      end

      assert view |> element("pre") |> render() =~ "show_flags={false}"
      assert view |> element("pre") |> render() =~ "show_names={false}"

      before = view |> element("pre") |> render()
      render_click(view, "toggle_switcher_setting", %{"setting" => "public_form_debug_mode"})
      assert view |> element("pre") |> render() == before
    end
  end

  describe "an open page after another admin turns languages off" do
    test "configuration events leave the saved settings alone and refresh the page", %{conn: conn} do
      for {event, params} <- [
            {"toggle_language_availability", %{"code" => "ja"}},
            {"set_default", %{"code" => "en-US"}},
            {"reorder_languages", %{"ordered_ids" => ["en-US"]}},
            {"toggle_default_language_no_prefix", %{}}
          ] do
        {:ok, _} = Languages.enable_system()
        {:ok, view, _} = mount_as_admin(conn)
        before = Settings.get_json_setting("languages_config")
        prefix_before = Languages.default_language_no_prefix?()
        {:ok, _} = Languages.disable_system()

        html = render_click(view, event, params)

        assert Settings.get_json_setting("languages_config") == before
        assert Languages.default_language_no_prefix?() == prefix_before
        refute Languages.enabled?()
        refute html =~ "URL Behavior"
        refute switch_checked?(view)
      end
    end
  end

  describe "the settings tab" do
    test "is a core admin tab, not one a module contributes" do
      tab = Enum.find(AdminTabs.default_tabs(), &(&1.id == :admin_settings_languages))

      assert tab
      assert tab.permission == "languages"
      assert tab.parent == :admin_settings
      assert tab.path == "/admin/settings/languages"

      refute Enum.any?(
               PhoenixKit.ModuleRegistry.all_settings_tabs(),
               &(&1.id == :admin_settings_languages)
             )
    end
  end
end
