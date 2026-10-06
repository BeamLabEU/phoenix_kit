defmodule PhoenixKit.Jobs.SweepWorkerTest do
  @moduledoc """
  The sweeper finds a run whose batch died or whose dispatch was lost and puts it
  right, reading the run's own Oban job — never a stale heartbeat alone — and
  keeping a durable rescue budget.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Jobs.{Engine, History, PruneWorker, Run, SweepWorker}
  alias PhoenixKit.Test.JobKinds.Counter

  setup do
    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    :ok
  end

  defp start!(args \\ %{}) do
    assert {:ok, run, :started} = Engine.start(Counter, :site, args: args)
    run
  end

  defp reload(run), do: Repo.get!(Run, run.uuid)
  defp job(run), do: Repo.get!(Oban.Job, reload(run).oban_job_id)

  # A run that has been quiet for longer than the grace period.
  defp age(run) do
    old = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(r in Run, where: r.uuid == ^run.uuid), set: [updated_at: old])
  end

  defp set_job_state(run, state) do
    Repo.update_all(from(j in Oban.Job, where: j.id == ^reload(run).oban_job_id),
      set: [state: state]
    )
  end

  defp actions(run), do: run.uuid |> History.for_run() |> Enum.map(& &1.action)

  test "leaves a healthy run alone: a waiting job, a recent change" do
    run = start!()
    age(run)

    assert %{released: 0, failed: 0, rescued: 0} = SweepWorker.sweep()
    assert %{state: "queued", rescues: 0, generation: 1} = reload(run)
  end

  test "leaves a run changed a moment ago, whatever its job says" do
    run = start!()
    set_job_state(run, "completed")

    assert %{rescued: 0} = SweepWorker.sweep()
    assert reload(run).generation == 1
  end

  test "rescues a lost dispatch: a job that completed without the run moving on" do
    run = start!()
    set_job_state(run, "completed")
    age(run)

    assert %{rescued: 1} = SweepWorker.sweep()

    assert %{state: "queued", generation: 2, rescues: 1, last_rescued_at: at} = reload(run)
    assert at
    assert job(run).args["generation"] == 2
    assert job(run).state == "available"
    assert actions(run) == ["job.started", "job.rescued"]
  end

  test "rescues a dispatch whose job is gone, and one that was never made" do
    run = start!()
    Repo.delete_all(from j in Oban.Job, where: j.id == ^reload(run).oban_job_id)
    age(run)

    assert %{rescued: 1} = SweepWorker.sweep()
    assert %{generation: 2, rescues: 1} = reload(run)

    stop_supervised!(Oban)
    {:ok, orphan, :started} = Engine.start(Counter, {"library", Ecto.UUID.generate()})
    assert orphan.oban_job_id == nil
    age(orphan)

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    assert %{rescued: 1} = SweepWorker.sweep()
    assert %{generation: 2, oban_job_id: id} = reload(orphan)
    assert is_integer(id)
  end

  test "treats a job of an older generation as no dispatch at all" do
    run = start!()
    {:ok, _, token} = Engine.claim(run.uuid, 1)
    {:ok, _} = Engine.checkpoint(run.uuid, token, {:snooze, 0})

    # the run is at generation 2 and its job id points at the new job; make that job of generation 1
    Repo.update_all(
      from(j in Oban.Job, where: j.id == ^reload(run).oban_job_id),
      set: [
        args: %{"run_uuid" => run.uuid, "generation" => 1, "kind" => "test.counter"},
        state: "completed"
      ]
    )

    age(run)
    assert %{rescued: 1} = SweepWorker.sweep()
    assert reload(run).generation == 3
  end

  test "fails a run whose batch used up its attempts, with the job's last error" do
    run = start!()

    Repo.update_all(from(j in Oban.Job, where: j.id == ^reload(run).oban_job_id),
      set: [state: "discarded", errors: [%{"error" => "boom"}]]
    )

    age(run)

    assert %{failed: 1} = SweepWorker.sweep()
    assert %{state: "failed", error: error, finished_at: finished} = reload(run)
    assert error =~ "used up its attempts" and error =~ "boom"
    assert finished
    assert actions(run) == ["job.started", "job.failed"]
  end

  test "fails a run whose job was cancelled outside the run" do
    run = start!()
    set_job_state(run, "cancelled")
    age(run)

    assert %{failed: 1} = SweepWorker.sweep()
    assert %{state: "failed", error: error} = reload(run)
    assert error =~ "cancelled outside"
  end

  test "stops rescuing at the limit and fails the run instead of restarting for ever" do
    run = start!()

    for _ <- 1..3 do
      set_job_state(run, "completed")
      age(run)
      assert %{rescued: 1} = SweepWorker.sweep()
    end

    assert reload(run).rescues == 3

    set_job_state(run, "completed")
    age(run)
    assert %{failed: 1} = SweepWorker.sweep()
    assert %{state: "failed", error: error} = reload(run)
    assert error =~ "given up"
  end

  describe "a run that holds a claim" do
    test "is left while its job is executing: Lifeline owns a genuinely dead one" do
      run = start!()
      {:ok, _, token} = Engine.claim(run.uuid, 1)
      set_job_state(run, "executing")
      age(run)

      assert %{released: 0} = SweepWorker.sweep()
      assert %{claim_token: ^token} = reload(run)
    end

    test "is released when its job is no longer executing, so the retry can take it" do
      run = start!()
      {:ok, _, _token} = Engine.claim(run.uuid, 1)
      set_job_state(run, "retryable")
      age(run)

      assert %{released: 1} = SweepWorker.sweep()
      assert %{claim_token: nil, state: "running", error: error} = reload(run)
      assert error =~ "did not finish"
      assert {:ok, _, _} = Engine.claim(run.uuid, 1)
    end

    test "a pause that was waiting for the dead batch settles" do
      run = start!()
      {:ok, _, _} = Engine.claim(run.uuid, 1)
      {:ok, %{state: "pausing"}} = Engine.transition(run.uuid, {:pause, nil})
      set_job_state(run, "discarded")
      age(run)

      assert %{released: 1} = SweepWorker.sweep()
      assert %{state: "paused", claim_token: nil} = reload(run)
    end
  end

  test "a paused run is never touched" do
    run = start!()
    {:ok, _} = Engine.transition(run.uuid, {:pause, nil})
    set_job_state(run, "completed")
    age(run)

    assert %{rescued: 0, failed: 0, released: 0} = SweepWorker.sweep()
    assert reload(run).state == "paused"
  end

  test "stamps the pass, for the Jobs page to read" do
    SweepWorker.sweep()

    assert {:ok, _, _} =
             DateTime.from_iso8601(
               PhoenixKit.Settings.get_setting(SweepWorker.last_sweep_setting())
             )
  end

  # The stamp moves on every pass (every five minutes from cron); a permanent
  # settings-history entry per pass buried the Activity feed and never pruned.
  test "stamps every pass without writing the settings history" do
    t0 = ~U[2026-10-06 10:00:00Z]

    for minutes <- [0, 5, 10] do
      SweepWorker.sweep(DateTime.add(t0, minutes * 60, :second))
    end

    assert PhoenixKit.Settings.get_setting(SweepWorker.last_sweep_setting()) ==
             "2026-10-06T10:10:00Z"

    assert PhoenixKit.Settings.History.list(SweepWorker.last_sweep_setting()) == []
  end

  describe "pruning" do
    test "deletes finished runs older than the retention, and nothing else" do
      old = start!(%{steps: 1}) |> finish()

      recent =
        start!(%{steps: 1})
        |> then(
          &(elem(Engine.start(Counter, {"library", Ecto.UUID.generate()}, args: %{steps: 1}), 1) &&
              &1)
        )

      active = elem(Engine.start(Counter, {"library", Ecto.UUID.generate()}), 1)

      long_ago =
        DateTime.utc_now() |> DateTime.add(-200 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(r in Run, where: r.uuid == ^old.uuid), set: [finished_at: long_ago])
      Repo.update_all(from(r in Run, where: r.uuid == ^active.uuid), set: [inserted_at: long_ago])

      assert PruneWorker.prune() == 1
      assert Repo.get(Run, old.uuid) == nil
      assert Repo.get(Run, recent.uuid)
      assert Repo.get(Run, active.uuid)
    end

    test "the retention is a setting, 90 days by default" do
      assert PruneWorker.retention_days() == 90
      {:ok, _} = PhoenixKit.Settings.update_setting("job_runs_retention_days", "7")
      assert PruneWorker.retention_days() == 7
    end
  end

  defp finish(run) do
    {:ok, _, token} = Engine.claim(run.uuid, 1)
    {:ok, run} = Engine.checkpoint(run.uuid, token, {:done, %{}, %{}})
    run
  end
end
