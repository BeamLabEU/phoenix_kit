defmodule PhoenixKitWeb.Live.LibrariesSyncTest do
  @moduledoc """
  The Sync column of the Libraries tab (Settings → Media): each library's state
  (`LibraryState`) with Check now, Pause and Resume for those who may use them
  (`jobs.manage` and `media.manage`, checked by the Jobs context), updated live as
  the library's reconcile run moves.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Jobs
  alias PhoenixKit.Jobs.{Engine, Run}
  alias PhoenixKit.Modules.Storage.Jobs.Reconcile
  alias PhoenixKit.Modules.Storage.{Libraries, Reconciler}
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    {user, _token} = create_admin_user()
    admin = Roles.get_role_by_name("Admin")

    for key <- ~w(jobs jobs.manage media media.manage) do
      {:ok, _} = Permissions.grant_permission(admin.uuid, key)
    end

    {:ok, library} =
      Libraries.create_system_library(%{name: "Sync #{System.unique_integer([:positive])}"})

    %{conn: log_in_user(conn, user), library: library, admin: admin}
  end

  defp libraries(conn) do
    {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media"))
    render_patch(view, Routes.path("/admin/settings/media?tab=libraries"))
    view
  end

  defp cell(library), do: "#media-libraries-sync-#{library.uuid}"

  defp run_for(library) do
    Jobs.active_run(Reconcile.kind(), {"library", to_string(library.uuid)})
  end

  test "a library with nothing out of date is up to date, and can be checked", ctx do
    view = libraries(ctx.conn)

    assert has_element?(view, "#{cell(ctx.library)} [data-sync-state=up_to_date]", "Up to date")
    refute run_for(ctx.library)

    view
    |> element("#{cell(ctx.library)} button", "Check now")
    |> render_click()

    assert %Run{mode: "manual", state: "queued"} = run_for(ctx.library)
    assert has_element?(view, "#{cell(ctx.library)} [data-sync-state=syncing]", "Syncing")
    assert has_element?(view, "#{cell(ctx.library)} a", "Details")
  end

  test "a syncing library can be paused and resumed from the tab", ctx do
    {:ok, run, :started} =
      Jobs.System.start(Reconcile, {"library", to_string(ctx.library.uuid)})

    view = libraries(ctx.conn)
    assert has_element?(view, "#{cell(ctx.library)} [data-sync-state=syncing]")

    view |> element("#{cell(ctx.library)} button", "Pause") |> render_click()
    assert %{state: "paused"} = Repo.get!(Run, run.uuid)
    assert has_element?(view, "#{cell(ctx.library)} [data-sync-state=paused]", "Paused")

    view |> element("#{cell(ctx.library)} button", "Resume") |> render_click()
    assert %{state: "queued"} = Repo.get!(Run, run.uuid)
    assert has_element?(view, "#{cell(ctx.library)} [data-sync-state=syncing]")
  end

  test "follows the run when something else moves it", ctx do
    {:ok, run, :started} =
      Jobs.System.start(Reconcile, {"library", to_string(ctx.library.uuid)})

    view = libraries(ctx.conn)
    assert has_element?(view, "#{cell(ctx.library)} [data-sync-state=syncing]")

    {:ok, _} = Engine.transition(run.uuid, {:pause, nil})
    # The event handler queues a component update on the LiveView's mailbox.
    # Let it handle the event before the test proxy requests the rendered state.
    :sys.get_state(view.pid)

    assert has_element?(view, "#{cell(ctx.library)} [data-sync-state=paused]")
  end

  test "refreshes derived state even when no run event arrives", ctx do
    {:ok, run, :started} =
      Jobs.System.start(Reconcile, {"library", ctx.library.uuid})

    view = libraries(ctx.conn)
    assert has_element?(view, "#{cell(ctx.library)} [data-sync-state=syncing]")

    # Simulate a missed notification: the next periodic refresh must catch up.
    Repo.update_all(from(r in Run, where: r.uuid == ^run.uuid), set: [state: "paused"])
    send(view.pid, :refresh_library_sync)
    # The handler queues a send_update to itself. Wait until it has handled
    # the refresh before asking the test proxy to inspect the component.
    :sys.get_state(view.pid)

    assert has_element?(view, "#{cell(ctx.library)} [data-sync-state=paused]")
  end

  test "someone who may not manage jobs sees the state but no buttons", ctx do
    :ok = Permissions.revoke_permission(ctx.admin.uuid, "jobs.manage")
    {:ok, _run, :started} = Jobs.System.start(Reconcile, {"library", to_string(ctx.library.uuid)})

    view = libraries(ctx.conn)

    assert has_element?(view, "#{cell(ctx.library)} [data-sync-state=syncing]")
    refute has_element?(view, "#{cell(ctx.library)} button")
    refute has_element?(view, "#{cell(ctx.library)} button", "Check now")
  end

  test "a hand-made sync event from someone who may not is refused", ctx do
    :ok = Permissions.revoke_permission(ctx.admin.uuid, "jobs.manage")
    view = libraries(ctx.conn)

    view
    |> with_target("#media-libraries")
    |> render_click("sync", %{"action" => "check", "uuid" => ctx.library.uuid})

    refute run_for(ctx.library)
  end

  test "an unknown action or library does nothing", ctx do
    view = libraries(ctx.conn)

    view
    |> with_target("#media-libraries")
    |> render_click("sync", %{"action" => "explode", "uuid" => ctx.library.uuid})

    view
    |> with_target("#media-libraries")
    |> render_click("sync", %{"action" => "check", "uuid" => Ecto.UUID.generate()})

    refute run_for(ctx.library)
    assert Reconciler.counts_by_library() |> Map.has_key?(to_string(ctx.library.uuid)) == false
  end
end
