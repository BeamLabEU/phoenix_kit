defmodule PhoenixKit.Integration.Users.LiveSessionsPaginationTest do
  @moduledoc """
  Rows-per-page on the Live Sessions tab. Presence is one named GenServer
  that a host app supervises but this suite does not start, so each test
  starts its own (`async: false` — the name is global) and tracks its sessions
  from a process that outlives the assertions.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Admin.SimplePresence
  alias PhoenixKit.Users.ViewPrefs
  alias PhoenixKit.Utils.Routes

  # Two pages at the default of 25, one at 50.
  @sessions 30

  setup %{conn: conn} do
    start_supervised!(SimplePresence)
    {admin, _token} = create_admin_user()

    # Presence drops a session when its tracking process exits, so the
    # tracker lives until the test is done and is then told to stop.
    parent = self()

    tracker =
      spawn_link(fn ->
        for i <- 1..@sessions do
          :ok =
            SimplePresence.track_anonymous("pag-#{System.unique_integer([:positive])}-#{i}", %{
              ip_address: "127.0.0.1",
              user_agent: "pagination-test",
              current_page: "/"
            })
        end

        send(parent, :tracked)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :tracked, 5_000
    on_exit(fn -> send(tracker, :stop) end)

    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  defp selected_size(html) do
    case Regex.run(~r/<option value="([^"]+)"\s+selected/, html) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp page_links(html) do
    ~r/page=(\d+)(?:"|&amp;)/
    |> Regex.scan(html)
    |> Enum.map(fn [_, n] -> String.to_integer(n) end)
    |> Enum.uniq()
  end

  test "per_page from the URL is honoured, unlisted values fall back to 25", %{conn: conn} do
    {:ok, _view, html} = live(conn, Routes.path("/admin/users/live_sessions"))
    assert selected_size(html) == "25"
    assert 2 in page_links(html)

    {:ok, _view, html} = live(conn, Routes.path("/admin/users/live_sessions?per_page=50"))
    assert selected_size(html) == "50"
    assert page_links(html) == []

    {:ok, _view, html} = live(conn, Routes.path("/admin/users/live_sessions?per_page=7"))
    assert selected_size(html) == "25"
  end

  test "choosing a size from the selector resets to page 1", %{conn: conn} do
    {:ok, view, _html} = live(conn, Routes.path("/admin/users/live_sessions?page=2"))

    view
    |> element("form[phx-change=change_per_page]")
    |> render_change(%{"per_page" => "50"})

    # Saved as the admin's size, so the address no longer needs it.
    assert_patch(view, Routes.path("/admin/users/live_sessions"))
    assert selected_size(render(view)) == "50"
  end

  test "opens at the person's saved size, with the shared footer", %{conn: conn, admin: admin} do
    {:ok, _} = ViewPrefs.put(admin, "admin.lists", %{"page_size" => 50})

    {:ok, _view, html} = live(conn, Routes.path("/admin/users/live_sessions"))
    assert selected_size(html) == "50"
    assert html =~ ~s(id="live-sessions-pagination")
    assert html =~ ~s(data-table-id="live-sessions-table")
  end

  test "a page past the end is clamped to the last page", %{conn: conn} do
    {:ok, _view, html} = live(conn, Routes.path("/admin/users/live_sessions?page=99"))
    assert html =~ ~r/btn-active[^>]*>\s*2\s*</
  end
end
