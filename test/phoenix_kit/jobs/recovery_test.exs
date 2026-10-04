defmodule PhoenixKit.Jobs.RecoveryTest do
  @moduledoc """
  The review findings of `dev_docs/plans/2026-10-03-job-runs.md` §16 as permanent
  tests: recovery decided under the row lock (F1), a script's claim that the sweeper
  must not steal (F2), an obsolete delivery that stays inert when its kind is gone
  (F3), inline waits (F5), no events before an outer commit (F7), and a batch that
  is really killed — by its timeout, then by Lifeline — and recovered.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Jobs
  alias PhoenixKit.Jobs.{Engine, Events, Run, RunWorker, SweepWorker}
  alias PhoenixKit.Test.JobKinds.{Counter, Short}

  @owner_a "00000000-0000-4000-8000-00000000000a"
  @owner_b "00000000-0000-4000-8000-00000000000b"

  defp oban(opts \\ [], id \\ :oban_main) do
    base = [name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []]
    start_supervised!(Supervisor.child_spec({Oban, Keyword.merge(base, opts)}, id: id))
  end

  defp start!(kind \\ Counter, opts \\ []) do
    assert {:ok, run, :started} = Engine.start(kind, :site, opts)
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

  # The run has been quiet for `seconds`: its row, its claim and its heartbeat.
  defp backdate(run, seconds) do
    old = DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

    from(r in Run, where: r.uuid == ^run.uuid)
    |> Repo.update_all(set: [updated_at: old])

    from(r in Run, where: r.uuid == ^run.uuid and not is_nil(r.claim_token))
    |> Repo.update_all(set: [claimed_at: old, heartbeat_at: old])
  end

  defp set_job_state(run, state) do
    from(j in Oban.Job, where: j.id == ^reload(run).oban_job_id)
    |> Repo.update_all(set: [state: state])
  end

  defp without_kinds(_context \\ nil) do
    previous = Application.get_env(:phoenix_kit, :job_kinds)
    Application.put_env(:phoenix_kit, :job_kinds, [])
    on_exit(fn -> Application.put_env(:phoenix_kit, :job_kinds, previous) end)
  end

  defp persisted_job(run), do: Repo.get!(Oban.Job, reload(run).oban_job_id)

  defp no_sweep, do: %{released: 0, failed: 0, rescued: 0}

  # ---------------------------------------------------------------------------
  # F1 — a sweep decides under the lock, from the run as it is then
  # ---------------------------------------------------------------------------

  describe "a sweep that listed a run before somebody else moved it" do
    setup do
      oban()
      :ok
    end

    test "leaves the newer generation's live claim alone" do
      run = start!()
      set_job_state(run, "completed")
      backdate(run, 600)

      hook = fn ->
        {:ok, %{generation: 2}} = Engine.transition(run.uuid, {:rescue, 3}, mode: "auto")
        {:ok, _claimed, token} = Engine.claim(run.uuid, 2)
        set_job_state(run, "executing")
        Process.put(:token, token)
      end

      assert no_sweep() == SweepWorker.sweep(DateTime.utc_now(), after_listing: hook)

      token = Process.get(:token)
      assert %{generation: 2, claim_token: ^token, rescues: 1, state: "running"} = reload(run)
      assert length(jobs(run)) == 2
    end

    test "leaves it alone even when the run has gone quiet again, if its job is executing" do
      run = start!()
      set_job_state(run, "completed")
      backdate(run, 600)

      hook = fn ->
        {:ok, _} = Engine.transition(run.uuid, {:rescue, 3}, mode: "auto")
        {:ok, _claimed, token} = Engine.claim(run.uuid, 2)
        set_job_state(run, "executing")
        backdate(run, 600)
        Process.put(:token, token)
      end

      assert no_sweep() == SweepWorker.sweep(DateTime.utc_now(), after_listing: hook)
      token = Process.get(:token)
      assert %{generation: 2, claim_token: ^token, rescues: 1} = reload(run)
      assert length(jobs(run)) == 2
    end

    test "a stale 'discarded' observation of the old dispatch cannot fail the new generation" do
      run = start!()
      set_job_state(run, "discarded")
      backdate(run, 600)

      hook = fn ->
        {:ok, _} = Engine.transition(run.uuid, {:rescue, 3}, mode: "auto")
        backdate(run, 600)
      end

      assert no_sweep() == SweepWorker.sweep(DateTime.utc_now(), after_listing: hook)
      assert %{state: "queued", generation: 2, rescues: 1} = reload(run)
      assert [%{state: "available"}, %{state: "discarded"}] = Enum.sort_by(jobs(run), & &1.state)
    end

    test "two sweeps cannot charge the rescue budget twice for one lost dispatch" do
      run = start!()
      set_job_state(run, "completed")
      backdate(run, 600)

      assert %{rescued: 0} =
               SweepWorker.sweep(DateTime.utc_now(), after_listing: fn -> SweepWorker.sweep() end)

      assert %{rescues: 1, generation: 2} = reload(run)
      assert length(jobs(run)) == 2
    end
  end

  describe "Engine.recover/4" do
    setup do
      oban()
      :ok
    end

    test "refuses to rescue or fail a run a batch holds" do
      run = start!()
      {:ok, _claimed, _token} = Engine.claim(run.uuid, 1)

      assert {:error, :claimed} = Engine.transition(run.uuid, {:rescue, 3}, mode: "auto")
      assert {:error, :claimed} = Engine.transition(run.uuid, {:fail, "x"}, mode: "auto")
      assert %{state: "running", generation: 1} = reload(run)
    end

    test "leaves a run changed since the cutoff" do
      run = start!()
      cutoff = DateTime.add(DateTime.utc_now(), -600, :second)

      assert {:error, :changed} = Engine.recover(run.uuid, cutoff, fn _ -> flunk("decided") end)
    end
  end

  # ---------------------------------------------------------------------------
  # F2 — a script's claim is not a dead batch
  # ---------------------------------------------------------------------------

  describe "a script's claim" do
    setup do
      oban()
      :ok
    end

    test "is marked as one, and the sweeper leaves it while its lease stands" do
      run = start!(Counter, dispatch: false)
      assert {:ok, %{claim_owner: "inline", generation: 2}, token} = Engine.claim_inline(run.uuid)

      backdate(run, 600)

      assert no_sweep() == SweepWorker.sweep()
      assert %{claim_token: ^token, claim_owner: "inline"} = reload(run)
      assert jobs(run) == []
    end

    test "a heartbeat renews the lease" do
      run = start!(Counter, dispatch: false)
      {:ok, claimed, token} = Engine.claim_inline(run.uuid)
      backdate(run, Run.inline_lease_seconds() * 2)

      assert :ok = Engine.heartbeat(claimed)
      assert no_sweep() == SweepWorker.sweep()
      assert %{claim_token: ^token} = reload(run)
    end

    test "once the lease has run out the sweeper takes the dead script's run back" do
      run = start!(Counter, dispatch: false)
      {:ok, _claimed, _token} = Engine.claim_inline(run.uuid)
      backdate(run, Run.inline_lease_seconds() * 2)

      assert %{rescued: 1} = SweepWorker.sweep()
      assert %{claim_token: nil, claim_owner: nil, rescues: 1} = reload(run)
      assert [_] = jobs(run)
    end

    test "a new script may take over a claim whose lease ran out, and not before" do
      run = start!(Counter, dispatch: false)
      {:ok, _claimed, first} = Engine.claim_inline(run.uuid)
      assert {:error, :claimed} = Engine.claim_inline(run.uuid)

      backdate(run, Run.inline_lease_seconds() * 2)

      assert {:ok, %{claim_owner: "inline", interruptions: 1}, second} =
               Engine.claim_inline(run.uuid)

      refute second == first
    end

    test "a real inline batch held past the grace period keeps its claim, and finishes" do
      task =
        Task.async(fn -> Jobs.run_inline(Counter, :site, args: %{steps: 1, sleep_ms: 1500}) end)

      run = wait_for_claim()
      backdate(run, 600)

      assert no_sweep() == SweepWorker.sweep()
      assert %{claim_owner: "inline"} = reload(run)
      assert jobs(run) == []

      assert {:ok, %Run{state: "completed"}} = Task.await(task, 10_000)
    end

    test "when its owner is killed the run is recovered after the lease" do
      {:ok, pid} =
        Task.start(fn -> Jobs.run_inline(Counter, :site, args: %{steps: 1, sleep_ms: 30_000}) end)

      run = wait_for_claim()
      Process.exit(pid, :kill)
      backdate(run, 600)
      assert no_sweep() == SweepWorker.sweep()

      backdate(run, Run.inline_lease_seconds() * 2)
      assert %{rescued: 1} = SweepWorker.sweep()
      assert %{claim_token: nil, rescues: 1} = reload(run)
    end

    defp wait_for_claim(attempts \\ 60) do
      case Repo.one(from r in Run, where: r.kind == "test.counter" and not is_nil(r.claim_token)) do
        %Run{} = run ->
          run

        nil when attempts > 0 ->
          Process.sleep(50)
          wait_for_claim(attempts - 1)

        nil ->
          flunk("the inline batch never took its claim")
      end
    end
  end

  describe "a script waiting out a delay between its batches" do
    setup do
      oban()
      :ok
    end

    defp waiting_inline(seconds) do
      run = start!(Counter, dispatch: false, args: %{steps: 3})
      {:ok, _claimed, token} = Engine.claim_inline(run.uuid)

      {:ok, waiting} =
        Engine.checkpoint(
          run.uuid,
          token,
          {:more, %{done: 1, cursor: %{"step" => 1}}, schedule_in: seconds},
          dispatch: false
        )

      waiting
    end

    test "is recorded: the script is still the owner, and the next batch is due at wake_at" do
      waiting = waiting_inline(600)

      assert %{claim_token: nil, claim_owner: "inline", state: "running"} = reload(waiting)
      assert DateTime.diff(waiting.wake_at, DateTime.utc_now()) in 595..605
    end

    test "is not a lost dispatch: a wait longer than the grace period creates no early successor" do
      waiting = waiting_inline(600)
      backdate(waiting, 600)

      assert no_sweep() == SweepWorker.sweep()
      assert %{generation: 3, rescues: 0, claim_owner: "inline"} = reload(waiting)
      assert jobs(waiting) == []

      assert %{success: 0, failure: 0} =
               Oban.drain_queue(queue: :default, with_scheduled: true, with_recursion: true)
    end

    test "a live script is covered by the lease on top of its delay" do
      waiting = waiting_inline(7200)
      # an hour and a half after the checkpoint: still inside delay + lease
      backdate(waiting, 5400)

      assert no_sweep() == SweepWorker.sweep()
      assert jobs(waiting) == []
    end

    test "once the delay and the lease have both passed the sweeper takes the run back" do
      waiting = waiting_inline(60)

      past = DateTime.utc_now() |> DateTime.add(-3 * 3600, :second) |> DateTime.truncate(:second)

      from(r in Run, where: r.uuid == ^waiting.uuid)
      |> Repo.update_all(set: [updated_at: past, wake_at: past, heartbeat_at: past])

      assert %{rescued: 1} = SweepWorker.sweep()
      assert %{claim_owner: nil, rescues: 1, generation: 4} = reload(waiting)
      assert [_] = jobs(waiting)
    end

    test "the rescue of a queued run carries what is left of its delay" do
      run = start!()
      set_job_state(run, "completed")
      due = DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.truncate(:second)

      from(r in Run, where: r.uuid == ^run.uuid)
      |> Repo.update_all(set: [wake_at: due])

      backdate(run, 600)
      assert %{rescued: 1} = SweepWorker.sweep()

      [_old, new] = jobs(run)
      assert DateTime.diff(new.scheduled_at, DateTime.utc_now()) in 290..305
    end

    test "the same invocation reclaims its wait; another is refused until the lease runs out" do
      run = start!(Counter, dispatch: false, args: %{steps: 3})
      {:ok, _claimed, token} = Engine.claim_inline(run.uuid, @owner_a)

      {:ok, waiting} =
        Engine.checkpoint(run.uuid, token, {:more, %{done: 1}, schedule_in: 600}, dispatch: false)

      assert {:error, :claimed} = Engine.claim_inline(run.uuid, @owner_b)
      assert %{owner_token: @owner_a} = reload(waiting)

      past = DateTime.utc_now() |> DateTime.add(-3 * 3600, :second) |> DateTime.truncate(:second)

      from(r in Run, where: r.uuid == ^run.uuid)
      |> Repo.update_all(set: [wake_at: past, heartbeat_at: past])

      assert {:ok, %{owner_token: @owner_b, interruptions: 0}, _} =
               Engine.claim_inline(run.uuid, @owner_b)
    end

    test "the owner reclaims its own wait at once" do
      run = start!(Counter, dispatch: false, args: %{steps: 3})
      {:ok, _claimed, token} = Engine.claim_inline(run.uuid, @owner_a)

      {:ok, _} =
        Engine.checkpoint(run.uuid, token, {:more, %{done: 1}, schedule_in: 600}, dispatch: false)

      assert {:ok, %{owner_token: @owner_a, wake_at: nil}, _} =
               Engine.claim_inline(run.uuid, @owner_a)
    end

    test "a pause during the wait takes effect at once and ends the ownership" do
      waiting = waiting_inline(600)

      assert {:ok, %{state: "paused", claim_owner: nil, owner_token: nil, wake_at: nil}} =
               Engine.transition(waiting.uuid, {:pause, nil})
    end

    test "a real script held in a long wait is not taken from under it" do
      task =
        Task.async(fn ->
          Jobs.run_inline(Counter, :site, args: %{steps: 2, schedule_in: 3})
        end)

      # past the first batch, into the wait
      run = wait_for_waiting()
      backdate(run, 600)

      assert no_sweep() == SweepWorker.sweep()
      assert jobs(run) == []
      assert {:ok, %Run{state: "completed"}} = Task.await(task, 15_000)
    end

    defp wait_for_waiting(attempts \\ 100) do
      query =
        from r in Run,
          where:
            r.kind == "test.counter" and r.claim_owner == "inline" and is_nil(r.claim_token) and
              not is_nil(r.wake_at)

      case Repo.one(query) do
        %Run{} = run ->
          run

        nil when attempts > 0 ->
          Process.sleep(50)
          wait_for_waiting(attempts - 1)

        nil ->
          flunk("the script never began its wait")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Without an Oban instance, nothing about a dispatch can be judged
  # ---------------------------------------------------------------------------

  describe "a sweep where no Oban runs" do
    test "keeps a never-dispatched run's rescue budget, then rescues it once Oban is back" do
      run = start!()
      assert %{oban_job_id: nil, generation: 1, state: "queued"} = reload(run)

      for _ <- 1..5 do
        backdate(run, 600)
        assert no_sweep() == SweepWorker.sweep()
      end

      assert %{rescues: 0, generation: 1, state: "queued"} = reload(run)

      oban()
      backdate(run, 600)
      assert %{rescued: 1} = SweepWorker.sweep()
      assert %{rescues: 1, generation: 2, state: "queued"} = reload(run)
      assert [_] = jobs(run)
    end

    test "leaves a run that holds a queue claim alone too" do
      run = start!()
      {:ok, _claimed, token} = Engine.claim(run.uuid, 1)
      backdate(run, 600)

      assert no_sweep() == SweepWorker.sweep()
      assert %{claim_token: ^token} = reload(run)
    end
  end

  # ---------------------------------------------------------------------------
  # F3 — an obsolete delivery stays inert, even with its kind gone
  # ---------------------------------------------------------------------------

  describe "an obsolete job whose kind has since gone" do
    setup do
      oban()
      :ok
    end

    test "does nothing to a newer generation's live claim" do
      run = start!(Counter, args: %{steps: 3})
      old_job = persisted_job(run)

      {:ok, _claimed, token} = Engine.claim(run.uuid, 1)

      {:ok, _} =
        Engine.checkpoint(run.uuid, token, {:more, %{cursor: %{"step" => 1}, done: 10}, []})

      {:ok, _claimed, live} = Engine.claim(run.uuid, 2)
      without_kinds()

      assert :ok = RunWorker.perform(old_job)

      assert %{state: "running", generation: 2, claim_token: ^live, error: nil} = reload(run)
    end

    test "does nothing to a paused run" do
      run = start!(Counter, args: %{steps: 3})
      job = persisted_job(run)
      {:ok, _} = Engine.transition(run.uuid, {:pause, nil})
      without_kinds()

      assert :ok = RunWorker.perform(job)
      assert %{state: "paused", error: nil} = reload(run)
    end

    test "while a current, unclaimed dispatch whose kind is gone still fails the run" do
      run = start!(Counter, args: %{steps: 3})
      job = persisted_job(run)
      without_kinds()

      assert :ok = RunWorker.perform(job)
      assert %{state: "failed", error: error, claim_token: nil} = reload(run)
      assert error =~ "kind unavailable"
    end
  end

  # ---------------------------------------------------------------------------
  # F5 — inline execution waits as asked
  # ---------------------------------------------------------------------------

  describe "inline execution" do
    setup do
      oban()
      :ok
    end

    defp timed(fun) do
      started = System.monotonic_time(:millisecond)
      result = fun.()
      {result, System.monotonic_time(:millisecond) - started}
    end

    test "waits out a snooze, and reports no progress for it" do
      parent = self()

      {result, elapsed} =
        timed(fn ->
          Jobs.run_inline(Counter, :site,
            args: %{steps: 2, snooze_at: 0, snooze_for: 1},
            on_progress: fn run -> send(parent, {:progress, run.done}) end
          )
        end)

      assert {:ok, %Run{state: "completed", done: 20}} = result
      assert elapsed >= 950
      assert_received {:progress, 10}
      refute_received {:progress, _}
    end

    test "waits out a batch's own schedule_in" do
      {result, elapsed} =
        timed(fn -> Jobs.run_inline(Counter, :site, args: %{steps: 2, schedule_in: 1}) end)

      assert {:ok, %Run{state: "completed"}} = result
      assert elapsed >= 950
    end

    test "a pause during the wait ends it at once" do
      task =
        Task.async(fn ->
          timed(fn -> Jobs.run_inline(Counter, :site, args: %{steps: 3, schedule_in: 30}) end)
        end)

      Process.sleep(500)
      run = Repo.one!(from r in Run, where: r.kind == "test.counter")
      {:ok, _} = Engine.transition(run.uuid, {:pause, nil})

      assert {{:ok, %Run{state: "paused"}}, elapsed} = Task.await(task, 10_000)
      assert elapsed < 5_000
    end
  end

  # ---------------------------------------------------------------------------
  # F7 — nothing escapes a transaction that is not ours
  # ---------------------------------------------------------------------------

  describe "inside somebody else's transaction" do
    setup do
      oban()
      Events.subscribe()
      :ok
    end

    test "start is refused before it writes or announces anything" do
      assert {:ok, {:error, :in_transaction}} =
               Repo.transaction(fn -> Engine.start(Counter, :site, []) end)

      assert Repo.aggregate(from(r in Run, where: r.kind == "test.counter"), :count) == 0
      refute_received {:job_run, _, _}
    end

    test "a terminal transition is refused, and on_finish does not run" do
      run = start!()
      assert_received {:job_run, :started, _}

      assert {:ok, {:error, :in_transaction}} =
               Repo.transaction(fn -> Engine.transition(run.uuid, {:cancel, nil}) end)

      assert %{state: "queued"} = reload(run)
      refute_received {:job_run, _, _}
    end

    test "a claim and a recovery are refused too" do
      run = start!()

      assert {:ok, {:error, :in_transaction}} =
               Repo.transaction(fn -> Engine.claim(run.uuid, 1) end)

      assert {:ok, {:error, :in_transaction}} =
               Repo.transaction(fn -> Engine.claim_inline(run.uuid) end)

      assert {:ok, {:error, :in_transaction}} =
               Repo.transaction(fn ->
                 Engine.recover(run.uuid, DateTime.utc_now(), fn _ -> :leave end)
               end)

      assert %{claim_token: nil} = reload(run)
    end

    test "the same calls work outside one, and announce" do
      run = start!()
      assert_received {:job_run, :started, _}
      assert {:ok, %{state: "cancelled"}} = Engine.transition(run.uuid, {:cancel, nil})
      assert_received {:job_run, :cancelled, _}
    end
  end

  # ---------------------------------------------------------------------------
  # A batch that is really killed: its timeout, then Lifeline, then the sweeper
  # ---------------------------------------------------------------------------

  describe "a batch killed by its timeout" do
    # Oban counts a timeout as a crash of the process running the job; run under
    # `drain_queue` in a process of its own, the timeout kills that process and the
    # database shows what a dead node would leave: the job `executing`, the run held.
    defp kill_by_timeout(run_args) do
      oban([testing: :disabled], :oban_killer)
      run = start!(Short, args: run_args)

      {_pid, ref} =
        spawn_monitor(fn -> Oban.drain_queue(queue: :default, with_safety: false) end)

      assert_receive {:DOWN, ^ref, _, _, %Oban.TimeoutError{}}, 10_000
      stop_supervised!(:oban_killer)
      run
    end

    defp with_lifeline do
      oban(
        [testing: :disabled, plugins: [{Oban.Plugins.Lifeline, interval: 100, rescue_after: 50}]],
        :oban_lifeline
      )
    end

    defp await_job_state(run, fun, attempts \\ 60) do
      job = persisted_job(run)

      cond do
        fun.(job.state) -> job
        attempts == 0 -> flunk("the job stayed #{job.state}")
        true -> Process.sleep(100) && await_job_state(run, fun, attempts - 1)
      end
    end

    test "the claim stays; the sweeper leaves an executing job; Lifeline then gives it back and the sweeper releases the claim" do
      run = kill_by_timeout(%{sleep_ms: 2_000, steps: 1})

      assert %{state: "running", claim_token: token} = reload(run)
      assert %{state: "executing"} = persisted_job(run)

      backdate(run, 600)
      oban()
      assert no_sweep() == SweepWorker.sweep()
      assert %{claim_token: ^token} = reload(run)
      stop_supervised!(:oban_main)

      with_lifeline()
      assert %{state: "available"} = await_job_state(run, &(&1 != "executing"))
      stop_supervised!(:oban_lifeline)

      oban()
      backdate(run, 600)
      assert %{released: 1} = SweepWorker.sweep()
      assert %{state: "running", claim_token: nil, rescues: 0, interruptions: 1} = reload(run)
    end

    test "when the attempts are spent Lifeline discards the job and the run fails" do
      run = kill_by_timeout(%{sleep_ms: 2_000, steps: 1})

      from(j in Oban.Job, where: j.id == ^reload(run).oban_job_id)
      |> Repo.update_all(set: [attempt: 3, max_attempts: 3])

      with_lifeline()
      assert %{state: "discarded"} = await_job_state(run, &(&1 != "executing"))
      stop_supervised!(:oban_lifeline)

      oban()
      backdate(run, 600)
      assert %{failed: 1} = SweepWorker.sweep()
      assert %{state: "failed", claim_token: nil, error: error} = reload(run)
      assert error =~ "used up its attempts"
    end
  end
end
