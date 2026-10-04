defmodule PhoenixKit.Modules.Storage.CaptureDateIntegrationTest do
  @moduledoc """
  Capture dates recorded against real stored bytes: the backfill job dating
  files stored before V200, and `ProcessFileJob`'s write refusing to
  downgrade a date. Files are stored in a local bucket under a temp directory
  exactly as an upload stores them; with Oban in `:manual` testing mode no
  `ProcessFileJob` runs, so every stored file starts without a date — the
  state of a file uploaded before V200.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Jobs
  alias PhoenixKit.Jobs.{Engine, Kinds, Run, SweepWorker}
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.CaptureDate
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Jobs.CaptureDateBackfill
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.Modules.Storage.Workers.CaptureDateBackfillJob
  alias PhoenixKit.Test.ExifFixture
  alias PhoenixKit.Users.Auth

  unless ExifFixture.available?() and System.find_executable("identify"),
    do: @moduletag(:skip)

  # `Manager` caches the enabled-bucket list in `:persistent_term`; without a
  # reset a test reads through the previous test's (already removed) bucket.
  @buckets_cache :phoenix_kit_buckets_cache

  @exif %{date_time_original: "2018:07:31 23:04:05", offset_time_original: "-07:00"}

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "pk_capture_date_#{n}")
    sources = Path.join(System.tmp_dir!(), "pk_capture_date_src_#{n}")
    File.mkdir_p!(sources)

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "capture-date-test-#{n}",
        provider: "local",
        endpoint: tmp_root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    {:ok, user} =
      Auth.register_user(%{
        "email" => "capture-date-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(tmp_root)
      File.rm_rf(sources)
    end)

    %{user: user, sources: sources}
  end

  # Stores a JPEG carrying `tags` under the upload name `name`.
  defp store_jpeg!(ctx, name, tags \\ %{}) do
    path = Path.join(ctx.sources, "#{System.unique_integer([:positive])}.jpg")
    ExifFixture.write_jpeg!(path, tags)
    store!(ctx.user, path, "image", "jpg", name)
  end

  defp store!(user, path, file_type, ext, name) do
    checksum = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
    {:ok, file} = Storage.store_file_in_buckets(path, file_type, user.uuid, checksum, ext, name)
    file
  end

  defp reload(file), do: Repo.get!(StorageFile, file.uuid)

  defp backdate_run(run) do
    old = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(r in Run, where: r.uuid == ^run.uuid), set: [updated_at: old])
  end

  defp set!(file, fields) do
    {1, _} = Repo.update_all(from(f in StorageFile, where: f.uuid == ^file.uuid), set: fields)
    reload(file)
  end

  describe "CaptureDateBackfillJob.record/1" do
    test "dates a stored photo from its EXIF", ctx do
      file = store_jpeg!(ctx, "holiday.jpg", @exif)
      assert file.taken_at == nil

      assert CaptureDateBackfillJob.record(file.uuid) == :ok

      assert %{
               taken_at: ~U[2018-08-01 06:04:05Z],
               taken_on: ~D[2018-07-31],
               taken_at_offset: -25_200,
               taken_at_source: "exif"
             } = reload(file)
    end

    test "without EXIF, from the date in the file name", ctx do
      file = store_jpeg!(ctx, "IMG_20180701_120000.jpg")

      assert CaptureDateBackfillJob.record(file.uuid) == :ok
      assert %{taken_at_source: "filename", taken_on: ~D[2018-07-01]} = reload(file)
    end

    test "never touches a date set by hand", ctx do
      file =
        ctx
        |> store_jpeg!("holiday.jpg", @exif)
        |> set!(
          taken_at: ~U[2001-01-01 12:00:00Z],
          taken_on: ~D[2001-01-01],
          taken_at_source: "manual"
        )

      assert CaptureDateBackfillJob.record(file.uuid) == :kept
      assert %{taken_on: ~D[2001-01-01], taken_at_source: "manual"} = reload(file)
    end

    test "dates an edited image from its unedited backup, not its edited bytes", ctx do
      # An edit keeps only the ICC profile, so the file's own bytes carry no
      # EXIF; the date is still in the unedited original it points at.
      edited = store_jpeg!(ctx, "holiday.jpg")

      backup =
        ctx
        |> store_jpeg!("unedited-original", @exif)
        |> set!(system_managed: true, parent_file_uuid: edited.uuid)

      edited = set!(edited, original_file_uuid: backup.uuid)

      assert CaptureDateBackfillJob.record(edited.uuid) == :ok
      assert %{taken_at_source: "exif", taken_on: ~D[2018-07-31]} = reload(edited)
    end

    test "a backup that appears before the write is not dated from the file name", ctx do
      file = store_jpeg!(ctx, "IMG_20180701_120000.jpg")

      backup =
        ctx
        |> store_jpeg!("unedited-original", @exif)
        |> set!(system_managed: true, parent_file_uuid: file.uuid)

      file = set!(file, original_file_uuid: backup.uuid)
      attrs = CaptureDate.resolve(nil, file)

      # The pass read this file's own uuid, then the download failed — the
      # edit that created the backup landed in between. The filename must
      # not stick; the next record reads the backup.
      assert CaptureDateBackfillJob.write(file, file.uuid, nil, attrs) == :changed
      assert reload(file).taken_at == nil

      assert CaptureDateBackfillJob.record(file.uuid) == :ok
      assert %{taken_at_source: "exif", taken_on: ~D[2018-07-31]} = reload(file)
    end

    test "a file whose bytes are gone is still dated, from its name", ctx do
      file = store_jpeg!(ctx, "IMG_20180701_120000.jpg")

      {_, _} =
        Repo.delete_all(
          from(i in PhoenixKit.Modules.Storage.FileInstance, where: i.file_uuid == ^file.uuid)
        )

      assert CaptureDateBackfillJob.record(file.uuid) == :ok
      assert %{taken_at_source: "filename"} = reload(file)
    end

    test "a file that no longer exists is :gone" do
      assert CaptureDateBackfillJob.record(UUIDv7.generate()) == :gone
    end
  end

  describe "a pass" do
    test "run_pass/1 dates every image once, skipping backups and documents", ctx do
      a = store_jpeg!(ctx, "a.jpg", @exif)
      b = store_jpeg!(ctx, "IMG_20180701_120000.jpg")
      c = store_jpeg!(ctx, "c.jpg")

      _backup =
        ctx |> store_jpeg!("b.jpg", @exif) |> set!(system_managed: true, parent_file_uuid: a.uuid)

      pdf = Path.join(ctx.sources, "doc.pdf")
      File.write!(pdf, "%PDF-1.4 not really")
      document = store!(ctx.user, pdf, "document", "pdf", "IMG_20180701_120000.pdf")

      assert CaptureDateBackfillJob.pending_count() == 3

      parent = self()
      totals = CaptureDateBackfillJob.run_pass(&send(parent, {:progress, &1}))

      assert totals == %{ok: 3}
      assert_received {:progress, %{ok: 3}}
      assert CaptureDateBackfillJob.pending_count() == 0

      assert reload(a).taken_at_source == "exif"
      assert reload(b).taken_at_source == "filename"
      assert reload(c).taken_at_source == "inserted_at"
      assert reload(document).taken_at == nil
    end

    test "a re-run keeps every date it already recorded", ctx do
      file = store_jpeg!(ctx, "holiday.jpg", @exif)
      assert CaptureDateBackfillJob.run_pass() == %{ok: 1}

      # Nothing is pending any more; recording the file again rewrites the
      # same EXIF date (an equal source may replace an equal one).
      assert CaptureDateBackfillJob.run_pass() == %{}
      assert CaptureDateBackfillJob.record(file.uuid) == :ok
      assert %{taken_at_source: "exif", taken_on: ~D[2018-07-31]} = reload(file)
    end

    test "only one pass is active at a time: a second start gets the first run back" do
      assert {:ok, run, :started} = CaptureDateBackfillJob.enqueue()
      assert {:ok, again, :existing} = CaptureDateBackfillJob.enqueue()
      assert again.uuid == run.uuid
      assert run.mode == "auto"
    end

    test "a job queued by an earlier release starts the run and ends", ctx do
      store_jpeg!(ctx, "holiday.jpg", @exif)

      assert CaptureDateBackfillJob.perform(%Oban.Job{args: %{"after" => "x"}}) == :ok
      assert CaptureDateBackfillJob.perform(%Oban.Job{args: %{}}) == :ok

      assert [run] = Jobs.list_runs(kind: "storage.capture_date_backfill")
      assert run.state in ["queued", "running"]
    end
  end

  describe "as a job run (storage.capture_date_backfill)" do
    test "dates every file, with progress and the whole pass's outcomes", ctx do
      store_jpeg!(ctx, "a.jpg", @exif)
      store_jpeg!(ctx, "20180701_b.jpg")
      store_jpeg!(ctx, "c.jpg")

      assert {:ok,
              %{state: "completed", done: 3, failed_count: 0, total: 3, mode: "script"} = run} =
               Jobs.run_inline(CaptureDateBackfill, :site)

      assert run.result == %{"outcomes" => %{"ok" => 3}}
      assert CaptureDateBackfillJob.pending_count() == 0
      assert run.title =~ "taken"
    end

    test "walks a pass of more than one batch, and carries the cursor and the outcomes across",
         ctx do
      for n <- 1..52, do: store_jpeg!(ctx, "f#{n}.jpg")

      parent = self()

      assert {:ok, %{state: "completed", done: 52, total: 52} = run} =
               Jobs.run_inline(CaptureDateBackfill, :site,
                 on_progress: &send(parent, {:progress, &1})
               )

      assert run.result == %{"outcomes" => %{"ok" => 52}}
      # one full batch of 50, then the 2 left
      assert_received {:progress, %{done: 50, cursor: %{"after" => _}, total: 52}}
      assert CaptureDateBackfillJob.pending_count() == 0
    end

    test "queued, it runs batch after batch through Oban and can be paused between them", ctx do
      for n <- 1..52, do: store_jpeg!(ctx, "g#{n}.jpg")
      {:ok, run, :started} = CaptureDateBackfillJob.enqueue()

      # storing the files queued their processing jobs; only the run is under test
      Repo.delete_all(from j in Oban.Job, where: j.worker != "PhoenixKit.Jobs.RunWorker")

      # one batch, then pause: the successor is dispatched, and does nothing
      assert %{success: 1} = Oban.drain_queue(queue: :file_processing, with_recursion: false)
      assert %{state: "running", done: 50} = Repo.get!(Run, run.uuid)

      {:ok, _} = Engine.transition(run.uuid, {:pause, nil})
      Oban.drain_queue(queue: :file_processing, with_recursion: true)
      assert %{state: "paused", done: 50} = Repo.get!(Run, run.uuid)

      # resumed, it finishes from its cursor: the 50 are not done twice
      {:ok, _} = Engine.transition(run.uuid, {:resume, nil})
      Oban.drain_queue(queue: :file_processing, with_recursion: true)
      assert %{state: "completed", done: 52} = Repo.get!(Run, run.uuid)
    end

    test "a batch that dies after dating files and before its checkpoint: each file stays dated once, the retry finishes the rest, and the counts are only what a checkpoint recorded",
         ctx do
      files = for n <- 1..3, do: store_jpeg!(ctx, "crash#{n}.jpg", @exif)
      {:ok, run, :started} = CaptureDateBackfillJob.enqueue()
      Repo.delete_all(from j in Oban.Job, where: j.worker != "PhoenixKit.Jobs.RunWorker")
      job = Repo.get!(Oban.Job, Repo.get!(Run, run.uuid).oban_job_id)

      # The first batch takes its claim and dates two files — its side effect — and
      # the node dies before the checkpoint.
      {:ok, _held, _token} = Engine.claim(run.uuid, 1)
      [dated_a, dated_b, _left] = files
      assert CaptureDateBackfillJob.record(dated_a.uuid) == :ok
      assert CaptureDateBackfillJob.record(dated_b.uuid) == :ok
      first = {reload(dated_a).taken_at, reload(dated_b).taken_at}

      # Oban gives the job back; the sweeper releases the dead batch's claim.
      backdate_run(run)
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "available"])
      assert %{released: 1} = SweepWorker.sweep()
      assert %{claim_token: nil, state: "running", done: 0} = Repo.get!(Run, run.uuid)

      # The retry takes the claim and finishes what is left.
      Oban.drain_queue(queue: :file_processing, with_recursion: true)
      final = Repo.get!(Run, run.uuid)

      # File state: every file dated, the two the dead batch dated untouched.
      assert Enum.all?(files, &(reload(&1).taken_at != nil))
      assert {reload(dated_a).taken_at, reload(dated_b).taken_at} == first

      # Progress: the run completed, but counts only the file its checkpointed batch
      # handled. The two dated by the batch that died are in nobody's tally — the
      # documented, approximate-after-a-crash behaviour (`Jobs.Kind`).
      assert %{state: "completed", done: 1, total: 1, failed_count: 0} = final

      # ... and the run says so: the interruption is recorded apart from the
      # lost-dispatch rescues, so the Jobs page and the Mix task can disclose it.
      assert %{interruptions: 1, rescues: 0, error: nil} = final
      assert CaptureDateBackfillJob.pending_count() == 0
    end

    test "needs media.manage as well as jobs.manage" do
      assert CaptureDateBackfill.permission() == "media.manage"
      assert CaptureDateBackfill in Kinds.all()
    end
  end

  describe "paths that do not go through ProcessFileJob" do
    test "store_file/2 records the date from the bytes it just stored", ctx do
      path = Path.join(ctx.sources, "attach.jpg")
      ExifFixture.write_jpeg!(path, @exif)
      %{size: size} = File.stat!(path)

      assert {:ok, file} =
               Storage.store_file(path,
                 filename: "IMG_20180701_120000.jpg",
                 content_type: "image/jpeg",
                 size_bytes: size,
                 user_uuid: ctx.user.uuid
               )

      assert %{taken_at_source: "exif", taken_on: ~D[2018-07-31]} = reload(file)
    end

    test "a cross-user copy keeps the donor's capture date", ctx do
      path = Path.join(ctx.sources, "shared.jpg")
      ExifFixture.write_jpeg!(path, %{})
      checksum = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

      donor =
        store!(ctx.user, path, "image", "jpg", "holiday.jpg")
        |> set!(
          status: "active",
          taken_at: ~U[2018-08-01 06:04:05Z],
          taken_on: ~D[2018-07-31],
          taken_at_offset: -25_200,
          taken_at_source: "exif"
        )

      {:ok, other} =
        Auth.register_user(%{
          "email" => "capture-date-other-#{System.unique_integer([:positive])}@example.com",
          "password" => "ValidPassword123!"
        })

      assert {:ok, clone, :duplicate} =
               Storage.store_file_in_buckets(
                 path,
                 "image",
                 other.uuid,
                 checksum,
                 "jpg",
                 "holiday.jpg"
               )

      refute clone.uuid == donor.uuid

      assert %{taken_at_source: "exif", taken_on: ~D[2018-07-31], taken_at_offset: -25_200} =
               reload(clone)
    end
  end

  describe "ProcessFileJob.update_file_with_metadata/3" do
    test "never downgrades an EXIF date to a weaker one", ctx do
      file =
        ctx
        |> store_jpeg!("IMG_20200101_120000.jpg")
        |> set!(
          taken_at: ~U[2018-08-01 06:04:05Z],
          taken_on: ~D[2018-07-31],
          taken_at_offset: -25_200,
          taken_at_source: "exif"
        )

      source = Storage.get_file_instance_by_name(file.uuid, "original").file_name

      weaker = %{
        width: 64,
        height: 48,
        taken_at: ~U[2020-01-01 12:00:00Z],
        taken_on: ~D[2020-01-01],
        taken_at_offset: nil,
        taken_at_source: "filename"
      }

      assert ProcessFileJob.update_file_with_metadata(file, source, weaker) == :ok

      # The dimensions are written; the date is left as it was.
      assert %{width: 64, taken_on: ~D[2018-07-31], taken_at_source: "exif"} = reload(file)
    end

    test "records a date on a file that has none", ctx do
      file = store_jpeg!(ctx, "holiday.jpg")
      source = Storage.get_file_instance_by_name(file.uuid, "original").file_name

      attrs = %{
        taken_at: ~U[2018-08-01 06:04:05Z],
        taken_on: ~D[2018-07-31],
        taken_at_offset: -25_200,
        taken_at_source: "exif"
      }

      assert ProcessFileJob.update_file_with_metadata(file, source, attrs) == :ok
      assert %{taken_on: ~D[2018-07-31], taken_at_source: "exif", status: "active"} = reload(file)
    end
  end
end
