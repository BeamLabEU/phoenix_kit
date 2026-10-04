defmodule PhoenixKit.Jobs.EngineConcurrencyTest do
  @moduledoc """
  The engine's guarantees under real concurrency: separate database sessions, real
  commits, no sandbox. The ordinary engine tests drive each interleaving by hand;
  these let the database interleave them, and assert what must hold *whichever*
  order wins — one active run, one claim holder, a pause that never overlaps a
  batch, a cancel that cannot become a completion, a trigger that is not lost.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Jobs.{Engine, Run}
  alias PhoenixKit.Test.JobKinds.{Counter, Restarting}
  alias PhoenixKit.Test.Repo

  @moduletag :integration

  setup do
    Sandbox.mode(Repo, :auto)
    cleanup()

    start_supervised!({Oban, name: Oban, repo: Repo, testing: :manual, queues: [], plugins: []})

    on_exit(fn ->
      cleanup()
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  defp cleanup do
    Repo.delete_all(from r in Run, where: like(r.kind, "test.%"))
    Repo.delete_all(from j in Oban.Job, where: j.worker == "PhoenixKit.Jobs.RunWorker")

    Repo.delete_all(
      from e in PhoenixKit.Activity.Entry,
        where: e.resource_type == "job_run" and e.module == "test"
    )
  end

  defp reload(run), do: Repo.get!(Run, run.uuid)

  defp jobs_of(run) do
    Repo.all(
      from j in Oban.Job,
        where:
          j.worker == "PhoenixKit.Jobs.RunWorker" and
            fragment("?->>'run_uuid' = ?", j.args, ^run.uuid)
    )
  end

  defp concurrently(count, fun) do
    1..count
    |> Task.async_stream(fn n -> fun.(n) end, max_concurrency: count, timeout: 30_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  test "twenty starts at once make one run, one dispatch, and nineteen get that run back" do
    results = concurrently(20, fn _ -> Engine.start(Counter, :site) end)

    started = for {:ok, run, :started} <- results, do: run
    existing = for {:ok, run, :existing} <- results, do: run

    assert [run] = started
    assert length(existing) == 19
    assert Enum.all?(existing, &(&1.uuid == run.uuid))
    assert Repo.aggregate(from(r in Run, where: r.kind == "test.counter"), :count) == 1
    assert length(jobs_of(run)) == 1
  end

  test "ten claims at once for the same generation: one holds it, nine find it busy" do
    {:ok, run, :started} = Engine.start(Counter, :site)

    results = concurrently(10, fn _ -> Engine.claim(run.uuid, 1) end)

    assert [{:ok, claimed, token}] = Enum.filter(results, &match?({:ok, _, _}, &1))
    assert Enum.count(results, &(&1 == {:skip, :busy})) == 9
    assert reload(run).claim_token == token
    assert claimed.claim_token == token
  end

  test "pausing while a batch checkpoints never overlaps work, in either order" do
    for _ <- 1..25 do
      {:ok, run, :started} = Engine.start(Counter, :site, args: %{steps: 5})
      {:ok, _claimed, token} = Engine.claim(run.uuid, 1)

      [checkpoint, pause] =
        concurrently(2, fn
          1 ->
            Engine.checkpoint(run.uuid, token, {:more, %{cursor: %{"step" => 1}, done: 10}, []})

          2 ->
            Engine.transition(run.uuid, {:pause, nil})
        end)

      assert {:ok, _} = checkpoint
      assert {:ok, %{state: state}} = pause
      assert state in ["pausing", "paused"]

      # whichever won, the batch's work is recorded and the run ends up paused with no claim
      final = reload(run)
      assert %{state: "paused", claim_token: nil, done: 10} = final

      # any successor the checkpoint dispatched before the pause is inert
      Oban.drain_queue(queue: :default, with_scheduled: true, with_recursion: true)
      assert %{state: "paused", done: 10} = reload(run)

      Repo.delete_all(from r in Run, where: r.uuid == ^run.uuid)
    end
  end

  test "cancelling while the last batch finishes: cancelled or completed, never both and never stuck" do
    for _ <- 1..25 do
      {:ok, run, :started} = Engine.start(Counter, :site)
      {:ok, _claimed, token} = Engine.claim(run.uuid, 1)

      [done, cancel] =
        concurrently(2, fn
          1 -> Engine.checkpoint(run.uuid, token, {:done, %{done: 1}, %{}})
          2 -> Engine.transition(run.uuid, {:cancel, nil})
        end)

      assert {:ok, _} = done

      case cancel do
        # the cancel came first: the run was asked to cancel and the last batch settled it
        {:ok, _} -> assert %{state: "cancelled"} = reload(run)
        # the batch finished first: nothing was left to cancel
        {:error, :finished} -> assert %{state: "completed"} = reload(run)
      end

      assert %{claim_token: nil} = reload(run)
      Repo.delete_all(from r in Run, where: r.uuid == ^run.uuid)
    end
  end

  test "a trigger during the last batch is never lost" do
    for _ <- 1..25 do
      {:ok, run, :started} = Engine.start(Restarting, :site)
      {:ok, _claimed, token} = Engine.claim(run.uuid, 1)

      [done, trigger] =
        concurrently(2, fn
          1 -> Engine.checkpoint(run.uuid, token, {:done, %{done: 3}, %{}})
          2 -> Engine.start(Restarting, :site)
        end)

      assert {:ok, _} = done

      case trigger do
        # the run was still active: the request was kept, and the pass starts fresh
        {:ok, _, :existing} ->
          assert %{state: "queued", done: 0, restart_ack: ack, restart_seq: seq} = reload(run)
          assert ack == seq

        # the run had already completed: the trigger made a new run of its own
        {:ok, fresh, :started} ->
          assert fresh.uuid != run.uuid
          assert %{state: "completed"} = reload(run)
          assert %{state: "queued"} = reload(fresh)
      end

      Repo.delete_all(from r in Run, where: like(r.kind, "test.restarting"))
    end
  end

  test "two checkpoints with the same token: only the first lands" do
    {:ok, run, :started} = Engine.start(Counter, :site, args: %{steps: 5})
    {:ok, _claimed, token} = Engine.claim(run.uuid, 1)

    results =
      concurrently(2, fn _ ->
        Engine.checkpoint(run.uuid, token, {:more, %{cursor: %{"step" => 1}, done: 10}, []})
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :claim_lost})) == 1
    assert %{done: 10, generation: 2} = reload(run)
    assert length(jobs_of(run)) == 2
  end

  test "cancelling a draining run while others start the same kind: no second run until it drains" do
    for _ <- 1..10 do
      {:ok, run, :started} = Engine.start(Counter, :site, args: %{steps: 5})
      {:ok, _claimed, token} = Engine.claim(run.uuid, 1)

      results =
        concurrently(8, fn
          1 -> Engine.transition(run.uuid, {:cancel, nil})
          _ -> Engine.start(Counter, :site)
        end)

      assert {:ok, %{state: "cancelling"}} = hd(results)

      # every start met the draining run (never a fresh one) ...
      for {:ok, other, how} <- tl(results) do
        assert how == :existing
        assert other.uuid == run.uuid
      end

      assert Repo.aggregate(from(r in Run, where: r.kind == "test.counter"), :count) == 1

      # ... and only once the batch has settled can a new run begin
      {:ok, %{state: "cancelled"}} =
        Engine.checkpoint(run.uuid, token, {:more, %{cursor: %{"step" => 1}, done: 1}, []})

      assert {:ok, fresh, :started} = Engine.start(Counter, :site)
      refute fresh.uuid == run.uuid

      Repo.delete_all(from r in Run, where: like(r.kind, "test.%"))
    end
  end

  test "a queued claim and an inline claim race for one run: exactly one holds it" do
    for _ <- 1..25 do
      {:ok, run, :started} = Engine.start(Counter, :site)

      results =
        concurrently(2, fn
          1 -> Engine.claim(run.uuid, 1)
          2 -> Engine.claim_inline(run.uuid)
        end)

      winners = Enum.count(results, &match?({:ok, _, _}, &1))
      assert winners == 1, inspect(results)

      held = reload(run)
      assert held.claim_owner in ["queue", "inline"]
      assert not is_nil(held.claim_token)

      Repo.delete_all(from r in Run, where: like(r.kind, "test.%"))
    end
  end
end
