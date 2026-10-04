defmodule PhoenixKit.Modules.Storage.ReconcileKindTest do
  @moduledoc """
  The reconciler as job runs (`storage.reconcile`, plan `2026-10-03-job-runs.md`
  §6.2): one run per library, started by the trigger that every storage change
  already queues, throttled batch by batch, pausable between batches; and the
  scoped and "out of date" queries that library state is built on (R8).
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Jobs
  alias PhoenixKit.Jobs.{Engine, Run}
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Jobs.Reconcile
  alias PhoenixKit.Modules.Storage.{Libraries, Profiles, Reconciler}
  alias PhoenixKit.Modules.Storage.Workers.ReconcileJob
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  setup do
    n = System.unique_integer([:positive])
    roots = for side <- ~w(a b c d), do: Path.join(System.tmp_dir!(), "pk_rk_#{n}_#{side}")

    [a, b, c, d] =
      for root <- roots do
        {:ok, bucket} =
          Storage.create_bucket(%{
            name: "rk-#{Path.basename(root)}",
            provider: "local",
            endpoint: root,
            enabled: true,
            priority: 0
          })

        bucket
      end

    on_exit(fn -> Enum.each(roots, &File.rm_rf/1) end)

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    {:ok, user} =
      Auth.register_user(%{
        "email" => "rk-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    one = library!("One #{n}", a, n)
    two = library!("Two #{n}", b, n)

    %{n: n, user: user, one: one, two: two, c: c, d: d}
  end

  # A library on its own profile with one bucket.
  defp library!(name, bucket, n) do
    {:ok, library} = Libraries.create_system_library(%{name: name})
    {:ok, profile} = Profiles.create_profile(%{name: "P #{name} #{n}"})
    {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, %{})
    {:ok, library} = Profiles.set_library_profile(library, profile.uuid)
    %{library: library, profile: profile, bucket: bucket}
  end

  defp upload!(ctx, side, content) do
    path = Path.join(System.tmp_dir!(), "pk_rk_src_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    sha = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(path, "document", ctx.user.uuid, sha, "txt", "a.txt",
        library_uuid: side.library.uuid
      )

    {:ok, file} = Storage.update_file(file, %{status: "active"})
    file
  end

  # One more bucket in the library's profile: its files are now out of date.
  defp stale!(side, bucket) do
    profile = Profiles.get_profile(side.profile.uuid)
    {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, %{})

    {:ok, _} =
      Profiles.update_profile(Profiles.get_profile(side.profile.uuid), %{copies_local: 2})
  end

  # Storing a file queues its processing, and every change to a profile queues the
  # trigger; only the runs are under test here.
  defp without_processing_jobs do
    Repo.delete_all(
      from j in Oban.Job,
        where: like(j.worker, "%ProcessFileJob") or like(j.worker, "%ReconcileJob")
    )
  end

  defp drain do
    without_processing_jobs()
    Oban.drain_queue(queue: :file_processing, with_scheduled: true, with_recursion: true)
  end

  defp runs,
    do: Repo.all(from r in Run, where: r.kind == "storage.reconcile", order_by: r.inserted_at)

  defp stale?(file),
    do: Repo.exists?(from(f in Reconciler.stale_query(), where: f.uuid == ^file.uuid))

  describe "the queries" do
    test "stale_query/1 and stale_count/1 can be limited to one library", ctx do
      f1 = upload!(ctx, ctx.one, "one")
      f2 = upload!(ctx, ctx.two, "two")
      stale!(ctx.one, ctx.c)
      stale!(ctx.two, ctx.d)

      one = ctx.one.library.uuid
      assert Reconciler.stale_count(library_uuid: one) == 1

      assert Repo.exists?(
               from(f in Reconciler.stale_query(library_uuid: one), where: f.uuid == ^f1.uuid)
             )

      refute Repo.exists?(
               from(f in Reconciler.stale_query(library_uuid: one), where: f.uuid == ^f2.uuid)
             )

      assert Reconciler.pending?(library_uuid: one)
    end

    test "counts_by_library/0 tells out of date, eligible and failing apart", ctx do
      eligible = upload!(ctx, ctx.one, "eligible")
      failing = upload!(ctx, ctx.one, "failing")
      editing = upload!(ctx, ctx.one, "editing")
      _fine = upload!(ctx, ctx.two, "fine")
      stale!(ctx.one, ctx.c)

      recent =
        NaiveDateTime.utc_now() |> NaiveDateTime.add(-60) |> NaiveDateTime.truncate(:second)

      Repo.update_all(from(f in Storage.File, where: f.uuid == ^failing.uuid),
        set: [reconcile_attempted_at: recent]
      )

      Repo.update_all(from(f in Storage.File, where: f.uuid == ^editing.uuid),
        set: [edit_state: "pending"]
      )

      counts = Reconciler.counts_by_library()
      assert %{out_of_date: 3, eligible: 1, failing: 1} = counts[to_string(ctx.one.library.uuid)]
      refute Map.has_key?(counts, to_string(ctx.two.library.uuid))

      # eligible is the work-selection query's own number
      assert Reconciler.stale_count(library_uuid: ctx.one.library.uuid) == 1
      assert stale?(eligible)

      assert %{} == Reconciler.counts_by_library([ctx.two.library.uuid])
      assert %{} == Reconciler.counts_by_library([])

      assert %{out_of_date: 3} =
               Reconciler.counts_by_library([ctx.one.library.uuid])[ctx.one.library.uuid]
    end

    test "libraries_with_work/0 lists the libraries the reconciler may take now", ctx do
      upload!(ctx, ctx.one, "x")
      upload!(ctx, ctx.two, "y")
      stale!(ctx.one, ctx.c)

      assert to_string(ctx.one.library.uuid) in Reconciler.libraries_with_work()
      refute to_string(ctx.two.library.uuid) in Reconciler.libraries_with_work()
    end
  end

  describe "trigger/1" do
    test "records a restart even when the active run's files are temporarily ineligible", ctx do
      file = upload!(ctx, ctx.one, "waiting for an edit")
      stale!(ctx.one, ctx.c)
      {:ok, run, :started} = Jobs.System.start(Reconcile, {"library", ctx.one.library.uuid})
      {:ok, _, token} = Engine.claim(run.uuid, run.generation)

      Repo.update_all(from(f in Storage.File, where: f.uuid == ^file.uuid),
        set: [edit_state: "pending"]
      )

      refute Reconciler.pending?(library_uuid: ctx.one.library.uuid)
      assert {:ok, libraries} = Reconcile.trigger()
      assert ctx.one.library.uuid in libraries
      assert %{restart_seq: 1} = Repo.get!(Run, run.uuid)

      # Even a last batch must honor the recorded change rather than finish.
      {:ok, restarted} = Engine.checkpoint(run.uuid, token, {:done, %{}, %{}})
      assert %{state: "queued", cursor: %{}, restart_ack: 1} = restarted
    end

    test "does not report success when starting the runs is refused", ctx do
      upload!(ctx, ctx.one, "x")
      stale!(ctx.one, ctx.c)

      assert {:ok, {:error, :in_transaction}} = Repo.transaction(fn -> Reconcile.trigger() end)
      assert runs() == []
    end

    test "starts a run for each library with work, and for no other", ctx do
      upload!(ctx, ctx.one, "x")
      upload!(ctx, ctx.two, "y")
      stale!(ctx.one, ctx.c)

      assert {:ok, libraries} = Reconcile.trigger()
      assert to_string(ctx.one.library.uuid) in libraries

      assert [%Run{scope_type: "library", mode: "auto", state: "queued", title: title} = run] =
               Enum.filter(runs(), &(to_string(&1.scope_uuid) == to_string(ctx.one.library.uuid)))

      assert title =~ ctx.one.library.name
      assert run.args["source"] == "a change to storage settings"
      refute Enum.any?(runs(), &(to_string(&1.scope_uuid) == to_string(ctx.two.library.uuid)))
    end

    test "while a pass runs, a second trigger asks it to begin again instead of starting another",
         ctx do
      upload!(ctx, ctx.one, "x")
      stale!(ctx.one, ctx.c)

      Reconcile.trigger()
      Reconcile.trigger()

      assert [%Run{restart_seq: 1}] =
               Enum.filter(runs(), &(to_string(&1.scope_uuid) == to_string(ctx.one.library.uuid)))
    end
  end

  describe "a run" do
    test "brings its library's files up to date and leaves the other library's alone", ctx do
      f1 = upload!(ctx, ctx.one, "one")
      f2 = upload!(ctx, ctx.two, "two")
      stale!(ctx.one, ctx.c)
      stale!(ctx.two, ctx.d)

      {:ok, run, :started} =
        Jobs.System.start(Reconcile, {"library", to_string(ctx.one.library.uuid)})

      drain()

      assert %{state: "completed", done: 1, failed_count: 0, total: 1} = Repo.get!(Run, run.uuid)
      refute stale?(f1)
      assert stale?(f2)
    end

    test "walks more than a batch, throttled, and can be paused between batches", ctx do
      files = for i <- 1..12, do: upload!(ctx, ctx.one, "many #{i}")
      stale!(ctx.one, ctx.c)

      {:ok, run, :started} =
        Jobs.System.start(Reconcile, {"library", to_string(ctx.one.library.uuid)})

      without_processing_jobs()
      assert %{success: 1} = Oban.drain_queue(queue: :file_processing, with_recursion: false)
      assert %{state: "running", done: 10, total: 12} = Repo.get!(Run, run.uuid)

      {:ok, _} = Engine.transition(run.uuid, {:pause, nil})
      drain()
      assert %{state: "paused", done: 10} = Repo.get!(Run, run.uuid)
      assert Enum.count(files, &stale?/1) == 2

      {:ok, _} = Engine.transition(run.uuid, {:resume, nil})
      drain()

      assert %{state: "completed", done: 12} = Repo.get!(Run, run.uuid)
      refute Enum.any?(files, &stale?/1)
    end

    test "a file it cannot finish counts as failed, stays out of date, and is not retried at once",
         ctx do
      file = upload!(ctx, ctx.one, "stuck")
      # its only bucket is draining and there is nowhere else to put the copy
      profile = Profiles.get_profile(ctx.one.profile.uuid)
      {:ok, _} = Profiles.put_bucket(profile, ctx.one.bucket.uuid, %{status: "draining"})

      {:ok, run, :started} =
        Jobs.System.start(Reconcile, {"library", to_string(ctx.one.library.uuid)})

      drain()

      assert %{state: "completed", done: 0, failed_count: 1} = Repo.get!(Run, run.uuid)

      # it is tried and left: out of date and failing, but not eligible again for ten minutes
      assert %{out_of_date: 1, eligible: 0, failing: 1} =
               Reconciler.counts_by_library()[to_string(ctx.one.library.uuid)]

      refute stale?(file)
    end

    test "needs media.manage as well as jobs.manage" do
      assert Reconcile.permission() == "media.manage"
      assert Reconcile in Jobs.kinds()
    end
  end

  describe "the Oban job every change queues" do
    test "triggers the runs, and so does a job queued by an earlier release", ctx do
      upload!(ctx, ctx.one, "x")
      stale!(ctx.one, ctx.c)

      assert ReconcileJob.enqueue() == :queued

      assert %{success: success} =
               Oban.drain_queue(queue: :file_processing, with_recursion: false)

      assert success >= 1
      assert [%Run{state: "queued"}] = runs()

      # a job with an old cursor in its args: it just triggers
      Repo.delete_all(from r in Run, where: r.kind == "storage.reconcile")
      assert :ok = ReconcileJob.perform(%Oban.Job{args: %{"after" => Ecto.UUID.generate()}})
      assert [%Run{}] = runs()
    end

    test "only one waits at a time", _ctx do
      assert ReconcileJob.enqueue() == :queued
      assert ReconcileJob.enqueue() == :queued

      assert Repo.aggregate(
               from(j in Oban.Job,
                 where: j.worker == "PhoenixKit.Modules.Storage.Workers.ReconcileJob"
               ),
               :count
             ) == 1
    end

    test "maybe_enqueue/0 queues only when something is stale", ctx do
      upload!(ctx, ctx.one, "x")
      assert ReconcileJob.maybe_enqueue() == :nothing_to_do

      stale!(ctx.one, ctx.c)
      assert ReconcileJob.maybe_enqueue() == :queued
    end
  end

  describe "library state" do
    alias PhoenixKit.Modules.Storage.LibraryState

    defp state_of(side), do: LibraryState.for_library(side.library.uuid)

    defp start_run!(side),
      do: elem(Jobs.System.start(Reconcile, {"library", to_string(side.library.uuid)}), 1)

    test "nothing out of date is up to date, with no run", ctx do
      upload!(ctx, ctx.one, "x")
      assert %{state: :up_to_date, out_of_date: 0, run: nil} = state_of(ctx.one)
    end

    test "files out of date and no run is waiting — what a global count hides", ctx do
      upload!(ctx, ctx.one, "x")
      stale!(ctx.one, ctx.c)

      assert %{state: :waiting, out_of_date: 1, eligible: 1, run: nil} = state_of(ctx.one)
    end

    test "a queued or running run is syncing, and says how many files are left", ctx do
      for i <- 1..3, do: upload!(ctx, ctx.one, "x#{i}")
      stale!(ctx.one, ctx.c)
      run = start_run!(ctx.one)

      assert %{state: :syncing, out_of_date: 3, run: %Run{uuid: uuid}} = state_of(ctx.one)
      assert uuid == run.uuid
    end

    test "a paused run is paused, and so is one whose pause is waiting for its batch", ctx do
      upload!(ctx, ctx.one, "x")
      stale!(ctx.one, ctx.c)
      run = start_run!(ctx.one)
      {:ok, _} = Engine.transition(run.uuid, {:pause, nil})

      assert %{state: :paused} = state_of(ctx.one)
    end

    test "a failed run with files left, and files the reconciler keeps failing on, need attention",
         ctx do
      upload!(ctx, ctx.one, "x")
      stale!(ctx.one, ctx.c)
      run = start_run!(ctx.one)
      {:ok, _} = Engine.transition(run.uuid, {:fail, "boom"})
      assert %{state: :attention, run: %Run{state: "failed"}} = state_of(ctx.one)

      # the same with no failed run: the file itself keeps failing
      Repo.delete_all(from r in Run, where: r.kind == "storage.reconcile")
      file = upload!(ctx, ctx.two, "y")
      stale!(ctx.two, ctx.d)

      recent =
        NaiveDateTime.utc_now() |> NaiveDateTime.add(-30) |> NaiveDateTime.truncate(:second)

      Repo.update_all(from(f in Storage.File, where: f.uuid == ^file.uuid),
        set: [reconcile_attempted_at: recent]
      )

      assert %{state: :attention, failing: 1, run: nil} = state_of(ctx.two)
    end

    test "a failed run whose files have since been put right is simply up to date", ctx do
      upload!(ctx, ctx.one, "x")
      run = start_run!(ctx.one)
      {:ok, _} = Engine.transition(run.uuid, {:fail, "boom"})

      assert %{state: :up_to_date, run: %Run{state: "failed"}} = state_of(ctx.one)
    end

    test "for_libraries/1 answers every library asked for, in three queries", ctx do
      stale = upload!(ctx, ctx.one, "x")
      stale!(ctx.one, ctx.c)
      _ = stale

      states =
        LibraryState.for_libraries([
          ctx.one.library.uuid,
          ctx.two.library.uuid,
          Ecto.UUID.generate()
        ])

      assert Map.keys(states) |> length() == 3
      assert %{state: :waiting} = states[to_string(ctx.one.library.uuid)]
      assert %{state: :up_to_date} = states[to_string(ctx.two.library.uuid)]
    end
  end
end
