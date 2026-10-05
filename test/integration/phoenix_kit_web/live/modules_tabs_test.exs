defmodule PhoenixKitWeb.Live.ModulesTabsTest do
  @moduledoc """
  Pins the Active/Disabled/Not Installed tab strip on the admin Modules page
  (`/admin/modules`), and that Storage and Notifications no longer render as
  cards there — both are core capabilities configured entirely from their own
  Settings pages, not real install/uninstall toggles (see their moduledocs).
  Languages and Jobs are core too: Languages' multi-language switch is on
  Settings → Languages, so it has no card either.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Utils.Routes

  @modules_path Routes.path("/admin/modules")
  @crawlers_description "Control how search engines and AI bots crawl and index this site"

  setup do
    on_exit(fn -> Crawlers.disable_module() end)
    :ok
  end

  defp mount_as_admin(conn) do
    {user, _token} = create_admin_user()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> log_in_user(user)

    {:ok, view, html} = live(conn, @modules_path)
    {view, html}
  end

  describe "?tab=" do
    defp mount_tab(conn, query) do
      {user, _token} = create_admin_user()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> log_in_user(user)

      {:ok, _view, html} = live(conn, @modules_path <> query)
      html
    end

    # A disabled module's page sends its visitor here. On the Active tab the
    # module it is about is not listed at all, which read as a missing route.
    test "disabled opens the Disabled tab, where a switched-off module's card is", %{conn: conn} do
      Crawlers.disable_module()

      refute mount_tab(conn, "") =~ @crawlers_description
      assert mount_tab(conn, "?tab=disabled") =~ @crawlers_description
    end

    test "anything else is the Active tab", %{conn: conn} do
      Crawlers.disable_module()

      refute mount_tab(conn, "?tab=nonsense") =~ @crawlers_description
    end

    test "a disabled module's own page redirects to the Disabled tab, with the reason", %{
      conn: conn
    } do
      Crawlers.disable_module()
      {user, _token} = create_admin_user()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> log_in_user(user)

      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(conn, Routes.path("/admin/settings/crawlers"))

      assert to =~ "/admin/modules?tab=disabled"
      # The admin on_mount hook answers before the page's own guard does.
      assert flash["error"] == "Crawlers module is not enabled"
    end
  end

  test "renders the Active/Disabled/Not Installed tab strip", %{conn: conn} do
    {_view, html} = mount_as_admin(conn)

    assert html =~ "Active"
    assert html =~ "Disabled"
    assert html =~ "Not Installed"
  end

  test "Languages is not a module card: its switch is on its own settings page", %{conn: conn} do
    {view, html} = mount_as_admin(conn)

    refute html =~ "Manage language module and translations"

    disabled_html = render_click(view, "switch_modules_tab", %{"tab" => "disabled"})
    refute disabled_html =~ "Manage language module and translations"
  end

  test "Storage and Notifications no longer render as module cards", %{conn: conn} do
    {view, html} = mount_as_admin(conn)

    refute html =~ "Always Enabled"
    refute html =~ "Per-user in-app notifications driven by the activity log"

    disabled_html = render_click(view, "switch_modules_tab", %{"tab" => "disabled"})
    refute disabled_html =~ "Always Enabled"
    refute disabled_html =~ "Per-user in-app notifications driven by the activity log"
  end

  test "a disabled module shows under Disabled, not Active; toggling moves it live", %{
    conn: conn
  } do
    refute Crawlers.module_enabled?()
    {view, active_html} = mount_as_admin(conn)

    # Default tab is "active" — a disabled module must not appear there.
    refute active_html =~ @crawlers_description

    disabled_html = render_click(view, "switch_modules_tab", %{"tab" => "disabled"})
    assert disabled_html =~ @crawlers_description

    # Enable it while still on the Disabled tab — it must disappear live,
    # without a page reload, because the toggle recomputes tab membership.
    still_disabled_tab_html = render_click(view, "toggle_module", %{"key" => "crawlers"})
    assert Crawlers.module_enabled?()
    refute still_disabled_tab_html =~ @crawlers_description

    active_again_html = render_click(view, "switch_modules_tab", %{"tab" => "active"})
    assert active_again_html =~ @crawlers_description
  end
end
