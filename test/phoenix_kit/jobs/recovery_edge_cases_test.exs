defmodule PhoenixKit.Jobs.RecoveryEdgeCasesTest do
  @moduledoc """
  Remaining publish-gate cases from the job-runs plan, section 20: a second
  inline caller, repeated loss of a delayed dispatch, and an expired inline
  wait on a node without Oban.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Jobs
  alias PhoenixKit.Jobs.{Engine, Run, SweepWorker}
  alias PhoenixKit.Test.JobKinds.Counter

  defp start_oban do
    start_supervised!({Oban, name: Oban, repo: Repo, testing: :manual, queues: [], plugins: []})
  end

  defp reload(run), do: Repo.get!(Run, run.uuid)

  defp age(run) do
    old = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(r in Run, where: r.uuid == ^run.uuid), set: [updated_at: old])
  end

  defp inline_wait do
    {:ok, run, :started} = Engine.start(Counter, :site, dispatch: false, args: %{steps: 2})
    {:ok, _, token} = Engine.claim_inline(run.uuid)

    {:ok, waiting} =
      Engine.checkpoint(
        run.uuid,
        token,
        {:more, %{done: 10, cursor: %{"step" => 1}}, schedule_in: 600},
        dispatch: false
      )

    waiting
  end

  test "another script cannot bypass a living inline owner's wait" do
    start_oban()
    waiting = inline_wait()

    assert {:error, :claimed} = Jobs.run_inline(Counter, :site)
    assert %{state: "running", claim_owner: "inline", done: 10} = reload(waiting)
  end

  test "a second rescue retains a queued run's original next-batch time" do
    start_oban()
    {:ok, run, :started} = Engine.start(Counter, :site, args: %{steps: 2})
    {:ok, _, token} = Engine.claim(run.uuid, 1)

    {:ok, delayed} =
      Engine.checkpoint(
        run.uuid,
        token,
        {:more, %{done: 10, cursor: %{"step" => 1}}, schedule_in: 600}
      )

    due = delayed.wake_at

    for _ <- 1..2 do
      current = reload(run)
      Repo.delete_all(from(j in Oban.Job, where: j.id == ^current.oban_job_id))
      age(run)
      assert %{rescued: 1} = SweepWorker.sweep()
    end

    current = reload(run)
    job = Repo.get!(Oban.Job, current.oban_job_id)
    assert DateTime.compare(job.scheduled_at, due) != :lt
  end

  test "an expired inline wait preserves the rescue budget when Oban is absent" do
    waiting = inline_wait()
    old = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(r in Run, where: r.uuid == ^waiting.uuid),
      set: [updated_at: old, heartbeat_at: old, wake_at: old]
    )

    for _ <- 1..4 do
      age(waiting)
      assert %{rescued: 0, failed: 0} = SweepWorker.sweep()
    end

    assert %{state: "running", rescues: 0, oban_job_id: nil} = reload(waiting)
  end
end
