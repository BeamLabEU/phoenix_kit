defmodule PhoenixKit.Integration.Users.PermissionsMatrixPhoneTest do
  @moduledoc """
  On a phone the pinned first column of the permissions matrix is capped, so
  the role columns scroll beside it instead of being covered, and the toggle
  buttons keep a touch-sized target. From `md` up the column is unchanged.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    {admin, _token} = create_admin_user()
    {:ok, conn: log_in_user(conn, admin)}
  end

  defp classes(node), do: node |> Floki.attribute("class") |> List.first() |> String.split()

  test "the pinned first column is capped on small screens and unchanged from md up", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, Routes.path("/admin/users/permissions"))
    doc = view |> render() |> Floki.parse_document!()

    header = doc |> Floki.find("table thead th") |> hd()
    body_cells = Floki.find(doc, "table tbody tr > td:first-child[title]")
    total = doc |> Floki.find("table tbody tr:last-child > td") |> hd()

    assert body_cells != []

    for cell <- [header, total | body_cells] do
      cls = classes(cell)
      assert "sticky" in cls
      assert "left-0" in cls
      assert "max-md:max-w-[40vw]" in cls
      assert "max-md:break-words" in cls
      # the single-line column only from md up, so a long label wraps on a phone
      assert "md:whitespace-nowrap" in cls
      refute "whitespace-nowrap" in cls
    end

    # a pinned cell is opaque on a phone, or the scrolled columns show through
    assert "max-md:bg-primary" in classes(header)
    assert "max-md:bg-base-100" in classes(total)

    # the full label stays reachable when it wraps
    assert Enum.all?(body_cells, &(Floki.attribute(&1, "title") != [""]))
  end

  test "an editable toggle is at least 32px square on small screens", %{conn: conn} do
    {:ok, view, _html} = live(conn, Routes.path("/admin/users/permissions"))
    doc = view |> render() |> Floki.parse_document!()

    toggles = Floki.find(doc, ~s(button[phx-click="toggle_permission"]))
    assert toggles != []

    for toggle <- toggles do
      cls = classes(toggle)
      # min-h-11 / min-w-11 = 2.75rem = 44px, the touch-target guidance
      assert "max-md:min-h-11" in cls
      assert "max-md:min-w-11" in cls
      assert "max-md:inline-flex" in cls
    end
  end
end
