defmodule PhoenixKit.Jobs.StateMachineTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Jobs.{Run, StateMachine}
  alias PhoenixKit.Migrations.Postgres.V207

  @now ~U[2026-10-03 12:00:00Z]
  @token "11111111-1111-1111-1111-111111111111"

  defp run(attrs \\ []), do: struct!(Run, Keyword.put_new(attrs, :state, "queued"))
  defp claimed(attrs \\ []), do: run([state: "running", claim_token: @token] ++ attrs)

  defp t(run, event), do: StateMachine.transition(run, event, @now)
  defp changes({:ok, changes, _effects}), do: changes

  describe "claim" do
    test "takes a queued or running run and marks it running" do
      for state <- ~w(queued running) do
        assert {:ok, %{claim_token: @token, state: "running", claimed_at: @now, started_at: @now},
                []} =
                 t(run(state: state), {:claim, @token})
      end
    end

    test "marks the claim as a queue batch's, and a release clears it" do
      assert %{claim_owner: "queue"} = changes(t(run(), {:claim, @token}))

      assert %{claim_owner: nil, claim_token: nil} =
               changes(t(claimed(claim_owner: "queue"), {:checkpoint, @token, {:release, "x"}}))
    end

    test "keeps the first start time" do
      started = ~U[2026-10-03 11:00:00Z]
      refute Map.has_key?(changes(t(run(started_at: started), {:claim, @token})), :started_at)
    end

    test "refuses a run that something already holds" do
      assert {:error, :claimed} = t(claimed(), {:claim, "other"})
    end

    test "refuses a run that is not waiting for a batch" do
      for state <- ~w(paused pausing cancelling completed failed cancelled) do
        assert {:error, :inactive} = t(run(state: state), {:claim, @token}), state
      end
    end

    test "takes a pending restart in: the pass starts fresh and the request is acknowledged" do
      run =
        run(
          restart_seq: 3,
          restart_ack: 1,
          done: 40,
          failed_count: 2,
          total: 100,
          cursor: %{"a" => 1}
        )

      assert %{done: 0, failed_count: 0, total: nil, cursor: %{}, restart_ack: 3} =
               changes(t(run, {:claim, @token}))
    end

    test "leaves a settled restart alone" do
      run = run(restart_seq: 2, restart_ack: 2, done: 40)
      refute Map.has_key?(changes(t(run, {:claim, @token})), :done)
    end
  end

  describe "pause" do
    test "a run that is waiting is paused at once" do
      assert {:ok, %{state: "paused", paused_by_uuid: "a", paused_at: @now},
              [{:log, "job.paused", _}]} =
               t(run(state: "queued"), {:pause, "a"})

      assert {:ok, %{state: "paused"}, _} = t(run(state: "running"), {:pause, "a"})
    end

    test "a run whose batch is executing is asked to pause, not paused" do
      assert {:ok, %{state: "pausing"}, [{:log, "job.pause_requested", _}]} =
               t(claimed(), {:pause, "a"})
    end

    test "says why it cannot" do
      assert {:error, :already_pausing} = t(claimed(state: "pausing"), {:pause, "a"})
      assert {:error, :already_paused} = t(run(state: "paused"), {:pause, "a"})
      assert {:error, :cancelling} = t(claimed(state: "cancelling"), {:pause, "a"})
      assert {:error, :finished} = t(run(state: "completed"), {:pause, "a"})
    end
  end

  describe "resume" do
    test "queues a paused run again under a new generation, with a dispatch" do
      run = run(state: "paused", generation: 4, paused_by_uuid: "a", paused_at: @now)

      assert {:ok, %{state: "queued", generation: 5, paused_by_uuid: nil, paused_at: nil},
              [{:dispatch, 0}, {:log, "job.resumed", _}]} = t(run, {:resume, "b"})
    end

    test "is refused while the batch is still draining" do
      assert {:error, :draining} = t(claimed(state: "pausing"), {:resume, "a"})
    end

    test "is refused for a run that is not paused" do
      for state <- ~w(queued running cancelling completed failed cancelled) do
        assert {:error, :not_paused} = t(run(state: state), {:resume, "a"}), state
      end
    end
  end

  describe "cancel" do
    test "a run nothing is working on is cancelled at once" do
      for state <- ~w(queued paused) do
        assert {:ok, %{state: "cancelled", cancelled_by_uuid: "a", finished_at: @now},
                [{:log, "job.cancelled", _}]} = t(run(state: state), {:cancel, "a"})
      end

      assert {:ok, %{state: "cancelled"}, _} = t(run(state: "running"), {:cancel, "a"})
    end

    test "a run whose batch is executing is asked to cancel, and the request wins over a pause" do
      for state <- ~w(running pausing) do
        assert {:ok, %{state: "cancelling", cancelled_by_uuid: "a"},
                [{:log, "job.cancel_requested", _}]} =
                 t(claimed(state: state), {:cancel, "a"})
      end
    end

    test "says why it cannot" do
      assert {:error, :already_cancelling} = t(claimed(state: "cancelling"), {:cancel, "a"})

      for state <- ~w(completed failed cancelled) do
        assert {:error, :finished} = t(run(state: state), {:cancel, "a"}), state
      end
    end
  end

  describe "checkpoint: a batch that has more to do" do
    test "adds its increments, keeps its cursor, releases the claim and dispatches the next batch" do
      run = claimed(done: 10, failed_count: 1, generation: 2)

      assert {:ok, changes, [{:dispatch, 2}]} =
               t(
                 run,
                 {:checkpoint, @token,
                  {:more, %{cursor: %{"after" => "x"}, done: 10, failed: 1, total: 90},
                   [schedule_in: 2]}}
               )

      assert %{
               done: 20,
               failed_count: 2,
               total: 90,
               cursor: %{"after" => "x"},
               claim_token: nil,
               claimed_at: nil,
               generation: 3
             } = changes
    end

    test "a snooze dispatches again without changing the progress" do
      run = claimed(done: 5, cursor: %{"a" => 1}, generation: 1)

      assert {:ok, %{done: 5, cursor: %{"a" => 1}, generation: 2, claim_token: nil},
              [{:dispatch, 30}]} =
               t(run, {:checkpoint, @token, {:snooze, 30}})
    end

    test "a stranger's token is refused: the claim was lost" do
      assert {:error, :claim_lost} = t(claimed(), {:checkpoint, "other", {:snooze, 1}})
      assert {:error, :claim_lost} = t(run(), {:checkpoint, @token, {:snooze, 1}})
    end
  end

  describe "checkpoint: the last batch" do
    test "completes the run and applies the last batch's increments in the same write" do
      run = claimed(done: 10)

      assert {:ok,
              %{
                state: "completed",
                done: 15,
                finished_at: @now,
                result: %{"ok" => true},
                claim_token: nil
              }, [{:log, "job.completed", _}]} =
               t(run, {:checkpoint, @token, {:done, %{done: 5}, %{"ok" => true}}})
    end

    test "a pause that arrived during the last batch does not stop it: the run completes" do
      run = claimed(state: "pausing", paused_by_uuid: "a")

      assert {:ok, %{state: "completed", result: %{"pause_arrived_after_the_last_batch" => true}},
              _} =
               t(run, {:checkpoint, @token, {:done, %{}, %{}}})
    end

    test "a cancel that arrived during the last batch wins: the run is cancelled, its result kept" do
      run = claimed(state: "cancelling", cancelled_by_uuid: "a", done: 3)

      assert {:ok,
              %{state: "cancelled", result: %{"n" => 1}, finished_at: @now, claim_token: nil}, _} =
               t(run, {:checkpoint, @token, {:done, %{done: 2}, %{"n" => 1}}})
    end
  end

  describe "checkpoint: a request to pause or cancel that was waiting for the batch" do
    test "pausing settles into paused, records the work, and dispatches nothing" do
      run = claimed(state: "pausing", paused_by_uuid: "a", paused_at: @now, done: 1)

      assert {:ok, %{state: "paused", done: 11, claim_token: nil}, [{:log, "job.paused", _}]} =
               t(run, {:checkpoint, @token, {:more, %{done: 10}, []}})
    end

    test "cancelling settles into cancelled and dispatches nothing" do
      run = claimed(state: "cancelling", cancelled_by_uuid: "a")

      assert {:ok, %{state: "cancelled", finished_at: @now}, [{:log, "job.cancelled", _}]} =
               t(run, {:checkpoint, @token, {:more, %{done: 1}, []}})

      assert {:ok, %{state: "cancelled"}, _} = t(run, {:checkpoint, @token, {:snooze, 5}})
    end
  end

  describe "restart" do
    test "a request is counted for an active run" do
      assert {:ok, %{restart_seq: 1}, []} = t(run(), :request_restart)
      assert {:ok, %{restart_seq: 4}, []} = t(claimed(restart_seq: 3), :request_restart)
    end

    test "is refused for a finished run" do
      assert {:error, :finished} = t(run(state: "completed"), :request_restart)
    end

    test "a trigger that arrived during the last batch starts a fresh pass instead of completing" do
      run = claimed(restart_seq: 2, restart_ack: 1, done: 50, generation: 3, cursor: %{"a" => 1})

      assert {:ok,
              %{
                state: "queued",
                done: 0,
                cursor: %{},
                restart_ack: 2,
                generation: _,
                claim_token: nil
              }, [{:dispatch, 0}, {:log, "job.restarted", _}]} =
               t(run, {:checkpoint, @token, {:done, %{done: 5}, %{}}})
    end

    test "also during a batch that has more to do" do
      run = claimed(restart_seq: 2, restart_ack: 1, done: 50)

      assert {:ok, %{state: "queued", done: 0, restart_ack: 2}, [{:dispatch, 0}, _]} =
               t(run, {:checkpoint, @token, {:more, %{done: 10, cursor: %{"x" => 1}}, []}})
    end

    test "never overrides a pause or a cancel: the request waits" do
      for state <- ~w(pausing cancelling) do
        run = claimed(state: state, restart_seq: 2, restart_ack: 1)

        assert {:ok, changes, _} = t(run, {:checkpoint, @token, {:more, %{done: 1}, []}})
        refute Map.has_key?(changes, :restart_ack), state
      end
    end
  end

  describe "a script's run between its batches (inline)" do
    test "keeps the script as owner, gives up the batch claim, and records when the next batch is due" do
      run = claimed(claim_owner: "inline")

      assert {:ok, changes, [{:dispatch, 600}]} =
               t(run, {:checkpoint, @token, {:more, %{done: 1}, schedule_in: 600}})

      # the owner is not among the changes: it stays
      assert %{claim_token: nil, wake_at: wake} = changes
      refute Map.has_key?(changes, :claim_owner)
      assert DateTime.diff(wake, @now) == 600

      assert {:ok, %{claim_token: nil, wake_at: snooze_wake} = snoozed, _} =
               t(run, {:checkpoint, @token, {:snooze, 30}})

      refute Map.has_key?(snoozed, :claim_owner)
      assert DateTime.diff(snooze_wake, @now) == 30
    end

    test "no delay, no wake time; a queue batch gives up its owner and records the time too" do
      kept = changes(t(claimed(claim_owner: "inline"), {:checkpoint, @token, {:more, %{}, []}}))
      assert %{wake_at: nil, claim_token: nil} = kept
      refute Map.has_key?(kept, :claim_owner)

      assert %{claim_owner: nil, wake_at: wake} =
               changes(
                 t(
                   claimed(claim_owner: "queue"),
                   {:checkpoint, @token, {:more, %{}, schedule_in: 5}}
                 )
               )

      assert DateTime.diff(wake, @now) == 5
    end

    test "the last batch, and anything that settles the run, ends the ownership" do
      run = claimed(claim_owner: "inline")

      assert %{claim_owner: nil, state: "completed"} =
               changes(t(run, {:checkpoint, @token, {:done, %{}, %{}}}))

      assert %{claim_owner: nil, state: "failed"} =
               changes(t(run, {:checkpoint, @token, {:fail, "x"}}))

      waiting = run(state: "running", claim_owner: "inline", wake_at: @now)

      assert %{claim_owner: nil, wake_at: nil, state: "paused"} =
               changes(t(waiting, {:pause, nil}))

      assert %{claim_owner: nil, wake_at: nil, state: "cancelled"} =
               changes(t(waiting, {:cancel, nil}))
    end

    test "the owner identity goes with the ownership, and is kept through the wait" do
      owned = claimed(claim_owner: "inline", owner_token: "owner-1")
      kept = changes(t(owned, {:checkpoint, @token, {:more, %{}, schedule_in: 5}}))
      refute Map.has_key?(kept, :owner_token)

      assert %{owner_token: nil} = changes(t(owned, {:checkpoint, @token, {:done, %{}, %{}}}))

      waiting = run(state: "running", claim_owner: "inline", owner_token: "owner-1")
      assert %{owner_token: nil} = changes(t(waiting, {:pause, nil}))
      assert %{owner_token: nil} = changes(t(waiting, {:cancel, nil}))
    end

    test "a pause is immediate: nothing is draining" do
      waiting = run(state: "running", claim_owner: "inline", wake_at: @now)
      assert {:ok, %{state: "paused"}, [{:log, "job.paused", _}]} = t(waiting, {:pause, nil})
    end
  end

  describe "interruptions" do
    test "a batch Oban will retry counts as one, and so does each further one" do
      assert %{interruptions: 1} = changes(t(claimed(), {:checkpoint, @token, {:release, "x"}}))

      assert %{interruptions: 3} =
               changes(t(claimed(interruptions: 2), {:checkpoint, @token, {:release, "x"}}))
    end

    test "a rescue is not one: no batch was cut off" do
      refute Map.has_key?(changes(t(run(state: "running"), {:rescue, 3})), :interruptions)
    end
  end

  describe "an error" do
    test "one Oban will retry releases the claim and changes no state" do
      run = claimed(generation: 2)

      assert {:ok, %{claim_token: nil, error: "boom"} = changes, []} =
               t(run, {:checkpoint, @token, {:release, "boom"}})

      refute Map.has_key?(changes, :state)
      refute Map.has_key?(changes, :generation)
    end

    test "while a pause was asked it settles the pause" do
      run = claimed(state: "pausing")

      assert {:ok, %{state: "paused", claim_token: nil}, [{:log, "job.paused", _}]} =
               t(run, {:checkpoint, @token, {:release, "boom"}})
    end

    test "a final one fails the run, unless a cancel was asked" do
      assert {:ok, %{state: "failed", error: "gave up", finished_at: @now, claim_token: nil},
              [{:log, "job.failed", %{"error" => "gave up"}}]} =
               t(claimed(), {:checkpoint, @token, {:fail, "gave up"}})

      assert {:ok, %{state: "cancelled"}, _} =
               t(claimed(state: "cancelling"), {:checkpoint, @token, {:fail, "gave up"}})
    end

    test "a run nothing holds can be failed from outside; one a batch holds cannot" do
      assert {:ok, %{state: "failed", error: "lost", claim_token: nil}, _} =
               t(run(state: "running"), {:fail, "lost"})

      assert {:error, :claimed} = t(claimed(), {:fail, "lost"})
      assert {:error, :finished} = t(run(state: "completed"), {:fail, "lost"})
    end

    test "a batch ends its own run through its checkpoint, whatever holds it" do
      assert {:ok, %{state: "failed", claim_token: nil, claim_owner: nil}, _} =
               t(claimed(claim_owner: "queue"), {:checkpoint, @token, {:fail, "gone"}})
    end
  end

  describe "rescue" do
    test "keeps the next-batch time, so a second rescue still waits" do
      due = DateTime.add(@now, 90, :second)

      kept = changes(t(run(state: "running", wake_at: due), {:rescue, 3}))
      refute Map.has_key?(kept, :wake_at), "the marker is left on the run"
    end

    test "carries what is left of the delay into the dispatch" do
      due = DateTime.add(@now, 90, :second)

      assert {:ok, _changes, [{:dispatch, 90}, _log]} =
               t(run(state: "running", wake_at: due), {:rescue, 3})

      past = DateTime.add(@now, -90, :second)

      assert {:ok, _changes, [{:dispatch, 0}, _log]} =
               t(run(state: "running", wake_at: past), {:rescue, 3})
    end

    test "gives a lost dispatch a new generation and counts it" do
      run = run(state: "running", rescues: 1, generation: 4)

      assert {:ok, %{rescues: 2, generation: 5, last_rescued_at: @now},
              [{:dispatch, 0}, {:log, "job.rescued", %{"rescues" => 2}}]} = t(run, {:rescue, 3})
    end

    test "is refused while a batch holds the run: a held claim is not a lost dispatch" do
      run = run(state: "running", rescues: 1, generation: 4, claim_token: @token)
      assert {:error, :claimed} = t(run, {:rescue, 3})
    end

    test "gives up at the limit, and the run fails instead of restarting for ever" do
      assert {:ok, %{state: "failed", error: error}, _} = t(run(rescues: 3), {:rescue, 3})
      assert error =~ "given up"
    end

    test "only touches a run that is waiting for a batch" do
      for state <- ~w(paused pausing cancelling completed failed cancelled) do
        assert {:error, :not_active} = t(run(state: state), {:rescue, 3}), state
      end
    end
  end

  test "a heartbeat needs the claim" do
    assert {:ok, %{heartbeat_at: @now}, []} = t(claimed(), {:heartbeat, @token})
    assert {:error, :claim_lost} = t(claimed(), {:heartbeat, "other"})
  end

  test "the states are the migration's" do
    assert Run.states() == V207.states()
    assert Run.active_states() == V207.active_states()
  end
end
