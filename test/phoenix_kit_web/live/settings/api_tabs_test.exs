defmodule PhoenixKitWeb.Live.Settings.ApiTabsTest do
  @moduledoc """
  Settings -> API is split into tabs held in the URL (`?tab=…`, see
  `PhoenixKitWeb.Live.Settings.UrlTabs`): switches and modules, keys and service
  users, approvals and limits, sign-in (OAuth), and the guide. Every pane but the guide
  and the OAuth panel is rendered and only hidden, so a form in a hidden pane keeps what
  was typed; the guide is built, and the OAuth panel mounted, only when its tab is shown,
  again on each visit. The old guide address
  opens the guide tab.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/api")

  @panes %{
    "access" => ~w(api-switches api-modules-card),
    "keys" => ~w(api-keys-card api-service-users-card),
    "approvals" => ~w(api-approvals-card api-limits-card api-flow-card),
    "oauth" => [],
    "guide" => ~w(api-guide-page)
  }

  setup %{conn: conn} do
    KeyTestSupport.register_fake_module!()
    {admin, _token} = create_admin_user()
    {:ok, _} = Permissions.grant_permission(Roles.get_role_by_name("Admin").uuid, "api")

    %{conn: log_in_user(conn, admin)}
  end

  defp tab_path("access"), do: @path
  defp tab_path(tab), do: Routes.path("/admin/settings/api?tab=#{tab}")

  defp active_tab_hrefs(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([role="tablist"] [role="tab"].tab-active))
    |> LazyHTML.attribute("href")
  end

  defp assert_only_visible(view, tab) do
    assert has_element?(view, "#api-tab-#{tab}")
    refute has_element?(view, "#api-tab-#{tab}.hidden")

    for other <- Map.keys(@panes) -- [tab], has_element?(view, "#api-tab-#{other}") do
      assert has_element?(view, "#api-tab-#{other}.hidden"), "#api-tab-#{other} is shown"
    end
  end

  describe "the tabs" do
    test "the page opens on switches and modules, with a bare URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert active_tab_hrefs(view) == [@path]
      assert_only_visible(view, "access")
    end

    test "five tabs, each linking to its own ?tab=", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      hrefs =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([role="tablist"] [role="tab"]))
        |> LazyHTML.attribute("href")

      assert hrefs == Enum.map(~w(access keys approvals oauth guide), &tab_path/1)
    end

    test "?tab=keys shows keys and service users and hides the rest", %{conn: conn} do
      {:ok, view, _html} = live(conn, tab_path("keys"))

      assert active_tab_hrefs(view) == [tab_path("keys")]
      assert_only_visible(view, "keys")
    end

    test "?tab=approvals shows approvals and the limits", %{conn: conn} do
      {:ok, view, _html} = live(conn, tab_path("approvals"))

      assert active_tab_hrefs(view) == [tab_path("approvals")]
      assert_only_visible(view, "approvals")
    end

    test "an unknown tab opens the default", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/api?tab=nope"))

      assert active_tab_hrefs(view) == [@path]
      assert_only_visible(view, "access")
    end

    test "every card sits in its own tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, tab_path("guide"))

      for {tab, cards} <- @panes, card <- cards do
        assert has_element?(view, "#api-tab-#{tab} ##{card}"), "#{card} is not in #{tab}"
      end
    end

    test "the guide card and its button are gone", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#api-guide-card")
      refute has_element?(view, "#api-guide-link")
    end

    test "the dialogs open outside the panes", %{conn: conn} do
      {:ok, view, _html} = live(conn, tab_path("keys"))

      for {button, modal} <- [
            {"#api-new-key", "#create-api-key-modal"},
            {"#api-new-service-user", "#create-service-user-modal"}
          ] do
        view |> element(button) |> render_click()

        assert has_element?(view, modal)
        refute has_element?(view, ~s([id^="api-tab-"] #{modal}))
      end
    end

    test "clicking a tab patches the URL and keeps the page mounted", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      pid = view.pid

      view |> element(~s([role="tab"][href="#{tab_path("keys")}"])) |> render_click()

      assert_patch(view, tab_path("keys"))
      assert view.pid == pid
      assert_only_visible(view, "keys")
    end
  end

  describe "the OAuth tab" do
    test "?tab=oauth mounts the panel and hides the rest", %{conn: conn} do
      {:ok, view, _html} = live(conn, tab_path("oauth"))

      assert active_tab_hrefs(view) == [tab_path("oauth")]
      assert_only_visible(view, "oauth")
      assert has_element?(view, "#api-tab-oauth #api-oauth-switches")
    end

    test "is mounted only when its tab is shown", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, "#api-oauth")

      view |> element(~s([role="tab"][href="#{tab_path("oauth")}"])) |> render_click()

      assert_patch(view, tab_path("oauth"))
      assert has_element?(view, "#api-tab-oauth #api-oauth-switches")
    end
  end

  describe "the guide tab" do
    test "?tab=guide renders the guide", %{conn: conn} do
      {:ok, view, _html} = live(conn, tab_path("guide"))

      assert active_tab_hrefs(view) == [tab_path("guide")]
      assert_only_visible(view, "guide")
      assert has_element?(view, "#api-tab-guide #api-guide-page")

      for section <- ~w(guide-status guide-endpoints guide-connect guide-tools guide-keys
                        guide-danger guide-errors) do
        assert has_element?(view, "#api-tab-guide ##{section}")
      end
    end

    test "is built only when its tab is shown, again on each visit", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#api-guide-page")

      view |> element(~s([role="tab"][href="#{tab_path("guide")}"])) |> render_click()

      assert_patch(view, tab_path("guide"))
      assert has_element?(view, "#api-tab-guide #api-guide-page")
    end

    test "the page title stays the page's own", %{conn: conn} do
      {:ok, _view, html} = live(conn, tab_path("guide"))

      assert html |> LazyHTML.from_document() |> LazyHTML.query("title") |> LazyHTML.text() =~
               "API"

      refute html |> LazyHTML.from_document() |> LazyHTML.query("title") |> LazyHTML.text() =~
               "API guide"
    end
  end

  describe "a role that holds only api" do
    setup do
      {user, role} = KeyTestSupport.user_with([])
      assert Permissions.get_permissions_for_role(role.uuid) == ["api"]

      %{api_conn: log_in_user(build_conn(), user)}
    end

    test "opens every tab with its cards", %{api_conn: conn} do
      for {tab, cards} <- @panes do
        assert {:ok, view, _html} = live(conn, tab_path(tab)), "?tab=#{tab} is refused"
        assert_only_visible(view, tab)
        for card <- cards, do: assert(has_element?(view, "#api-tab-#{tab} ##{card}"))
      end
    end

    test "follows the old guide address to the guide tab", %{api_conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, Routes.path("/admin/settings/api/guide"))

      assert to == tab_path("guide")
      assert {:ok, view, _html} = live(conn, to)
      assert_only_visible(view, "guide")
    end
  end

  describe "the old guide address" do
    test "opens the guide tab", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, Routes.path("/admin/settings/api/guide"))

      assert to == tab_path("guide")
    end

    test "keeps the locale of the address", %{conn: conn} do
      Settings.update_setting("languages_enabled", "true")

      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{"code" => "en", "name" => "English", "is_default" => true, "is_enabled" => true},
          %{"code" => "et", "name" => "Estonian", "is_default" => false, "is_enabled" => true}
        ]
      })

      on_exit(fn -> Settings.update_setting("languages_enabled", "false") end)

      old = Routes.path("/admin/settings/api/guide", locale: "et")
      assert old =~ "/et/admin/settings/api/guide"

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, old)
      assert to == Routes.path("/admin/settings/api?tab=guide", locale: "et")
      assert to =~ "/et/admin/settings/api?tab=guide"
    end

    test "is still gated by api" do
      {admin, _token} = create_admin_user()
      :ok = Permissions.revoke_permission(Roles.get_role_by_name("Admin").uuid, "api")

      result = live(log_in_user(build_conn(), admin), Routes.path("/admin/settings/api/guide"))

      assert match?({:error, {kind, _}} when kind in [:redirect, :live_redirect], result)
      {:error, {_kind, %{to: to}}} = result
      refute to =~ "tab=guide"
    end
  end
end
