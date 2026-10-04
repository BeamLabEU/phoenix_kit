defmodule PhoenixKitWeb.Live.Modules.Storage.SettingsTabsTest do
  @moduledoc """
  Tabs on the Media settings page (`/admin/settings/media`) — Buckets /
  Configuration / Tools / External libraries, the same `<.nav_tabs>` treatment the Email
  Sending and Sitemap settings pages already have.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.System.Dependencies
  alias PhoenixKit.Utils.Routes

  @media_settings_path Routes.path("/admin/settings/media")

  defp admin_conn(conn) do
    {user, _token} = create_admin_user()
    log_in_user(conn, user)
  end

  # `class={cond && "hidden"}` drops the `class` attribute entirely when
  # `cond` is false (Phoenix omits `nil`/`false` attribute values rather than
  # rendering `class=""`), so a bare `find/2` on the wrapper's stable id tells
  # visible from hidden.
  defp tab_visible?(html, dom_id) do
    case html |> Floki.parse_document!() |> Floki.find("##{dom_id}") do
      [el] -> "hidden" not in String.split(Floki.attribute(el, "class") |> List.first() || "")
      [] -> flunk("no element with id=#{dom_id} found")
    end
  end

  test "the tabs render, defaulting to Buckets", %{conn: conn} do
    {:ok, _view, html} = live(admin_conn(conn), @media_settings_path)

    assert html =~ "Buckets"
    assert html =~ "Configuration"
    assert html =~ "Tools"
    assert html =~ "External libraries"
    refute html =~ "Quick Actions"
    refute html =~ "Media System Architecture"

    assert tab_visible?(html, "media-tab-buckets")
    refute tab_visible?(html, "media-tab-configuration")
    refute tab_visible?(html, "media-tab-tools")
  end

  test "a tab is in the URL, so opening it directly (or refreshing) keeps it", %{conn: conn} do
    {:ok, _view, html} = live(admin_conn(conn), @media_settings_path <> "?tab=tools")

    refute tab_visible?(html, "media-tab-buckets")
    assert tab_visible?(html, "media-tab-tools")
  end

  test "an unknown tab opens Buckets", %{conn: conn} do
    {:ok, _view, html} = live(admin_conn(conn), @media_settings_path <> "?tab=nope")

    assert tab_visible?(html, "media-tab-buckets")
  end

  test "switching to Configuration reveals it and hides the others", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), @media_settings_path)

    html =
      view
      |> element("a[role=tab][href$=\"tab=configuration\"]")
      |> render_click()

    refute tab_visible?(html, "media-tab-buckets")
    assert tab_visible?(html, "media-tab-configuration")
    refute tab_visible?(html, "media-tab-tools")
    assert html =~ "Annotated Thumbnails"
    assert html =~ "Image Editing"

    # Copies, sizes and tiles are set on the profile and the variant set, not
    # here: this tab has no second editor for them.
    refute html =~ "Redundancy Copies"
    refute html =~ ~s(name="form_redundancy")
    refute html =~ "Auto-Generate Variants"
    refute html =~ "Deep Zoom Tile Generation"
    assert html =~ "Copies, sizes and tiles are set per library"
  end

  test "switching to Tools reveals its action buttons", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), @media_settings_path)

    html =
      view
      |> element("a[role=tab][href$=\"tab=tools\"]")
      |> render_click()

    refute tab_visible?(html, "media-tab-buckets")
    refute tab_visible?(html, "media-tab-configuration")
    assert tab_visible?(html, "media-tab-tools")
    assert html =~ "Variant sets"
    assert html =~ "Repair Media Module"
  end

  test "External libraries lists every tool with its status", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), @media_settings_path)

    html =
      view
      |> element("a[role=tab][href$=\"tab=external_libraries\"]")
      |> render_click()

    assert tab_visible?(html, "media-tab-external-libraries")

    for tool <- Dependencies.external_tools() do
      assert html =~ tool.name
    end

    refute html =~ "brew install"
    assert view |> element("button[phx-click=recheck_external_tools]") |> render_click()
  end

  test "the missing-tools warning is not tab-scoped", %{conn: conn} do
    {:ok, view, html} = live(admin_conn(conn), @media_settings_path)

    # Whatever the dependency status is on this machine, switching tabs must
    # not change whether the warning shows — it lives above the tab strip.
    before_tools = html =~ "Not found on this server"

    html_after =
      view
      |> element("a[role=tab][href$=\"tab=tools\"]")
      |> render_click()

    assert html_after =~ "Not found on this server" == before_tools
  end

  test "Apply Changes still saves what this tab keeps", %{conn: conn} do
    original = PhoenixKit.Settings.get_setting("storage_annotated_thumbnails_enabled", "false")

    # The row is rolled back with the sandbox; the cached copy is not.
    on_exit(fn ->
      PhoenixKit.Cache.invalidate(:settings, "storage_annotated_thumbnails_enabled")
    end)

    {:ok, view, _html} = live(admin_conn(conn), @media_settings_path <> "?tab=configuration")

    flipped = if original == "true", do: "false", else: "true"
    render_click(view, "toggle_form_annotated_thumbnails", %{})
    html = render_click(view, "apply_storage_settings", %{})

    assert html =~ "Storage settings updated successfully"

    assert PhoenixKit.Settings.get_setting("storage_annotated_thumbnails_enabled", "false") ==
             flipped
  end
end
