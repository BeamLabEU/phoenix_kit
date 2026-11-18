defmodule PhoenixKitWeb.Live.ScopeBadgesLiveTest do
  @moduledoc """
  An open admin page redraws the host's per-viewer menu badges
  (`PhoenixKit.Dashboard.ScopeBadges`) when `ScopeBadges.changed/1` names its account,
  without a reload and without the message reaching the page.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Dashboard.{Registry, ScopeBadges}
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @badge ~s(a[data-tab-id="admin_users"] .badge)

  defmodule Host do
    @behaviour PhoenixKit.Dashboard.ScopeBadges

    alias PhoenixKit.Dashboard.Badge

    @impl true
    def badges(_scope) do
      case :persistent_term.get({__MODULE__, :count}, 0) do
        0 -> %{admin_users: nil}
        count -> %{admin_users: Badge.count(count, color: :primary)}
      end
    end

    def set(count), do: :persistent_term.put({__MODULE__, :count}, count)
  end

  setup %{conn: conn} do
    previous = Application.fetch_env(:phoenix_kit, :scope_badges)
    Application.put_env(:phoenix_kit, :scope_badges, Host)
    Host.set(0)

    on_exit(fn ->
      :persistent_term.erase({Host, :count})

      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :scope_badges, value)
        :error -> Application.delete_env(:phoenix_kit, :scope_badges)
      end
    end)

    # The registry is not part of the test supervision tree; the menu is drawn only with one.
    refute Process.whereis(Registry), "a registry is already running - this suite starts its own"
    start_supervised!(Registry)
    :sys.get_state(Registry)

    owner = Auth.get_user_by_email("seed-owner@phoenixkit.test")
    %{conn: log_in_user(conn, owner), owner: owner}
  end

  # The change is a message to the page, and the redraw a second one it sends itself.
  defp settle(view) do
    _ = :sys.get_state(view.pid)
    _ = :sys.get_state(view.pid)
    :ok
  end

  test "the badge follows the count while the page is open", %{conn: conn, owner: owner} do
    {:ok, view, _html} = live(conn, Routes.path("/admin/users"))
    assert has_element?(view, ~s(a[data-tab-id="admin_users"]))
    refute has_element?(view, @badge)

    Host.set(4)
    ScopeBadges.changed(owner.uuid)
    settle(view)
    assert has_element?(view, @badge, "4")

    Host.set(2)
    ScopeBadges.changed(owner)
    settle(view)
    assert has_element?(view, @badge, "2")

    Host.set(0)
    ScopeBadges.changed(owner.uuid)
    settle(view)
    refute has_element?(view, @badge)
  end

  # Most core pages hand the layout `assigns[:phoenix_kit_current_scope]`, which turns
  # change tracking off, so any assign redraws them. A page (or a host's page) that
  # writes `@phoenix_kit_current_scope` is tracked, and redraws only because the scope
  # is marked changed. Relationship types is such a page.
  test "a page that passes the scope change-tracked redraws too", %{conn: conn, owner: owner} do
    {:ok, view, _html} = live(conn, Routes.path("/admin/users/relationship-types"))
    assert has_element?(view, ~s(a[data-tab-id="admin_users"]))
    refute has_element?(view, @badge)

    Host.set(5)
    ScopeBadges.changed(owner.uuid)
    settle(view)
    assert has_element?(view, @badge, "5")
  end

  test "another account's change leaves the page alone", %{conn: conn, owner: owner} do
    {:ok, view, _html} = live(conn, Routes.path("/admin/users"))

    Host.set(6)
    ScopeBadges.changed(UUIDv7.generate())
    settle(view)
    refute has_element?(view, @badge)

    # The page is alive and still listening for its own account.
    ScopeBadges.changed(owner.uuid)
    settle(view)
    assert has_element?(view, @badge, "6")
  end

  test "a burst of changes is drawn once", %{conn: conn, owner: owner} do
    {:ok, view, _html} = live(conn, Routes.path("/admin/users"))
    Host.set(9)

    :sys.suspend(view.pid)
    for _ <- 1..5, do: ScopeBadges.changed(owner.uuid)
    :sys.resume(view.pid)
    settle(view)

    assert has_element?(view, @badge, "9")
    refute view.pid |> :sys.get_state() |> inspect() =~ "redraw_queued?: true"
  end
end
