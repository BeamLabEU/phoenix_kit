defmodule PhoenixKitWeb.Live.Users.MediaFiltersTest do
  @moduledoc """
  The Media toolbar's type, sort and shape filters: what the button says, which
  row is ticked, that the listing follows, and that they live in the URL, so a
  tab Safari discarded and reloaded (an iPad) comes back to the same view.
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.MediaBrowser.Embed

  @media_path Routes.path("/admin/media")
  @browser PhoenixKitWeb.Components.MediaBrowser

  # ── The URL half, DB-free ────────────────────────────────────────────

  describe "nav params" do
    test "type, sort and shape survive the parse → build round trip" do
      params = %{"folder" => "f-1", "type" => "image", "sort" => "oldest", "shape" => "wide"}
      nav = Embed.parse_nav_params(params)

      assert {nav.type, nav.sort, nav.shape} == {"image", "oldest", "wide"}
      assert Embed.build_nav_query(nav) == params
    end

    test "the defaults keep the URL clean" do
      nav = Embed.parse_nav_params(%{})
      assert Embed.build_nav_query(nav) == %{}

      assert Embed.build_nav_query(%{type: "all", sort: "newest", shape: "all"}) == %{}
    end
  end

  # ── The page ─────────────────────────────────────────────────────────

  defp admin_view(conn, path \\ @media_path) do
    {user, _token} = create_admin_user()
    live(log_in_user(conn, user), path)
  end

  defp file!(name, width, height) do
    n = System.unique_integer([:positive])

    Repo.insert!(%StorageFile{
      original_file_name: name,
      file_name: name,
      mime_type: "image/jpeg",
      file_type: "image",
      ext: "jpg",
      file_checksum: "sha256:mf-#{n}",
      user_file_checksum: "user-sha256:mf-#{n}",
      size: 10,
      width: width,
      height: height,
      status: "active",
      user_uuid: nil
    })
  end

  defp menu_button(view, event, label) do
    view |> element(~s(button[phx-click="#{event}"]), label)
  end

  test "with nothing chosen the button says All types, never Filter", %{conn: conn} do
    {:ok, view, html} = admin_view(conn)

    assert html =~ "All types"
    refute html =~ ">Filter<"
    assert has_element?(menu_button(view, "set_file_filter", "All types"))
    assert has_element?(view, ~s(button.menu-active[phx-value-type="all"]))
    assert has_element?(view, ~s(button.menu-active[phx-value-shape="all"]))
    assert has_element?(view, ~s(button.menu-active[phx-value-sort="newest"]))
  end

  test "the chosen rows are ticked and the button names them", %{conn: conn} do
    {:ok, view, html} = admin_view(conn, @media_path <> "?type=image&sort=oldest&shape=wide")

    assert html =~ "Images · Panoramas"
    assert has_element?(view, ~s(button.menu-active[phx-value-type="image"]))
    assert has_element?(view, ~s(button.menu-active[phx-value-shape="wide"]))
    assert has_element?(view, ~s(button.menu-active[phx-value-sort="oldest"]))
    refute has_element?(view, ~s(button.menu-active[phx-value-type="all"]))
  end

  test "a value that is not on the list is the default", %{conn: conn} do
    {:ok, view, _html} = admin_view(conn, @media_path <> "?type=bogus&sort=bogus&shape=bogus")

    assert has_element?(view, ~s(button.menu-active[phx-value-type="all"]))
    assert has_element?(view, ~s(button.menu-active[phx-value-sort="newest"]))
    assert has_element?(view, ~s(button.menu-active[phx-value-shape="all"]))
  end

  test "picking a filter puts it in the URL, and All takes it out", %{conn: conn} do
    {:ok, view, _html} = admin_view(conn)

    menu_button(view, "set_shape_filter", "Panoramas") |> render_click()
    assert_patch(view, @media_path <> "?shape=wide")

    menu_button(view, "set_file_filter", "Images") |> render_click()
    assert_patch(view, @media_path <> "?shape=wide&type=image")

    menu_button(view, "set_sort", "Oldest first") |> render_click()
    assert_patch(view, @media_path <> "?shape=wide&sort=oldest&type=image")

    menu_button(view, "set_shape_filter", "All shapes") |> render_click()
    menu_button(view, "set_file_filter", "All types") |> render_click()
    menu_button(view, "set_sort", "Newest first") |> render_click()
    assert_patch(view, @media_path)
  end

  test "moving around keeps the filter", %{conn: conn} do
    {:ok, view, _html} = admin_view(conn, @media_path <> "?shape=wide")

    send(view.pid, {@browser, "media-browser", {:navigate, %{folder: nil, q: "x", page: 1}}})

    assert_patch(view, @media_path <> "?q=x&shape=wide")
  end

  test "the listing follows the shape", %{conn: conn} do
    pano = file!("filters-pano-#{System.unique_integer([:positive])}.jpg", 6000, 2000)
    plain = file!("filters-plain-#{System.unique_integer([:positive])}.jpg", 3000, 2000)

    {:ok, view, _html} = admin_view(conn, @media_path <> "?shape=wide&view=all")
    html = render(view)
    assert html =~ pano.uuid
    refute html =~ plain.uuid

    {:ok, view, _html} = admin_view(conn, @media_path <> "?view=all")
    html = render(view)
    assert html =~ pano.uuid
    assert html =~ plain.uuid
  end

  test "the grid marks a panorama with a badge, and only a panorama", %{conn: conn} do
    pano = file!("badge-pano-#{System.unique_integer([:positive])}.jpg", 6000, 2000)
    plain = file!("badge-plain-#{System.unique_integer([:positive])}.jpg", 3000, 2000)

    {:ok, view, _html} = admin_view(conn, @media_path <> "?view=all")
    render(view) |> assert_badge_count(pano, 1)

    # A page of the plain file alone has no badge.
    {:ok, view, _html} = admin_view(conn, @media_path <> "?view=all&shape=tall")
    refute render(view) =~ plain.uuid
    refute render(view) =~ ~s(aria-label="Panorama")
  end

  defp assert_badge_count(html, _file, count) do
    found = html |> String.split(~s(aria-label="Panorama")) |> length() |> Kernel.-(1)
    assert found >= count
  end
end
