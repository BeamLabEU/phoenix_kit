defmodule PhoenixKit.Jobs.EngineTest do
  @moduledoc """
  The job engine against the real database, with Oban in manual testing mode: a
  run's whole life — start, batches, pause, resume, cancel, retry, the claim, a
  restart, errors — and the Activity entries and Oban jobs each one leaves.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Jobs.{Engine, History, Run, RunWorker}
  alias PhoenixKit.Test.JobKinds.{Counter, Restarting}
  alias PhoenixKit.Users.Auth

  @library "01a0f33e-0000-7000-8000-00000000cccc"

  setup do
    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    :ok
  end

  defp user do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "jobs-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp start!(kind \\ Counter, scope \\ :site, opts \\ []) do
    assert {:ok, run, :started} = Engine.start(kind, scope, opts)
    run
  end

  defp reload(run), do: Repo.get!(Run, run.uuid)

  defp jobs(run) do
    Repo.all(
      from j in Oban.Job,
        where:
          j.worker == "PhoenixKit.Jobs.RunWorker" and
            fragment("?->>'run_uuid' = ?", j.args, ^run.uuid),
        order_by: j.id
    )
  end

  defp drain, do: Oban.drain_queue(queue: :default, with_scheduled: true, with_recursion: true)

  defp actions(run), do: run.uuid |> History.for_run() |> Enum.map(& &1.action)

  describe "start" do
    test "makes a queued run under generation 1 and dispatches its first batch" do
      run = start!(Counter, :site, args: %{steps: 2})

      assert %{
               state: "queued",
               generation: 1,
               kind: "test.counter",
               module: "test",
               mode: "manual"
             } = run

      assert run.title == "Count to 2"
      assert run.args == %{"steps" => 2}

      assert [
               %Oban.Job{args: %{"run_uuid" => uuid, "generation" => 1, "kind" => "test.counter"}} =
                 job
             ] =
               jobs(run)

      assert uuid == run.uuid
      assert reload(run).oban_job_id == job.id
      assert actions(run) == ["job.started"]
    end

    test "records who started it, and writes the entry under the kind's module" do
      user = user()
      run = start!(Counter, :site, actor_uuid: user.uuid)

      assert run.started_by_uuid == user.uuid

      assert [%Entry{module: "test", actor_uuid: actor, resource_type: "job_run", mode: "manual"}] =
               History.for_run(run.uuid)

      assert actor == user.uuid
    end

    test "a library scope is kept" do
      run = start!(Counter, {"library", @library})
      assert Run.scope(run) == {"library", @library}
    end

    test "a second start of the same kind and scope returns the active run, and dispatches nothing" do
      run = start!()

      assert {:ok, again, :existing} = Engine.start(Counter, :site)
      assert again.uuid == run.uuid
      assert length(jobs(run)) == 1
      assert actions(run) == ["job.started"]
    end

    test "a different scope or kind is a different run" do
      site = start!()
      library = start!(Counter, {"library", @library})
      other = start!(Restarting)

      assert length(Enum.uniq([site.uuid, library.uuid, other.uuid])) == 3
    end

    test "a kind may refuse a start" do
      assert {:error, :refused} =
               Engine.start(PhoenixKit.Test.JobKinds.Guarded, :site, args: %{refuse: true})

      assert Repo.aggregate(Run, :count) == 0
    end

    test "a kind that wants a fresh pass is asked for one while it runs" do
      run = start!(Restarting)

      assert {:ok, again, :existing} = Engine.start(Restarting, :site)
      assert again.uuid == run.uuid
      assert reload(run).restart_seq == 1
    end

    test "with no Oban the run is made without a job, for the sweeper to find" do
      stop_supervised!(Oban)

      assert {:ok, run, :started} = Engine.start(Counter, :site)
      assert run.oban_job_id == nil
      assert %{state: "queued", generation: 1} = reload(run)
    end
  end

  describe "batches" do
    test "run to completion, one dispatch each, with the progress and the history" do
      run = start!(Counter, :site, args: %{steps: 3, per_batch: 10})

      drain()

      assert %{
               state: "completed",
               done: 30,
               finished_at: finished,
               result: %{"steps" => 3},
               claim_token: nil
             } =
               reload(run)

      assert finished
      assert actions(run) == ["job.started", "job.completed"]
      # first batch + two successors, each of a new generation
      assert jobs(run) |> Enum.map(& &1.args["generation"]) == [1, 2, 3]
    end

    test "record the total and the cursor as they go" do
      run = start!(Counter, :site, args: %{steps: 3})

      assert {:ok, claimed, token} = Engine.claim(run.uuid, 1)
      outcome = RunWorker.batch_outcome(Counter, claimed, false)
      assert {:ok, after_one} = Engine.checkpoint(run.uuid, token, outcome)

      assert %{
               state: "running",
               done: 10,
               total: 30,
               cursor: %{"step" => 1},
               generation: 2,
               claim_token: nil
             } =
               after_one

      assert Run.percent(after_one) == 33
    end

    test "a snooze changes nothing and tries again" do
      run = start!(Counter, :site, args: %{steps: 2, snooze_at: 0})

      drain()

      assert %{state: "completed", done: 20} = reload(run)
    end
  end

  describe "the claim" do
    test "is taken by one batch; a second finds the run busy" do
      run = start!()

      assert {:ok, claimed, token} = Engine.claim(run.uuid, 1)
      assert %{state: "running", claim_token: ^token, started_at: started} = claimed
      assert started
      assert {:skip, :busy} = Engine.claim(run.uuid, 1)
    end

    test "is refused to a job of an older generation" do
      run = start!()
      assert {:ok, _, token} = Engine.claim(run.uuid, 1)
      assert {:ok, _} = Engine.checkpoint(run.uuid, token, {:snooze, 0})

      assert reload(run).generation == 2
      assert {:skip, :obsolete} = Engine.claim(run.uuid, 1)
      assert {:ok, _, _} = Engine.claim(run.uuid, 2)
    end

    test "is refused for a run that is gone" do
      assert {:skip, :obsolete} = Engine.claim(Ecto.UUID.generate(), 1)
    end

    test "a checkpoint with another token is refused" do
      run = start!()
      assert {:ok, _, _token} = Engine.claim(run.uuid, 1)

      assert {:error, :claim_lost} =
               Engine.checkpoint(run.uuid, Ecto.UUID.generate(), {:snooze, 0})
    end

    test "a heartbeat needs the claim" do
      run = start!()
      assert {:ok, claimed, _token} = Engine.claim(run.uuid, 1)

      assert :ok = Engine.heartbeat(claimed)

      assert {:error, :claim_lost} =
               Engine.heartbeat(%{claimed | claim_token: Ecto.UUID.generate()})

      assert {:error, :claim_lost} = Engine.heartbeat(run)
    end
  end

  describe "pause and resume" do
    test "a run nothing is working on is paused at once and its pending batch does nothing" do
      user = user()
      run = start!()

      assert {:ok, %{state: "paused", paused_by_uuid: by}} =
               Engine.transition(run.uuid, {:pause, user.uuid}, actor_uuid: user.uuid)

      assert by == user.uuid
      drain()
      assert %{state: "paused", done: 0} = reload(run)
      assert actions(run) == ["job.started", "job.paused"]
    end

    test "resuming dispatches again under a new generation, and the old pending job is inert" do
      run = start!(Counter, :site, args: %{steps: 2})
      {:ok, _} = Engine.transition(run.uuid, {:pause, nil})

      assert {:ok, %{state: "queued", generation: 2}} =
               Engine.transition(run.uuid, {:resume, nil})

      drain()

      assert %{state: "completed", done: 20} = reload(run)
      assert actions(run) == ["job.started", "job.paused", "job.resumed", "job.completed"]
    end

    test "while a batch holds the run, a pause is a request, resume is refused, and the batch's checkpoint settles it" do
      run = start!(Counter, :site, args: %{steps: 3})
      {:ok, _claimed, token} = Engine.claim(run.uuid, 1)

      assert {:ok, %{state: "pausing"}} = Engine.transition(run.uuid, {:pause, nil})
      assert {:error, :draining} = Engine.transition(run.uuid, {:resume, nil})
      assert {:error, :already_pausing} = Engine.transition(run.uuid, {:pause, nil})

      jobs_before = length(jobs(run))

      assert {:ok, %{state: "paused", done: 10, claim_token: nil, generation: 1}} =
               Engine.checkpoint(
                 run.uuid,
                 token,
                 {:more, %{cursor: %{"step" => 1}, done: 10}, []}
               )

      # the work is recorded, and nothing is dispatched
      assert length(jobs(run)) == jobs_before
      assert actions(run) == ["job.started", "job.pause_requested", "job.paused"]
    end
  end

  describe "cancel" do
    test "a run nothing is working on is cancelled at once" do
      user = user()
      run = start!()

      assert {:ok, %{state: "cancelled", cancelled_by_uuid: by, finished_at: finished}} =
               Engine.transition(run.uuid, {:cancel, user.uuid}, actor_uuid: user.uuid)

      assert by == user.uuid and finished
      drain()
      assert %{state: "cancelled", done: 0} = reload(run)
    end

    test "while a batch holds the run, cancelling asks, and a new run of the kind cannot start until the old one has drained" do
      run = start!()
      {:ok, _, token} = Engine.claim(run.uuid, 1)

      assert {:ok, %{state: "cancelling"}} = Engine.transition(run.uuid, {:cancel, nil})

      # cancel then retry: the same kind and scope is still taken
      assert {:ok, existing, :existing} = Engine.start(Counter, :site)
      assert existing.uuid == run.uuid

      assert {:ok, %{state: "cancelled", done: 5}} =
               Engine.checkpoint(run.uuid, token, {:more, %{done: 5}, []})

      assert {:ok, fresh, :started} = Engine.start(Counter, :site)
      assert fresh.uuid != run.uuid
    end

    test "a last batch that was being cancelled leaves the run cancelled, not completed" do
      run = start!()
      {:ok, _, token} = Engine.claim(run.uuid, 1)
      {:ok, _} = Engine.transition(run.uuid, {:cancel, nil})

      assert {:ok, %{state: "cancelled", result: %{"x" => 1}}} =
               Engine.checkpoint(run.uuid, token, {:done, %{done: 1}, %{"x" => 1}})
    end

    test "a pause that arrived during the last batch lets it complete" do
      run = start!()
      {:ok, _, token} = Engine.claim(run.uuid, 1)
      {:ok, _} = Engine.transition(run.uuid, {:pause, nil})

      assert {:ok, %{state: "completed"}} =
               Engine.checkpoint(run.uuid, token, {:done, %{}, %{}})
    end
  end

  describe "a trigger during a run" do
    test "during the last batch starts a fresh pass instead of completing" do
      run = start!(Restarting)
      {:ok, _, token} = Engine.claim(run.uuid, 1)

      assert {:ok, _, :existing} = Engine.start(Restarting, :site)

      assert {:ok, %{state: "queued", done: 0, cursor: %{}, restart_ack: 1, generation: 2}} =
               Engine.checkpoint(run.uuid, token, {:done, %{done: 7}, %{}})

      # and the new pass is dispatched and runs to the end
      drain()

      assert %{state: "completed", done: 30} = reload(run)
    end

    test "a trigger after the checkpoint is kept for the next batch" do
      run = start!(Restarting, :site, args: %{steps: 3})
      {:ok, _, token} = Engine.claim(run.uuid, 1)

      assert {:ok, %{state: "running", done: 10}} =
               Engine.checkpoint(
                 run.uuid,
                 token,
                 {:more, %{cursor: %{"step" => 1}, done: 10}, []}
               )

      assert {:ok, _, :existing} = Engine.start(Restarting, :site, args: %{steps: 3})

      # the next batch takes it in at its claim: the pass starts over
      assert {:ok, claimed, _} = Engine.claim(run.uuid, 2)
      assert %{done: 0, cursor: %{}, restart_ack: 1} = claimed
    end
  end

  describe "errors" do
    test "one that Oban will retry releases the claim, and the retry takes it" do
      run = start!(Counter, :site, args: %{steps: 2, error_at: 0})
      {:ok, _, token} = Engine.claim(run.uuid, 1)

      assert {:ok, %{state: "running", claim_token: nil, error: "boom"}} =
               Engine.checkpoint(run.uuid, token, {:release, "boom"})

      assert {:ok, _, _} = Engine.claim(run.uuid, 1)
    end

    test "the last attempt fails the run, with the error and the history" do
      run = start!(Counter, :site, args: %{steps: 2, raise_at: 0})

      drain()

      assert %{state: "failed", error: error, finished_at: finished, claim_token: nil} =
               reload(run)

      assert error =~ "boom at step 0"
      assert finished
      assert actions(run) == ["job.started", "job.failed"]
    end

    test "a kind that is gone fails the run instead of looping" do
      run = start!()
      previous = Application.get_env(:phoenix_kit, :job_kinds)
      Application.put_env(:phoenix_kit, :job_kinds, [])
      on_exit(fn -> Application.put_env(:phoenix_kit, :job_kinds, previous) end)

      drain()

      assert %{state: "failed", error: error} = reload(run)
      assert error =~ "kind unavailable"
    end
  end

  describe "retry" do
    test "a finished run can be started again, and the new run says what it retries" do
      run = start!(Counter, :site, args: %{steps: 2, raise_at: 0})
      drain()
      assert %{state: "failed"} = reload(run)

      assert {:ok, again, :started} =
               Engine.start(Counter, :site, args: run.args, retry_of: run.uuid)

      assert again.uuid != run.uuid
      assert again.args["retry_of"] == run.uuid
    end
  end

  test "a restart request on a finished run is refused" do
    run = start!()
    drain()
    assert {:error, :finished} = Engine.transition(run.uuid, :request_restart)
  end

  test "a transition on a run that does not exist says so" do
    assert {:error, :not_found} = Engine.transition(Ecto.UUID.generate(), {:pause, nil})
  end

  test "claim_inline takes any generation, bumps it, and refuses a held run" do
    run = start!()

    assert {:ok, claimed, _token} = Engine.claim_inline(run.uuid)
    assert claimed.generation == 2
    assert {:error, :claimed} = Engine.claim_inline(run.uuid)
    assert {:skip, :obsolete} = Engine.claim(run.uuid, 1)
  end
end
