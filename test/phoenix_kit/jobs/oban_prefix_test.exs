defmodule PhoenixKit.Jobs.ObanPrefixTest do
  @moduledoc """
  Recovery and the Jobs page read Oban's own table through Oban's configured
  prefix (§16 F4). A host whose Oban lives in a named schema has its dispatches
  there; a lookup in the connection's default schema finds nothing — and a sweeper
  that finds nothing rescues a healthy run until its budget is gone.

  The scratch schema is created inside the test's sandbox transaction, so it
  vanishes with it. The public `oban_jobs` table exists too, with decoys.
  """
  use PhoenixKit.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox

  alias PhoenixKit.Jobs.{Engine, ObanStore, Run, SweepWorker}
  alias PhoenixKit.Test.JobKinds.Counter

  @prefix "jr_oban_scratch"

  # The schema is committed (see below), so it must be dropped when the suite is
  # done — not in `on_exit/1`, which runs while the test's own sandbox transaction
  # still holds locks on its table. A leftover from a killed run is dropped by the
  # next setup.
  setup_all do
    ExUnit.after_suite(fn _result ->
      Sandbox.unboxed_run(Repo, fn -> Repo.query!("DROP SCHEMA IF EXISTS #{@prefix} CASCADE") end)
    end)

    :ok
  end

  setup do
    # Committed, not inside the sandbox: Oban checks its migration version on a
    # connection of its own at start (`Oban.Migration.verify_migrated!/1`).
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("DROP SCHEMA IF EXISTS #{@prefix} CASCADE")
      Repo.query!("CREATE SCHEMA #{@prefix}")
      Repo.query!("CREATE TABLE #{@prefix}.oban_jobs (LIKE public.oban_jobs INCLUDING ALL)")

      # Oban reads the table's migration version from its comment.
      %{rows: [[version]]} = Repo.query!("SELECT obj_description('public.oban_jobs'::regclass)")
      Repo.query!("COMMENT ON TABLE #{@prefix}.oban_jobs IS '#{version}'")
    end)

    start_supervised!(
      {Oban,
       name: Oban,
       repo: PhoenixKit.Test.Repo,
       prefix: @prefix,
       testing: :manual,
       queues: [],
       plugins: []}
    )

    :ok
  end

  defp start! do
    assert {:ok, run, :started} = Engine.start(Counter, :site, [])
    run
  end

  defp reload(run), do: Repo.get!(Run, run.uuid)

  defp backdate(run) do
    old = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(r in Run, where: r.uuid == ^run.uuid), set: [updated_at: old])
  end

  defp prefixed_job(run) do
    Repo.one!(from(j in Oban.Job, where: j.id == ^reload(run).oban_job_id), prefix: @prefix)
  end

  test "a dispatch is inserted into the prefixed table, where the sweeper looks" do
    run = start!()
    assert %Oban.Job{state: "available"} = prefixed_job(run)

    assert Repo.aggregate(from(j in "oban_jobs", where: j.id == ^reload(run).oban_job_id), :count) ==
             0
  end

  test "a healthy, quiet run is left alone — the lookup finds its job in the prefix" do
    run = start!()
    backdate(run)

    assert %{released: 0, failed: 0, rescued: 0} = SweepWorker.sweep()
    assert %{generation: 1, rescues: 0} = reload(run)
  end

  test "a row of the public table with the same id does not decide for the run" do
    run = start!()
    id = reload(run).oban_job_id

    # A decoy: another worker, 'completed', same integer id, in the default schema.
    Repo.query!(
      """
      INSERT INTO public.oban_jobs (id, state, queue, worker, args, max_attempts)
      VALUES ($1, 'completed', 'default', 'Other.Worker', '{}'::jsonb, 1)
      """,
      [id]
    )

    backdate(run)
    assert %{rescued: 0} = SweepWorker.sweep()
    assert %{generation: 1} = reload(run)
  end

  test "a really lost dispatch in the prefix is still rescued" do
    run = start!()

    from(j in Oban.Job, where: j.id == ^reload(run).oban_job_id)
    |> Map.put(:prefix, @prefix)
    |> Repo.update_all(set: [state: "completed"])

    backdate(run)
    assert %{rescued: 1} = SweepWorker.sweep()
    assert %{generation: 2, rescues: 1} = reload(run)
  end

  test "dispatch_of/1 refuses a job that is not this run's current dispatch" do
    run = start!()
    other = start_other()

    # Point the run at the other run's job: same table, wrong run.
    Repo.update_all(from(r in Run, where: r.uuid == ^run.uuid),
      set: [oban_job_id: reload(other).oban_job_id]
    )

    assert nil == ObanStore.dispatch_of(reload(run))
  end

  defp start_other do
    {:ok, run, :started} = Engine.start(Counter, {"library", Ecto.UUID.generate()}, [])
    run
  end

  test "the page's counts read the prefixed table" do
    start!()
    start_other()

    assert %{"available" => available} = ObanStore.state_counts()
    assert available == 2
    assert PhoenixKit.Jobs.get_job_stats().available == 2
  end

  test "stalled queues match the current run across the configured schemas" do
    run = start!()
    old = DateTime.utc_now() |> DateTime.add(-1200, :second)

    from(j in Oban.Job, where: j.id == ^reload(run).oban_job_id)
    |> Repo.update_all([set: [scheduled_at: old]], prefix: @prefix)

    assert ["default"] == ObanStore.stalled_queues()

    {:ok, _} = Engine.transition(run.uuid, {:pause, nil})
    assert [] == ObanStore.stalled_queues()
  end

  describe "where no Oban instance runs (a script, a web-only node)" do
    # The prefix is known only from a running instance. Without one nothing may be
    # guessed: reading the repo's default schema would show another table's rows.
    setup do
      run = start!()
      id = reload(run).oban_job_id
      stop_supervised!(Oban)

      Repo.query!(
        """
        INSERT INTO public.oban_jobs (id, state, queue, worker, args, max_attempts)
        VALUES ($1, 'available', 'default', 'Public.Decoy', '{}'::jsonb, 1)
        """,
        [id]
      )

      %{run: run, id: id}
    end

    test "says it is unavailable", %{run: run} do
      refute ObanStore.available?()
      assert :unavailable == ObanStore.dispatch_of(reload(run))
    end

    test "listings, one-row reads and counts answer their defaults, not the public table's decoy",
         %{id: id} do
      query = from(j in Oban.Job, where: j.id == ^id)

      assert [] == ObanStore.all(query)
      assert nil == ObanStore.one(query)
      assert 0 == ObanStore.aggregate(query, :count)
      assert %{} == ObanStore.state_counts()
      assert [] == ObanStore.all(query, [])
      assert :none == ObanStore.one(query, :none)
    end

    test "the stats are zeros", %{} do
      assert %{available: 0, executing: 0} = PhoenixKit.Jobs.get_job_stats()
    end
  end
end
