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
