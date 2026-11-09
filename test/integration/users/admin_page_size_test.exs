defmodule PhoenixKit.Integration.Users.AdminPageSizeTest do
  @moduledoc """
  One rows-per-page size per person (`PhoenixKitWeb.PageSize`): picked on any
  admin list, it opens every list at that size from then on, while a link that
  names a size still wins. And one footer (`<.pagination_bar>`) on all of them.

  `async: false`: the Users list reloads on every user event of the suite.
  Live Sessions needs its own Presence server and is pinned in
  `live_sessions_pagination_test.exs`.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Users.ViewPrefs
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.PageSize

  @lists [
    {"/admin/users", "users-table", "users-pagination"},
    {"/admin/users/roles", "roles-table", "roles-pagination"},
    {"/admin/users/sessions", "sessions-table", "sessions-pagination"}
  ]

  defp selected_size(html) do
    case Regex.run(~r/<option value="([^"]+)"\s+selected/, html) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp pick(view, size) do
    view |> element("form[phx-change=change_per_page]") |> render_change(%{"per_page" => size})
  end

  setup %{conn: conn} do
    {admin, _token} = create_admin_user()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  test "a size picked on one list opens every list at it", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, Routes.path("/admin/users"))
    pick(view, "50")
    assert PageSize.saved(admin) == 50

    for {path, _table, _bar} <- @lists do
      {:ok, _view, html} = live(conn, Routes.path(path))
      assert selected_size(html) == "50", path
    end
  end

  test "a link that names a size wins, and changes nothing saved", %{conn: conn, admin: admin} do
    {:ok, _} = ViewPrefs.put(admin, "admin.lists", %{"page_size" => 50})

    {:ok, _view, html} = live(conn, Routes.path("/admin/users/roles?per_page=10"))
    assert selected_size(html) == "10"
    assert PageSize.saved(admin) == 50
  end

  test "Clear Filters keeps the person's size", %{conn: conn, admin: admin} do
    {:ok, _} = ViewPrefs.put(admin, "admin.lists", %{"page_size" => 50})

    {:ok, view, _html} = live(conn, Routes.path("/admin/users?status=inactive&per_page=10"))
    render_click(view, "clear_filters", %{})

    assert_patch(view, Routes.path("/admin/users"))
    assert selected_size(render(view)) == "50"
  end

  test "Auto is remembered, and the size it measured is not saved over it", %{
    conn: conn,
    admin: admin
  } do
    {:ok, view, _html} = live(conn, Routes.path("/admin/users/roles"))
    pick(view, "auto")
    assert PageSize.saved(admin) == :auto

    # What the PageSizeAutoFit hook pushes once it has measured the table.
    render_hook(view, "change_per_page", %{"per_page" => "50", "auto" => "1"})
    assert PageSize.saved(admin) == :auto

    {:ok, _view, html} = live(conn, Routes.path("/admin/users/sessions"))
    assert selected_size(html) == "auto"
    assert html =~ ~s(data-auto="true")
  end

  test "each person has their own size", %{conn: conn, admin: admin} do
    {:ok, _} = ViewPrefs.put(admin, "admin.lists", %{"page_size" => 50})
    {other, _token} = create_admin_user()

    {:ok, _view, html} = live(log_in_user(build_conn(), other), Routes.path("/admin/users"))
    assert selected_size(html) == "25"

    {:ok, _view, html} = live(conn, Routes.path("/admin/users"))
    assert selected_size(html) == "50"
  end

  test "a stored value no list offers reads as none", %{conn: conn, admin: admin} do
    for bad <- [7, "50", "big", 1_000_000] do
      {:ok, _} = ViewPrefs.put(admin, "admin.lists", %{"page_size" => bad})
      assert PageSize.saved(admin) == nil

      {:ok, _view, html} = live(conn, Routes.path("/admin/users"))
      assert selected_size(html) == "25", inspect(bad)
    end
  end

  test "every list has the same footer", %{conn: conn} do
    for {path, table, bar_id} <- @lists do
      {:ok, _view, html} = live(conn, Routes.path(path))
      doc = Floki.parse_document!(html)

      assert [bar] = Floki.find(doc, "##{bar_id}"), path
      assert Floki.text(bar) =~ "Showing"
      assert [select] = Floki.find(bar, "select#" <> bar_id <> "-per-page")
      assert Floki.attribute(select, "data-table-id") == [table]

      assert bar |> Floki.find("option") |> Enum.flat_map(&Floki.attribute(&1, "value")) ==
               ["10", "25", "50", "100", "auto"]
    end
  end
end
