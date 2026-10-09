defmodule PhoenixKit.Modules.Storage.FileReportTest do
  @moduledoc """
  What a file's storage page reports: the renditions its variant set wants and
  which are stored, and a verification that reads each copy back from its own
  bucket and compares it with the checksum recorded for it.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.FileReport
  alias PhoenixKit.Modules.Storage.Providers.Local
  alias PhoenixKit.Users.Auth

  @moduletag :tmp_dir
  @buckets_cache :phoenix_kit_buckets_cache

  setup %{tmp_dir: tmp} do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])

    # Only this test's bucket: the seeded default one outlasts the test.
    Repo.update_all(Bucket, set: [enabled: false])

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "report-#{n}",
        provider: "local",
        endpoint: Path.join(tmp, "bucket"),
        enabled: true,
        priority: 0
      })

    on_exit(fn -> :persistent_term.erase(@buckets_cache) end)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "report-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    path = Path.join(tmp, "photo.jpg")
    File.write!(path, "not really a jpeg, but bytes #{n}")
    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    file =
      case Storage.store_file_in_buckets(path, "image", user.uuid, sha, "jpg", "photo.jpg") do
        {:ok, file} -> file
        {:ok, file, _} -> file
      end

    %{bucket: bucket, photo: file, sha: sha}
  end

  defp original(file), do: Storage.get_file_instance_by_name(file.uuid, "original")

  test "a profile's layout decides how many hash folders the file's folder has", ctx do
    %{tmp_dir: tmp, sha: _} = ctx
    alias PhoenixKit.Modules.Storage.Profiles
    {:ok, _} = Profiles.update_profile(Profiles.default_profile(), %{key_levels: 2})

    path = Path.join(tmp, "deeper.jpg")
    File.write!(path, "other bytes #{System.unique_integer([:positive])}")
    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
    user_uuid = ctx.photo.user_uuid

    file =
      case Storage.store_file_in_buckets(path, "image", user_uuid, sha, "jpg", "deeper.jpg") do
        {:ok, file} -> file
        {:ok, file, _} -> file
      end

    # <prefix>/<2>/<2>/<md5>
    assert [_prefix, a, b, md5] = String.split(file.file_path, "/")
    assert String.slice(md5, 0, 2) == a
    assert String.slice(md5, 2, 2) == b
  end

  test "the original is listed first, with its copy and its checksum", %{photo: file, sha: sha} do
    [first | _] = FileReport.renditions(file)

    assert first.name == "original"
    assert first.kind == :original
    assert first.state == :ok
    assert first.instance.checksum == sha
    assert [%{status: "active"}] = first.copies
  end

  test "an expected size the file lacks is missing, and is a problem", %{photo: file} do
    rows = FileReport.renditions(file)
    missing = Enum.filter(rows, &(&1.state == :missing))

    # The Default set's sizes for an image; none was made for this file.
    assert Enum.any?(missing, &(&1.name == "thumbnail"))
    assert Enum.all?(missing, &(&1.kind in [:size, :alternative]))
    assert Enum.all?(FileReport.problems(rows), &(&1.state == :missing))
  end

  test "an instance no bucket is recorded to hold is reported as having no copy", %{photo: file} do
    Repo.delete_all(PhoenixKit.Modules.Storage.FileLocation)

    assert %{state: :no_copy} = file |> FileReport.renditions() |> hd()
    assert [%{name: "original", bucket: nil, result: :no_copy}] = FileReport.verify(file)
  end

  test "verify reads the copy back and finds it intact", %{photo: file, bucket: bucket} do
    assert [%{name: "original", result: :ok, bucket: %{uuid: uuid}}] = FileReport.verify(file)
    assert uuid == bucket.uuid
    assert FileReport.all_ok?(FileReport.verify(file))
  end

  test "verify finds a copy whose bytes changed, and one that went missing", ctx do
    %{photo: file, bucket: bucket} = ctx
    key = original(file).file_name

    File.write!(Path.join(Local.root(bucket), key), "tampered")
    assert [%{result: {:mismatch, recorded, actual}}] = FileReport.verify(file)
    assert recorded == ctx.sha
    refute actual == recorded
    refute FileReport.all_ok?(FileReport.verify(file))

    File.rm!(Path.join(Local.root(bucket), key))
    assert [%{result: :not_found}] = FileReport.verify(file)
  end
end
