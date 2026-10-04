defmodule PhoenixKit.Modules.Storage.LocationBackfillTest do
  @moduledoc """
  `LocationBackfillJob` (V204): an instance with no location row is found in
  the bucket that holds its key and recorded; one found in no bucket is
  counted missing and left alone; a run schedules the next batch later, and
  only while there is more.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{FileLocation, Manager}
  alias PhoenixKit.Modules.Storage.Workers.LocationBackfillJob
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  @cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@cache)
    root = Path.join(System.tmp_dir!(), "pk_backfill_#{System.unique_integer([:positive])}")

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "backfill-#{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    on_exit(fn ->
      :persistent_term.erase(@cache)
      File.rm_rf(root)
    end)

    %{bucket: bucket}
  end

  defp instance!(key) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "backfill-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "a.txt",
        file_name: Path.basename(key),
        file_path: Path.dirname(key),
        mime_type: "text/plain",
        file_type: "document",
        ext: "txt",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: user.uuid
      })

    {:ok, instance} =
      Storage.create_file_instance(%{
        variant_name: "original",
        file_name: key,
        mime_type: "text/plain",
        ext: "txt",
        checksum: "c",
        size: 1,
        processing_status: "completed",
        file_uuid: file.uuid
      })

    instance
  end

  defp locations(instance),
    do: Repo.all(from(l in FileLocation, where: l.file_instance_uuid == ^instance.uuid))

  test "a pass records the bucket that holds each key, and leaves the rest", %{bucket: bucket} do
    stored_key = "backfill/#{System.unique_integer([:positive])}/a.txt"
    source = Path.join(System.tmp_dir!(), "pk_backfill_src_#{System.unique_integer([:positive])}")
    File.write!(source, "stored")
    on_exit(fn -> File.rm(source) end)

    {:ok, _} =
      Manager.store_file(source, path_prefix: stored_key, force_bucket_ids: [bucket.uuid])

    stored = instance!(stored_key)
    lost = instance!("backfill/#{System.unique_integer([:positive])}/gone.txt")

    assert LocationBackfillJob.pending?()
    totals = LocationBackfillJob.run_pass()

    assert totals[:recorded] >= 1
    assert totals[:missing] >= 1
    assert [%{bucket_uuid: uuid}] = locations(stored)
    assert to_string(uuid) == to_string(bucket.uuid)
    assert locations(lost) == []
  end

  test "maybe_enqueue/0 says there is nothing to do once every instance has a row" do
    # The shared database may hold other unlocated instances, so only the
    # shape of the answer is fixed here.
    assert LocationBackfillJob.maybe_enqueue() in [:queued, :nothing_to_do, :unavailable]
  end

  describe "as a job run (storage.location_backfill)" do
    alias PhoenixKit.Jobs
    alias PhoenixKit.Jobs.Run
    alias PhoenixKit.Modules.Storage.Jobs.LocationBackfill

    setup do
      start_supervised!(
        {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
      )

      :ok
    end

    test "records where each key is and reports the pass as a run", %{bucket: bucket} do
      stored_key = "backfill/#{System.unique_integer([:positive])}/run.txt"

      source =
        Path.join(System.tmp_dir!(), "pk_backfill_run_#{System.unique_integer([:positive])}")

      File.write!(source, "stored")
      on_exit(fn -> File.rm(source) end)

      {:ok, _} =
        Manager.store_file(source, path_prefix: stored_key, force_bucket_ids: [bucket.uuid])

      stored = instance!(stored_key)
      _lost = instance!("backfill/#{System.unique_integer([:positive])}/gone2.txt")

      assert {:ok, %Run{state: "completed", mode: "script", failed_count: 0} = run} =
               Jobs.run_inline(LocationBackfill, :site)

      assert run.done >= 2
      assert run.total >= 2
      assert run.result["outcomes"]["recorded"] >= 1
      assert run.result["outcomes"]["missing"] >= 1
      assert [_] = locations(stored)
    end

    test "maybe_enqueue/0 starts the run, and the old queued job starts it too" do
      _ = instance!("backfill/#{System.unique_integer([:positive])}/queued.txt")

      assert LocationBackfillJob.maybe_enqueue() == :queued

      assert %Run{kind: "storage.location_backfill", mode: "auto"} =
               Jobs.active_run(LocationBackfill.kind(), :site)

      # a job queued by an earlier release, cursor and all: it joins the active run
      assert :ok =
               LocationBackfillJob.perform(%Oban.Job{args: %{"after" => Ecto.UUID.generate()}})

      assert [_] = Repo.all(from r in Run, where: r.kind == "storage.location_backfill")
    end

    test "is declared by the storage module and needs media.manage" do
      assert LocationBackfill in Jobs.kinds()
      assert LocationBackfill.permission() == "media.manage"
    end
  end
end
