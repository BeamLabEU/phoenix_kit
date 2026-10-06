defmodule PhoenixKitWeb.Live.Settings.UrlTabsTest do
  @moduledoc """
  The tab of a settings page lives in the URL (`?tab=…`), so a refresh, a shared
  link and Back keep it. Every page is checked the same way: the default tab has
  a bare URL, a named tab opens straight away, an unknown one falls back to the
  default, and clicking a tab patches (no remount).
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Settings.UrlTabs

  # {page, a tab that is not the default}
  @pages [
    {"/admin/settings", "datetime"},
    {"/admin/settings/users", "sessions"},
    {"/admin/settings/authorization", "methods"},
    {"/admin/settings/organization", "bank"},
    {"/admin/settings/website-access", "redirect"},
    {"/admin/settings/email-sending", "transport"},
    {"/admin/settings/integrations", "personal"},
    {"/admin/settings/media", "tools"},
    {"/admin/settings/crawlers", "bots"},
    {"/admin/settings/sitemap", "advanced"}
  ]

  defp active_tab_hrefs(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s([role="tablist"]))
    |> List.first()
    |> Floki.find(~s([role="tab"].tab-active))
    |> Enum.flat_map(&Floki.attribute(&1, "href"))
  end

  setup %{conn: conn} do
    {user, _token} = create_admin_user()
    # Crawlers and Sitemap refuse a disabled module for everyone.
    {:ok, _} = Crawlers.enable_module()
    {:ok, _} = Settings.update_boolean_setting("sitemap_enabled", true)
    admin_role = Roles.get_role_by_name("Admin")
    {:ok, _} = Permissions.grant_permission(admin_role.uuid, "integrations_system")
    %{conn: log_in_user(conn, user)}
  end

  for {page, tab} <- @pages do
    describe page do
      test "opens on the default tab with a bare URL", %{conn: conn} do
        {:ok, _view, html} = live(conn, Routes.path(unquote(page)))

        assert [href] = active_tab_hrefs(html)
        refute href =~ "tab="
      end

      test "?tab=#{tab} opens that tab, so a refresh keeps it", %{conn: conn} do
        {:ok, _view, html} = live(conn, Routes.path(unquote(page) <> "?tab=#{unquote(tab)}"))

        assert [href] = active_tab_hrefs(html)
        assert href =~ "tab=#{unquote(tab)}"
      end

      test "an unknown tab falls back to the default", %{conn: conn} do
        {:ok, _view, html} = live(conn, Routes.path(unquote(page) <> "?tab=nope"))

        assert [href] = active_tab_hrefs(html)
        refute href =~ "tab="
      end

      test "clicking a tab patches the URL", %{conn: conn} do
        {:ok, view, _html} = live(conn, Routes.path(unquote(page)))

        view |> element(~s(a[role="tab"][href$="tab=#{unquote(tab)}"])) |> render_click()

        assert_patch(view, Routes.path(unquote(page) <> "?tab=#{unquote(tab)}"))
      end
    end
  end

  describe "UrlTabs" do
    @tabs [%{id: "a"}, %{id: "b"}, %{id: "c d"}]

    test "active/2 takes a known tab and otherwise the first" do
      assert UrlTabs.active(%{"tab" => "b"}, @tabs) == "b"
      assert UrlTabs.active(%{"tab" => "zzz"}, @tabs) == "a"
      assert UrlTabs.active(%{"tab" => ["b"]}, @tabs) == "a"
      assert UrlTabs.active(%{}, @tabs) == "a"
    end

    test "patch_links/2 leaves the default bare and encodes the rest" do
      assert [a, b, c] = UrlTabs.patch_links(@tabs, "/admin/settings/users")

      assert a.patch == Routes.path("/admin/settings/users")
      assert b.patch == Routes.path("/admin/settings/users?tab=b")
      assert c.patch == Routes.path("/admin/settings/users?tab=c+d")
    end
  end
end
