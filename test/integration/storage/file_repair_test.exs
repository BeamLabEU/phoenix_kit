defmodule PhoenixKit.Modules.Storage.FileRepairTest do
  @moduledoc """
  "Fix all issues": a copy that is gone or whose bytes differ is copied back from
  another bucket's good one, or, when no good copy is left, a size is made again
  from the original; an original with no good copy is reported as unrecoverable
  and nothing is made from it.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.FileRepair
  alias PhoenixKit.Modules.Storage.FileReport
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.Modules.Storage.Profiles
  alias PhoenixKit.Modules.Storage.Providers.Local
  alias PhoenixKit.Users.Auth

  @moduletag :tmp_dir
  @buckets_cache :phoenix_kit_buckets_cache

  unless System.find_executable("convert") && System.find_executable("identify"),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  setup %{tmp_dir: tmp} do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])

    # Only this test's buckets: the seeded default one outlasts the test.
    Repo.update_all(Bucket, set: [enabled: false])
    on_exit(fn -> :persistent_term.erase(@buckets_cache) end)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "repair-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    %{n: n, tmp: tmp, user: user}
  end

  defp bucket!(tmp, name) do
    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "#{name}-#{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: Path.join(tmp, name),
        enabled: true,
        priority: 0
      })

    bucket
  end

  defp upload!(tmp, user) do
    path = Path.join(tmp, "photo-#{System.unique_integer([:positive])}.jpg")

    {_, 0} =
      System.cmd("convert", ["-size", "1200x800", "plasma:fractal", path], stderr_to_stdout: true)

    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    file =
      case Storage.store_file_in_buckets(path, "image", user.uuid, sha, "jpg", "photo.jpg") do
        {:ok, file} -> file
        {:ok, file, _} -> file
      end

    :ok =
      ProcessFileJob.perform(%Oban.Job{
        args: %{"file_uuid" => file.uuid, "filename" => "photo.jpg"}
      })

    Storage.get_file(file.uuid)
  end

  defp object(bucket, file, name) do
    instance = Storage.get_file_instance_by_name(file.uuid, name)
    Path.join(Local.root(bucket), instance.file_name)
  end

  defp kinds(actions), do: for(%{name: n, kind: k} <- actions, k != :reconciled, do: {n, k})

  test "one bucket: a deleted size and a tampered size are made again", ctx do
    bucket = bucket!(ctx.tmp, "solo")
    file = upload!(ctx.tmp, ctx.user)
    assert FileReport.all_ok?(FileReport.verify(file))

    File.rm!(object(bucket, file, "medium"))
    File.write!(object(bucket, file, "large"), "tampered")
    refute FileReport.all_ok?(FileReport.verify(file))

    assert {:ok, %{actions: actions, verification: verification}} = FileRepair.repair(file)

    assert {"medium", :regenerated} in kinds(actions)
    assert {"large", :regenerated} in kinds(actions)
    assert FileReport.all_ok?(verification)
    assert FileReport.all_ok?(FileReport.verify(Storage.get_file(file.uuid)))
  end

  test "one bucket: a damaged original has no copy to go back to, and nothing is made from it",
       ctx do
    bucket = bucket!(ctx.tmp, "solo")
    file = upload!(ctx.tmp, ctx.user)

    File.write!(object(bucket, file, "original"), "tampered")

    assert {:ok, %{actions: actions, verification: verification}} = FileRepair.repair(file)

    assert {"original", :unrecoverable} in kinds(actions)
    refute Enum.any?(actions, &(&1.kind == :reconciled))
    refute FileReport.all_ok?(verification)
  end

  test "an original is copied back from a bucket nothing recorded as holding it", ctx do
    a = bucket!(ctx.tmp, "a")
    b = bucket!(ctx.tmp, "b")
    file = upload!(ctx.tmp, ctx.user)

    # One copy, in whichever bucket the upload chose; the same bytes put into the
    # other by hand, with no location row.
    {holder, other} = if File.exists?(object(a, file, "original")), do: {a, b}, else: {b, a}
    source = object(holder, file, "original")
    target = object(other, file, "original")
    File.mkdir_p!(Path.dirname(target))
    File.cp!(source, target)
    File.write!(source, "tampered")

    assert {:ok, %{actions: actions, verification: verification}} = FileRepair.repair(file)

    assert {"original", :restored} in kinds(actions)
    refute Enum.any?(actions, &(&1.kind == :unrecoverable))
    assert File.read!(source) == File.read!(target)
    assert FileReport.all_ok?(verification)
  end

  describe "the trail" do
    import Ecto.Query

    alias PhoenixKit.Activity.Entry
    alias PhoenixKit.Modules.Storage.Audit

    defp entries(action), do: Repo.all(from(e in Entry, where: e.action == ^action))

    test "a repair records each damaged copy against its bucket, and what it did", ctx do
      bucket = bucket!(ctx.tmp, "solo")
      file = upload!(ctx.tmp, ctx.user)

      File.rm!(object(bucket, file, "medium"))
      File.write!(object(bucket, file, "large"), "tampered")

      assert {:ok, _} = FileRepair.repair(file, actor_uuid: ctx.user.uuid)

      damaged = entries("storage.copy.damaged")
      assert length(damaged) == 2
      assert Enum.all?(damaged, &(&1.resource_uuid == to_string(bucket.uuid)))
      assert Enum.all?(damaged, &(&1.actor_uuid == ctx.user.uuid))

      assert %{"medium" => "missing", "large" => "checksum_mismatch"} ==
               Map.new(damaged, &{&1.metadata["rendition"], &1.metadata["problem"]})

      assert Enum.all?(damaged, &(&1.metadata["found_by"] == "repair"))

      assert [repaired] = entries("storage.file.repaired")
      assert repaired.resource_uuid == file.uuid
      assert repaired.metadata["problems_left"] == 0

      assert Enum.sort(Enum.map(repaired.metadata["actions"], & &1["rendition"])) ==
               ["large", "medium"]

      assert %{count: 2, last_at: %DateTime{}} = Audit.damaged_copies(bucket.uuid, 30)
    end

    test "verifying records damage too, but not a healthy file", ctx do
      bucket = bucket!(ctx.tmp, "solo")
      file = upload!(ctx.tmp, ctx.user)

      FileReport.verify(file, audit: [actor_uuid: ctx.user.uuid, found_by: "verify"])
      assert entries("storage.copy.damaged") == []
      assert %{count: 0} = Audit.damaged_copies(bucket.uuid, 30)

      File.rm!(object(bucket, file, "small"))
      FileReport.verify(file, audit: [actor_uuid: ctx.user.uuid, found_by: "verify"])

      assert [entry] = entries("storage.copy.damaged")
      assert entry.metadata["found_by"] == "verify"
      assert entry.metadata["rendition"] == "small"
    end

    test "nothing is written for a repair that had nothing to do", ctx do
      bucket!(ctx.tmp, "solo")
      file = upload!(ctx.tmp, ctx.user)

      assert {:ok, %{actions: actions}} = FileRepair.repair(file, actor_uuid: ctx.user.uuid)
      assert Enum.all?(actions, &(&1.kind == :reconciled))
      assert entries("storage.file.repaired") == []
      assert entries("storage.copy.damaged") == []
    end
  end

  test "a copy that cannot be put right is reported, and the reconciler is not run after it",
       ctx do
    a = bucket!(ctx.tmp, "a")
    b = bucket!(ctx.tmp, "b")

    {:ok, _} = Profiles.update_profile(Profiles.default_profile(), %{copies_local: 2})
    file = upload!(ctx.tmp, ctx.user)

    target = object(a, file, "medium")
    File.write!(target, "tampered")
    # Nothing can be written back into the bucket: the restore fails.
    File.chmod!(target, 0o444)
    File.chmod!(Path.dirname(target), 0o555)
    on_exit(fn -> File.chmod(Path.dirname(target), 0o755) end)

    assert File.exists?(object(b, file, "medium"))
    assert {:ok, %{actions: actions, verification: verification}} = FileRepair.repair(file)

    assert {"medium", :failed} in kinds(actions)
    refute Enum.any?(actions, &(&1.kind == :reconciled))
    refute FileReport.all_ok?(verification)
  end

  test "two buckets: a good copy is copied over a bad one, original included", ctx do
    a = bucket!(ctx.tmp, "a")
    b = bucket!(ctx.tmp, "b")

    {:ok, _} = Profiles.update_profile(Profiles.default_profile(), %{copies_local: 2})
    file = upload!(ctx.tmp, ctx.user)
    assert FileReport.all_ok?(FileReport.verify(file))
    assert length(FileReport.verify(file)) > 2

    File.write!(object(a, file, "original"), "tampered")
    File.rm!(object(b, file, "medium"))

    assert {:ok, %{actions: actions, verification: verification}} = FileRepair.repair(file)

    assert {"original", :restored} in kinds(actions)
    assert {"medium", :restored} in kinds(actions)
    refute Enum.any?(actions, &(&1.kind in [:regenerated, :unrecoverable]))
    assert FileReport.all_ok?(verification)
  end
end
