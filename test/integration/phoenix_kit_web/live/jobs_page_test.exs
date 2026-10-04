defmodule PhoenixKitWeb.Live.JobsPageTest do
  @moduledoc """
  The Jobs page's Runs tab: it is core (always reachable to a holder of `jobs`),
  it lists runs with state, progress and history, it updates as runs move, and its
  controls are offered — and honoured — only to those who hold `jobs.manage`.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Jobs
  alias PhoenixKit.Jobs.{Engine, Run, SweepWorker}
  alias PhoenixKit.Test.JobKinds.Counter
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/jobs")

  setup %{conn: conn} do
    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    {user, _token} = create_admin_user()
    admin = Roles.get_role_by_name("Admin")
    {:ok, _} = Permissions.grant_permission(admin.uuid, "jobs")
    # a sweeper that has been seen, so the warning is not the subject
    {:ok, _} =
      PhoenixKit.Settings.update_setting(
        SweepWorker.last_sweep_setting(),
        DateTime.to_iso8601(DateTime.utc_now())
      )

    %{conn: log_in_user(conn, user), admin: admin, user: user}
  end

  defp manage(admin), do: {:ok, _} = Permissions.grant_permission(admin.uuid, "jobs.manage")

  defp start!(kind \\ Counter, scope \\ :site, opts \\ []) do
    {:ok, run, :started} = Jobs.System.start(kind, scope, opts)
    run
  end

  defp reload(run), do: Repo.get!(Run, run.uuid)

  test "is always on: a holder of jobs reaches it, on the Runs tab", %{conn: conn} do
    {:ok, _view, html} = live(conn, @path)

    assert html =~ "Runs"
    assert html =~ "Queue"
    assert html =~ "Scheduled"
    assert html =~ "No runs match."
  end

  test "lists a run with its title, kind, state and progress", %{conn: conn} do
    run = start!(Counter, :site, args: %{steps: 4})
    {:ok, claimed, token} = Engine.claim(run.uuid, 1)

    {:ok, _} =
      Engine.checkpoint(claimed.uuid, token, {:more, %{cursor: %{}, done: 10, total: 40}, []})

    {:ok, _view, html} = live(conn, @path)

    assert html =~ "Count to 4"
    assert html =~ "test.counter"
    assert html =~ "Running"
    assert html =~ "10 / 40"
    assert html =~ ~s(value="25")
  end

  test "a viewer sees the runs but no controls", %{conn: conn} do
    start!()
    {:ok, view, html} = live(conn, @path)

    assert html =~ "Count to"
    refute html =~ ~s(phx-value-action="pause")
    refute has_element?(view, ~s(button[phx-click="run_control"]))
  end

  test "someone who may manage jobs pauses, resumes and cancels from the table", %{
    conn: conn,
    admin: admin
  } do
    manage(admin)
    run = start!()
    {:ok, view, html} = live(conn, @path)
    assert html =~ ~s(phx-value-action="pause")

    view |> element(~s(#run-#{run.uuid} button[phx-value-action="pause"])) |> render_click()
    assert reload(run).state == "paused"
    assert render(view) =~ "Resume"

    view |> element(~s(#run-#{run.uuid} button[phx-value-action="resume"])) |> render_click()
    assert reload(run).state == "queued"

    view |> element(~s(#run-#{run.uuid} button[phx-value-action="cancel"])) |> render_click()
    assert reload(run).state == "cancelled"
    assert render(view) =~ "Retry"
  end

  test "the actor is the person who clicked, and the history says so", %{
    conn: conn,
    admin: admin,
    user: user
  } do
    manage(admin)
    run = start!()
    {:ok, view, _html} = live(conn, @path)

    view |> element(~s(#run-#{run.uuid} button[phx-value-action="pause"])) |> render_click()

    assert %{paused_by_uuid: by} = reload(run)
    assert by == user.uuid

    {:ok, _view, html} = live(conn, @path <> "?run=#{run.uuid}")
    assert html =~ "Paused"
    assert html =~ user.email
  end

  test "a hand-made control event from a viewer is refused", %{conn: conn} do
    run = start!()
    {:ok, view, _html} = live(conn, @path)

    html = render_click(view, "run_control", %{"action" => "cancel", "uuid" => run.uuid})

    assert html =~ "You may not do that."
    assert reload(run).state == "queued"
  end

  test "an unknown control is refused, not guessed at", %{conn: conn, admin: admin} do
    manage(admin)
    run = start!()
    {:ok, view, _html} = live(conn, @path)

    assert render_click(view, "run_control", %{"action" => "explode", "uuid" => run.uuid}) =~
             "That did not work."

    assert reload(run).state == "queued"
  end

  test "follows a run as it moves, without a reload", %{conn: conn} do
    run = start!()
    {:ok, view, html} = live(conn, @path)
    assert html =~ "Queued"

    {:ok, _} = Engine.transition(run.uuid, {:pause, nil})
    assert render(view) =~ "Paused"
  end

  test "a draining run says so, and offers only to cancel", %{conn: conn, admin: admin} do
    manage(admin)
    run = start!()
    {:ok, _, _token} = Engine.claim(run.uuid, 1)
    {:ok, %{state: "pausing"}} = Engine.transition(run.uuid, {:pause, nil})

    {:ok, view, html} = live(conn, @path)

    assert html =~ "Pausing…"
    assert html =~ "The current batch is finishing…"
    refute has_element?(view, ~s(#run-#{run.uuid} button[phx-value-action="resume"]))
    assert has_element?(view, ~s(#run-#{run.uuid} button[phx-value-action="cancel"]))
  end

  test "a failed run shows its error and can be retried", %{conn: conn, admin: admin} do
    manage(admin)
    run = start!(Counter, :site, args: %{steps: 2, raise_at: 0})
    Oban.drain_queue(queue: :default, with_scheduled: true, with_recursion: true)
    assert %{state: "failed"} = reload(run)

    {:ok, view, html} = live(conn, @path)
    assert html =~ "boom at step 0"

    view |> element(~s(#run-#{run.uuid} button[phx-value-action="retry"])) |> render_click()
    assert Repo.aggregate(from(r in Run, where: r.kind == "test.counter"), :count) == 2
  end

  describe "the URL is the view" do
    test "?tab= picks the tab; an unknown one falls back to Runs", %{conn: conn} do
      {:ok, _view, html} = live(conn, @path <> "?tab=queue")
      assert html =~ ~r/id="jobs-runs-tab"[^>]*class="[^"]*hidden/ or html =~ "hidden"

      {:ok, view, _} = live(conn, @path <> "?tab=nope")
      refute render(view) =~ ~r/class="hidden"[^>]*id="jobs-runs-tab"/
    end

    test "?run_state= filters the table", %{conn: conn} do
      a = start!()
      b = start!(Counter, {"library", Ecto.UUID.generate()})
      {:ok, _} = Engine.transition(b.uuid, {:cancel, nil})

      {:ok, view, _html} = live(conn, @path <> "?run_state=cancelled")

      assert has_element?(view, "#run-#{b.uuid}")
      refute has_element?(view, "#run-#{a.uuid}")
    end

    test "?run= opens one run with its history", %{conn: conn} do
      run = start!()
      {:ok, _} = Engine.transition(run.uuid, {:pause, nil})

      {:ok, view, html} = live(conn, @path <> "?run=#{run.uuid}")

      assert html =~ run.uuid
      assert html =~ "History"
      assert html =~ "Started"
      assert html =~ "Paused"

      view |> element(~s(button[phx-click="close_run"]), "✕") |> render_click()
      refute render(view) =~ "History"
    end

    test "?run= with a run that is gone opens nothing", %{conn: conn} do
      {:ok, _view, html} = live(conn, @path <> "?run=#{Ecto.UUID.generate()}")
      refute html =~ "modal-open"
    end
  end

  test "warns when runs are waiting and no sweeper has been seen", %{conn: conn} do
    {:ok, _} = PhoenixKit.Settings.update_setting(SweepWorker.last_sweep_setting(), "")
    start!()

    {:ok, _view, html} = live(conn, @path)
    assert html =~ "No sweeper pass in the last 15 minutes"
  end

  test "says nothing about the sweeper when it has been seen, or nothing is waiting", %{
    conn: conn
  } do
    start!()
    {:ok, _view, html} = live(conn, @path)
    refute html =~ "No sweeper pass"
  end

  describe "the sweeper warning and the badge are about all runs, not this view" do
    setup do
      {:ok, _} = PhoenixKit.Settings.update_setting(SweepWorker.last_sweep_setting(), "")
      :ok
    end

    test "a filter that hides the waiting run does not hide the warning", %{conn: conn} do
      start!()

      {:ok, _view, html} = live(conn, @path <> "?run_state=completed")
      assert html =~ "No sweeper pass in the last 15 minutes"
    end

    test "paused runs are not waiting on the sweeper, so they do not raise it", %{conn: conn} do
      run = start!()
      {:ok, _} = Engine.transition(run.uuid, {:pause, nil})

      {:ok, _view, html} = live(conn, @path)
      refute html =~ "No sweeper pass"
    end

    test "the Runs tab counts every unfinished run, whatever the list shows", %{conn: conn} do
      start!()
      start!(Counter, {"library", Ecto.UUID.generate()})
      start!(Counter, {"library", Ecto.UUID.generate()})

      {:ok, view, _html} = live(conn, @path <> "?run_state=completed")
      assert render(view) =~ ~r/Runs\s*<span[^>]*badge[^>]*>\s*3\s*</
    end
  end

  test "the periodic refresh reloads the open run, even when nothing was broadcast", %{conn: conn} do
    run = start!()
    {:ok, view, html} = live(conn, @path <> "?run=#{run.uuid}")
    assert html =~ "Queued"

    # a worker that committed and died before it could broadcast
    Repo.update_all(from(r in Run, where: r.uuid == ^run.uuid), set: [state: "paused"])
    send(view.pid, :refresh)

    assert has_element?(view, "#run-#{run.uuid} .badge", "Paused")
    refute has_element?(view, "#run-#{run.uuid} .badge", "Queued")
    assert has_element?(view, ".modal-box .badge", "Paused")
  end

  test "the filters are the core selects, labelled and with their own ids", %{conn: conn} do
    start!()
    {:ok, view, html} = live(conn, @path)

    assert has_element?(view, "form#runs-filter-state-form select#runs-filter-state")
    assert html =~ ~s(for="runs-filter-state")
  end

  describe "where this node runs no Oban" do
    test "the Queue tab says so instead of showing another schema's table", %{conn: conn} do
      stop_supervised!(Oban)

      {:ok, view, html} = live(conn, @path <> "?tab=queue")
      assert has_element?(view, "#jobs-oban-unavailable")
      assert html =~ "Oban is not running on this node"
    end

    test "and says nothing when it does", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path <> "?tab=queue")
      refute has_element?(view, "#jobs-oban-unavailable")
    end
  end

  describe "the count caveat follows the interruptions" do
    defp open_run(conn, run) do
      {:ok, _view, html} = live(conn, @path <> "?run=#{run.uuid}")
      html
    end

    @note "the counts may not include the work it did before it stopped"

    test "a run whose batch was cut off and run again shows it, even when it completed", %{
      conn: conn
    } do
      run = start!()

      from(r in Run, where: r.uuid == ^run.uuid)
      |> Repo.update_all(set: [interruptions: 1, state: "completed", error: nil, rescues: 0])

      assert open_run(conn, run) =~ @note
    end

    test "a rescued dispatch alone does not: no batch was cut off", %{conn: conn} do
      run = start!()
      from(r in Run, where: r.uuid == ^run.uuid) |> Repo.update_all(set: [rescues: 2])

      refute open_run(conn, run) =~ @note
    end

    test "an untroubled run does not", %{conn: conn} do
      refute open_run(conn, start!()) =~ @note
    end
  end

  describe "a queue that is not working" do
    test "ignores the leftover dispatch of a paused run", %{conn: conn} do
      run = start!()
      age_dispatch(run, 20)
      {:ok, _} = Engine.transition(run.uuid, {:pause, nil})

      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, "#jobs-stalled-queues")
    end

    test "ignores a dispatch superseded by a newer generation", %{conn: conn} do
      run = start!()
      age_dispatch(run, 20)
      {:ok, _} = Engine.transition(run.uuid, {:pause, nil})
      {:ok, _} = Engine.transition(run.uuid, {:resume, nil})

      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, "#jobs-stalled-queues")
    end

    defp age_dispatch(run, minutes) do
      old = DateTime.utc_now() |> DateTime.add(-minutes * 60, :second)

      from(j in Oban.Job, where: j.id == ^Repo.get!(Run, run.uuid).oban_job_id)
      |> Repo.update_all(set: [scheduled_at: old, inserted_at: old])
    end

    test "is named when a batch has waited ten minutes and nothing in its queue has run", %{
      conn: conn
    } do
      run = start!()
      age_dispatch(run, 20)

      {:ok, view, html} = live(conn, @path)

      assert has_element?(view, "#jobs-stalled-queues")
      assert html =~ "Runs are waiting on a queue that is not working: default"
    end

    test "is not, when something in that queue has run lately", %{conn: conn} do
      run = start!()
      age_dispatch(run, 20)

      Repo.insert_all("oban_jobs", [
        %{
          state: "completed",
          queue: "default",
          worker: "Other.Worker",
          args: %{},
          max_attempts: 1,
          attempted_at: DateTime.utc_now() |> DateTime.add(-60, :second),
          completed_at: DateTime.utc_now() |> DateTime.add(-60, :second)
        }
      ])

      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, "#jobs-stalled-queues")
    end

    test "is not, for a batch that has only just been queued", %{conn: conn} do
      start!()
      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, "#jobs-stalled-queues")
    end
  end
end
