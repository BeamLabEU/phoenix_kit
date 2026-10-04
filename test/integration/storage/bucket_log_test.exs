defmodule PhoenixKit.Modules.Storage.BucketLogTest do
  @moduledoc """
  The bucket log (V208): what `Manager` and the probe write to it, that a
  repeat is one row, that a miss, a user's bucket and an unsaved bucket are not
  logged, and how it is read back and pruned.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{BucketLog, BucketLogEntry, Manager}
  alias PhoenixKit.Modules.Storage.Workers.BucketLogPruneWorker
  alias PhoenixKit.Test.Repo

  setup do
    root = Path.join(System.tmp_dir!(), "pk_bucket_log_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, bucket} =
      Storage.create_bucket(
        %{
          name: "log-#{System.unique_integer([:positive])}",
          provider: "local",
          endpoint: root,
          enabled: true,
          priority: 0
        },
        profile: nil
      )

    %{bucket: bucket, root: root}
  end

  defp entries(bucket),
    do: Repo.all(from(e in BucketLogEntry, where: e.bucket_uuid == ^bucket.uuid))

  describe "record_failure/3" do
    test "writes a failure with its reason", %{bucket: bucket} do
      :ok = BucketLog.record_failure(bucket, "write", "Disk full")

      assert [%{kind: "write", ok: false, message: "Disk full", count: 1}] = entries(bucket)
    end

    test "the same failure again within a minute is one row with a count", %{bucket: bucket} do
      for _ <- 1..3, do: BucketLog.record_failure(bucket, "read", "timeout")

      assert [%{count: 3, kind: "read"}] = entries(bucket)
    end

    test "a different message, kind or an older row is a row of its own", %{bucket: bucket} do
      BucketLog.record_failure(bucket, "read", "timeout")
      BucketLog.record_failure(bucket, "read", "denied")
      BucketLog.record_failure(bucket, "write", "timeout")

      assert length(entries(bucket)) == 3

      Repo.update_all(
        from(e in BucketLogEntry, where: e.bucket_uuid == ^bucket.uuid),
        set: [last_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -3600)]
      )

      BucketLog.record_failure(bucket, "read", "timeout")
      assert length(entries(bucket)) == 4
    end

    test "a miss is not a failure", %{bucket: bucket} do
      BucketLog.record_failure(bucket, "read", "Failed to copy file: :enoent")
      BucketLog.record_failure(bucket, "read", ~s|{:http_error, 404, "NoSuchKey"}|)

      assert entries(bucket) == []
    end

    test "a user's own bucket and an unsaved one are never logged", %{bucket: bucket} do
      BucketLog.record_failure(%{bucket | owner_uuid: Ecto.UUID.generate()}, "write", "x")
      BucketLog.record_failure(%{bucket | uuid: nil}, "write", "x")
      BucketLog.record_failure(nil, "write", "x")

      assert entries(bucket) == []
    end

    test "keeps the message to a sane length and never raises", %{bucket: bucket} do
      assert :ok = BucketLog.record_failure(bucket, "write", String.duplicate("x", 5000))
      assert [%{message: message}] = entries(bucket)
      assert String.length(message) == 500

      assert :ok = BucketLog.record_failure(bucket, "nonsense", "x")
    end
  end

  describe "what Manager reports" do
    test "a write that fails is logged against the bucket that failed", %{
      bucket: bucket,
      root: root
    } do
      File.chmod!(root, 0o500)
      on_exit(fn -> File.chmod(root, 0o700) end)
      Manager.invalidate_bucket_cache()

      source =
        Path.join(System.tmp_dir!(), "pk_bucket_log_src_#{System.unique_integer([:positive])}")

      File.write!(source, "data")
      on_exit(fn -> File.rm(source) end)

      assert {:error, _} = Manager.store_file(source, force_bucket_ids: [bucket.uuid])

      assert [%{kind: "write", ok: false, message: message}] = entries(bucket)
      assert is_binary(message)
    end

    test "deleting an object that is not there is not a failure", %{bucket: bucket} do
      Manager.delete_from_bucket(bucket, "nothing/here.txt")

      assert entries(bucket) == []
    end
  end

  describe "probe_bucket/1" do
    test "logs a good probe with how long it took", %{bucket: bucket} do
      assert :ok = Storage.probe_bucket(bucket)

      assert [%{kind: "probe", ok: true, latency_ms: ms, message: nil}] = entries(bucket)
      assert is_integer(ms) and ms >= 0
    end

    test "logs a failed probe with what it said", %{bucket: bucket, root: root} do
      File.rm_rf!(root)
      File.write!(root, "not a directory")

      assert {:error, _} = Storage.probe_bucket(bucket)
      assert [%{kind: "probe", ok: false, message: message}] = entries(bucket)
      assert is_binary(message) and message != ""
    end

    test "repeated failed probes are each a row (the time is the point)", %{
      bucket: bucket,
      root: root
    } do
      File.rm_rf!(root)
      File.write!(root, "not a directory")

      Storage.probe_bucket(bucket)
      Storage.probe_bucket(bucket)

      assert length(entries(bucket)) == 2
    end

    test "the unsaved test of a form is not logged", %{root: root} do
      assert :ok =
               Storage.test_connection(%{
                 "name" => "x",
                 "provider" => "local",
                 "endpoint" => root
               })

      assert Repo.aggregate(BucketLogEntry, :count) == 0
    end
  end

  describe "reading it back" do
    test "recent/2 is newest first, paged, and can show only failures", %{bucket: bucket} do
      Storage.probe_bucket(bucket)
      for n <- 1..12, do: BucketLog.record_failure(bucket, "write", "failure #{n}")

      page = BucketLog.recent(bucket.uuid, per_page: 5)
      assert page.total == 13
      assert page.total_pages == 3
      assert length(page.entries) == 5

      failures = BucketLog.recent(bucket.uuid, filter: :failures, per_page: 50)
      assert failures.total == 12
      assert Enum.all?(failures.entries, &(not &1.ok))
    end

    test "summary/1 counts every failure of the day, merged repeats included", %{bucket: bucket} do
      for _ <- 1..4, do: BucketLog.record_failure(bucket, "read", "timeout")
      Storage.probe_bucket(bucket)

      summary = BucketLog.summary(bucket.uuid)

      assert summary.failures_24h == 4
      assert %{kind: "read"} = summary.last_failure
      assert %{kind: "probe", ok: true} = summary.last_probe
      assert [%{kind: "probe"}] = summary.probes
    end
  end

  describe "keeping it small" do
    test "prune/0 removes what was last seen before the retention, and no more", %{bucket: bucket} do
      BucketLog.record_failure(bucket, "write", "old")
      BucketLog.record_failure(bucket, "read", "new")

      Repo.update_all(
        from(e in BucketLogEntry, where: e.message == "old"),
        set: [last_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -31 * 86_400)]
      )

      assert BucketLog.prune() == 1
      assert [%{message: "new"}] = entries(bucket)
    end

    test "the worker prunes", %{bucket: bucket} do
      BucketLog.record_failure(bucket, "write", "old")

      Repo.update_all(
        from(e in BucketLogEntry, where: e.bucket_uuid == ^bucket.uuid),
        set: [last_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -400 * 86_400)]
      )

      assert :ok = BucketLogPruneWorker.perform(%Oban.Job{})
      assert entries(bucket) == []
    end

    test "deleting a bucket removes its log", %{bucket: bucket} do
      BucketLog.record_failure(bucket, "write", "x")
      assert length(entries(bucket)) == 1

      assert {:ok, _} = Storage.delete_bucket(bucket)
      assert entries(bucket) == []
    end
  end
end
