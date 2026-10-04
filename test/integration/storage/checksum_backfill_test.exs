defmodule PhoenixKit.Modules.Storage.ChecksumBackfillTest do
  @moduledoc """
  `ChecksumBackfillJob` (G12): a file the upload API stored with an MD5
  checksum gets the SHA-256 of its stored bytes and the matching dedup key,
  so it dedups against the same bytes uploaded any other way; one whose
  uploader already has those bytes as another file is left as it is.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Workers.ChecksumBackfillJob
  alias PhoenixKit.Users.Auth

  @cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@cache)
    root = Path.join(System.tmp_dir!(), "pk_checksum_#{System.unique_integer([:positive])}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "checksum-#{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    {:ok, user} =
      Auth.register_user(%{
        "email" => "checksum-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    on_exit(fn ->
      :persistent_term.erase(@cache)
      File.rm_rf(root)
    end)

    %{user: user}
  end

  defp sha(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
  defp md5(content), do: :md5 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  # Stored the way the upload API used to: its checksum is the MD5.
  defp stored!(user, content) do
    source = Path.join(System.tmp_dir!(), "pk_checksum_src_#{System.unique_integer([:positive])}")
    File.write!(source, content)
    on_exit(fn -> File.rm(source) end)

    {result, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        Storage.store_file_in_buckets(source, "document", user.uuid, md5(content), "txt", "a.txt")
      end)

    {:ok, file} = result
    file
  end

  test "an MD5 row gets its bytes' SHA-256 and the matching dedup key", %{user: user} do
    content = "api upload #{System.unique_integer([:positive])}"
    file = stored!(user, content)
    assert file.file_checksum == md5(content)

    assert ChecksumBackfillJob.recompute(file) == :updated

    updated = Storage.get_file(file.uuid)
    assert updated.file_checksum == sha(content)

    assert updated.user_file_checksum ==
             Storage.calculate_user_file_checksum(user.uuid, sha(content), updated.library_uuid)
  end

  test "a row whose uploader already has the bytes is left as it is", %{user: user} do
    content = "twice #{System.unique_integer([:positive])}"
    old = stored!(user, content)

    source = Path.join(System.tmp_dir!(), "pk_checksum_sha_#{System.unique_integer([:positive])}")
    File.write!(source, content)
    on_exit(fn -> File.rm(source) end)

    {{:ok, _sha_copy}, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        Storage.store_file_in_buckets(source, "document", user.uuid, sha(content), "txt", "b.txt")
      end)

    assert ChecksumBackfillJob.recompute(old) == :duplicate
    assert Storage.get_file(old.uuid).file_checksum == md5(content)

    # A pass marks it, so the next pass does not download it again.
    ChecksumBackfillJob.run_pass()
    assert Storage.get_file(old.uuid).metadata["checksum_backfill"] == "duplicate"
  end

  describe "as a job run (storage.checksum_backfill)" do
    alias PhoenixKit.Jobs
    alias PhoenixKit.Jobs.Run
    alias PhoenixKit.Modules.Storage.Jobs.ChecksumBackfill
    alias PhoenixKit.Test.Repo

    setup do
      start_supervised!(
        {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
      )

      :ok
    end

    test "recomputes every MD5 row, with progress and the pass's outcomes", %{user: user} do
      content_a = "run a #{System.unique_integer([:positive])}"
      content_b = "run b #{System.unique_integer([:positive])}"
      a = stored!(user, content_a)
      b = stored!(user, content_b)

      assert ChecksumBackfillJob.pending?()

      assert {:ok, %Run{state: "completed", mode: "script", failed_count: 0} = run} =
               Jobs.run_inline(ChecksumBackfill, :site)

      assert run.done >= 2 and run.total >= 2
      assert run.result["outcomes"]["updated"] >= 2
      assert Storage.get_file(a.uuid).file_checksum == sha(content_a)
      assert Storage.get_file(b.uuid).file_checksum == sha(content_b)
    end

    test "maybe_enqueue/0 starts the run only while a row is left, and the old job joins it",
         %{user: user} do
      stored!(user, "pending #{System.unique_integer([:positive])}")

      assert ChecksumBackfillJob.maybe_enqueue() == :queued
      assert %Run{mode: "auto"} = Jobs.active_run(ChecksumBackfill.kind(), :site)

      assert :ok =
               ChecksumBackfillJob.perform(%Oban.Job{args: %{"after" => Ecto.UUID.generate()}})

      assert [_] = Repo.all(from r in Run, where: r.kind == "storage.checksum_backfill")
    end

    test "is declared by the storage module and needs media.manage" do
      assert ChecksumBackfill in Jobs.kinds()
      assert ChecksumBackfill.permission() == "media.manage"
    end
  end
end
