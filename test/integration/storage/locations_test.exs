defmodule PhoenixKit.Modules.Storage.LocationsTest do
  @moduledoc """
  Location-truth (V204), against the database and two real local buckets:
  reads go to the buckets a key's location rows name, a bucket found to hold
  a key without a row gets one, writers record where they stored, a forced
  set of buckets is written exactly, a bucket with files cannot be deleted,
  and bucket changes apply at once.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{FileLocation, Locations, Manager, ProfileBucket}
  alias PhoenixKit.Modules.Storage.Workers.LocationBackfillJob
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  @cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@cache)
    n = System.unique_integer([:positive])
    roots = for side <- ~w(a b), do: Path.join(System.tmp_dir!(), "pk_locations_#{n}_#{side}")

    [a, b] =
      for root <- roots do
        {:ok, bucket} =
          Storage.create_bucket(%{
            name: "locations-#{Path.basename(root)}",
            provider: "local",
            endpoint: root,
            enabled: true,
            priority: 0
          })

        bucket
      end

    on_exit(fn ->
      :persistent_term.erase(@cache)
      Enum.each(roots, &File.rm_rf/1)
    end)

    %{a: a, b: b}
  end

  # Out of every storage profile, the way an admin frees a bucket: a bucket a
  # profile lists is neither deleted nor disabled.
  defp free!(bucket),
    do: Repo.delete_all(from(r in ProfileBucket, where: r.bucket_uuid == ^bucket.uuid))

  defp source!(content) do
    path = Path.join(System.tmp_dir!(), "pk_locations_src_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # A file row with one instance at `key`, and no location rows.
  defp instance!(key) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "locations-#{System.unique_integer([:positive])}@example.com",
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

  defp key, do: "locations/#{System.unique_integer([:positive])}/a_original.txt"

  defp locations(instance),
    do: Repo.all(from(l in FileLocation, where: l.file_instance_uuid == ^instance.uuid))

  test "a key with no rows is found by probing, and the bucket that has it is recorded", ctx do
    key = key()
    instance = instance!(key)

    {:ok, _} =
      Manager.store_file(source!("probe"), path_prefix: key, force_bucket_ids: [ctx.b.uuid])

    assert Locations.bucket_uuids(key) == []
    assert Manager.file_exists?(key)

    assert [%{bucket_uuid: b_uuid, path: ^key, status: "active"}] = locations(instance)
    assert to_string(b_uuid) == to_string(ctx.b.uuid)
    assert Locations.bucket_uuids(key) == [to_string(ctx.b.uuid)]

    # Found again the same way, no second row.
    assert {:ok, path} = Manager.retrieve_file(key)
    assert File.read!(path) == "probe"
    assert length(locations(instance)) == 1
  end

  test "the rows' buckets are read first", ctx do
    key = key()
    _instance = instance!(key)

    {:ok, _} =
      Manager.store_file(source!("in b"), path_prefix: key, force_bucket_ids: [ctx.b.uuid])

    Locations.record(key, ctx.b.uuid)

    b_uuid = to_string(ctx.b.uuid)
    assert [%{bucket_uuid: ^b_uuid, role: "primary"}] = Locations.ranked(key)
    assert {:local, path} = Manager.get_file_access(key)
    assert String.starts_with?(path, ctx.b.endpoint)
  end

  test "a forced set of buckets is written exactly, whatever the redundancy", ctx do
    {:ok, info} =
      Manager.store_file(source!("both"),
        path_prefix: key(),
        redundancy_copies: 1,
        force_bucket_ids: [ctx.b.uuid, ctx.a.uuid]
      )

    assert info.bucket_ids == [ctx.b.uuid, ctx.a.uuid]
  end

  test "a system file (a tile) records where it was stored" do
    parent = instance!(key())
    tile_key = "tiles/#{System.unique_integer([:positive])}/0/0_0.jpg"

    {:ok, %{instance: tile_instance}} =
      Storage.store_system_file(source!("tile"), tile_key,
        parent_file_uuid: parent.file_uuid,
        mime_type: "image/jpeg"
      )

    stored_in =
      tile_instance |> locations() |> Enum.map(&to_string(&1.bucket_uuid)) |> Enum.sort()

    # Where it went depends on every enabled bucket (the shared test database
    # has others), so the check is that the rows say what the write did.
    assert stored_in != []
    assert Enum.sort(Locations.bucket_uuids(tile_key)) == stored_in
    assert Manager.file_exists?(tile_key)
  end

  test "record/2 adds a row per instance of the key, once", ctx do
    key = key()
    instance = instance!(key)

    assert Locations.record(key, ctx.a.uuid) == 1
    assert Locations.record(key, ctx.a.uuid) == 0
    assert Locations.record_all(key, [ctx.a.uuid, ctx.b.uuid]) == 1
    assert length(locations(instance)) == 2
    assert Locations.record("no/such/key", ctx.a.uuid) == 0
  end

  test "a read that records one bucket does not retire the instance from the backfill", ctx do
    key = key()
    instance = instance!(key)

    {:ok, _} =
      Manager.store_file(source!("two copies"),
        path_prefix: key,
        force_bucket_ids: [ctx.a.uuid, ctx.b.uuid]
      )

    # The read stops at the first bucket that has it and records that one.
    assert Manager.file_exists?(key)
    assert length(locations(instance)) == 1

    # Still unchecked, so the backfill visits it and records the other copy.
    assert Repo.exists?(from(i in Locations.unchecked_query(), where: i.uuid == ^instance.uuid))
    LocationBackfillJob.run_pass()

    recorded = instance |> locations() |> Enum.map(&to_string(&1.bucket_uuid)) |> Enum.sort()
    assert recorded == Enum.sort([to_string(ctx.a.uuid), to_string(ctx.b.uuid)])
    refute Repo.exists?(from(i in Locations.unchecked_query(), where: i.uuid == ^instance.uuid))
  end

  test "a miss is remembered: checked and found nowhere, a read stops asking", _ctx do
    key = key()
    instance = instance!(key)
    refute Locations.known_missing?(key)

    LocationBackfillJob.run_pass()

    assert Locations.known_missing?(key)
    refute Repo.exists?(from(i in Locations.unchecked_query(), where: i.uuid == ^instance.uuid))
    refute Manager.file_exists?(key)
  end

  test "list_files(bucket_uuid:) lists the files with a copy in that bucket", ctx do
    key = key()
    instance = instance!(key)
    Locations.record(key, ctx.a.uuid)

    in_a = Storage.list_files(bucket_uuid: ctx.a.uuid) |> Enum.map(& &1.uuid)
    in_b = Storage.list_files(bucket_uuid: ctx.b.uuid) |> Enum.map(& &1.uuid)

    assert instance.file_uuid in in_a
    refute instance.file_uuid in in_b
  end

  test "missing_count/0 counts instances not checked yet" do
    before = Locations.missing_count()
    key = key()
    instance!(key)
    assert Locations.missing_count() == before + 1
  end

  test "a bucket that still holds files is not deleted", ctx do
    key = key()
    instance!(key)
    Locations.record(key, ctx.a.uuid)
    free!(ctx.a)
    free!(ctx.b)

    assert {:error, changeset} = Storage.delete_bucket(ctx.a)
    assert changeset.errors[:file_locations]
    assert Storage.get_bucket(ctx.a.uuid)

    assert {:ok, _} = Storage.delete_bucket(ctx.b)
  end

  test "a bucket change applies at once, not after the cache expires", ctx do
    assert Manager.file_exists?("warm/the/cache") == false
    assert :persistent_term.get(@cache, nil)

    free!(ctx.a)

    {:ok, _} = Storage.update_bucket(ctx.a, %{enabled: false})
    assert :persistent_term.get(@cache, nil) == nil
  end
end
