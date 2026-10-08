defmodule PhoenixKit.Modules.Storage.PlacementTest do
  @moduledoc """
  Placement by storage profile (V205, step 2), against real local buckets:
  an upload is written where its library's profile says (roles, what each
  bucket stores, status, capacity, copy counts), a file records what placed
  it, too few copies of an original fail the upload, variants and tiles
  follow the profile as derived objects, a cross-user copy only reuses a
  donor placed the same way, and the redundancy setting is the Default
  profile's copy count.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Bucket, Libraries, Locations, Manager, Profiles, VariantSets}
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  setup do
    n = System.unique_integer([:positive])
    roots = for side <- ~w(a b c), do: Path.join(System.tmp_dir!(), "pk_placement_#{n}_#{side}")

    [a, b, c] =
      for root <- roots do
        {:ok, bucket} =
          Storage.create_bucket(%{
            name: "placement-#{Path.basename(root)}",
            provider: "local",
            endpoint: root,
            enabled: true,
            priority: 0
          })

        bucket
      end

    on_exit(fn -> Enum.each(roots, &File.rm_rf/1) end)

    {:ok, library} = Libraries.create_system_library(%{name: "Placement #{n}"})
    {:ok, profile} = Profiles.create_profile(%{name: "Placement #{n}"})
    {:ok, library} = Profiles.set_library_profile(library, profile.uuid)

    %{a: a, b: b, c: c, library: library, profile: profile, user: user!()}
  end

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "placement-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  # The emergency stop, set on the table: `Storage.update_bucket/3` refuses to
  # disable a bucket a storage profile lists, and these tests keep it listed.
  defp disable!(bucket) do
    {1, _} =
      Repo.update_all(from(b in Bucket, where: b.uuid == ^bucket.uuid), set: [enabled: false])

    Manager.invalidate_bucket_cache()
  end

  defp put!(profile, bucket, attrs \\ %{}) do
    {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, attrs)
    Profiles.get_profile(profile.uuid)
  end

  defp source!(content) do
    path = Path.join(System.tmp_dir!(), "pk_placement_src_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp upload(user, library, content) do
    path = source!(content)
    sha = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    Storage.store_file_in_buckets(path, "document", user.uuid, sha, "txt", "a.txt",
      library_uuid: library && library.uuid
    )
  end

  # Uploads stay "processing" until their job runs (no Oban here); only an
  # active file is a cross-user donor.
  defp activate!(file) do
    {:ok, file} = Storage.update_file(file, %{status: "active"})
    file
  end

  # A local bucket whose root is a regular file: every write to it fails.
  defp broken_bucket! do
    root =
      Path.join(System.tmp_dir!(), "pk_placement_broken_#{System.unique_integer([:positive])}")

    File.write!(root, "not a directory")
    on_exit(fn -> File.rm(root) end)

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "placement-broken-#{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    bucket
  end

  # A cloud bucket nothing can be written to: no connection, no keys. Inserted
  # as a row, because the form's rules want a real connection.
  defp cloud_bucket! do
    Repo.insert!(%Bucket{
      name: "placement-cloud-#{System.unique_integer([:positive])}",
      provider: "r2",
      bucket_name: "nowhere",
      endpoint: "127.0.0.1:9",
      access_type: "signed",
      enabled: true,
      priority: 0
    })
  end

  defp stored_files(bucket) do
    Path.join(bucket.endpoint, "**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1)
  end

  defp original_buckets(file) do
    instance = Storage.get_file_instance_by_name(file.uuid, "original")
    instance.file_name |> Locations.bucket_uuids() |> MapSet.new()
  end

  defp placed(file) do
    file = Storage.get_file(file.uuid)
    {file.placed_profile_uuid && to_string(file.placed_profile_uuid), file.placed_revision}
  end

  defp uuids(buckets), do: MapSet.new(buckets, &to_string(&1.uuid))

  describe "originals" do
    test "go to the profile's buckets only, up to its copy count", ctx do
      profile = put!(ctx.profile, ctx.a)
      profile = put!(profile, ctx.b)
      {:ok, profile} = Profiles.update_profile(profile, %{copies_local: 2})

      {:ok, file} = upload(ctx.user, ctx.library, "two copies")

      assert original_buckets(file) == uuids([ctx.a, ctx.b])
      assert placed(file) == {to_string(profile.uuid), profile.revision}
    end

    test "primaries come before backups whatever their write priority", ctx do
      profile = put!(ctx.profile, ctx.a, %{role: "backup", write_priority: 1})
      _profile = put!(profile, ctx.b, %{role: "primary"})

      {:ok, file} = upload(ctx.user, ctx.library, "primary first")

      assert original_buckets(file) == uuids([ctx.b])
    end

    test "a fixed write priority comes before the shuffled pool", ctx do
      profile = put!(ctx.profile, ctx.a)
      profile = put!(profile, ctx.b, %{write_priority: 5})
      _profile = put!(profile, ctx.c, %{write_priority: 1})

      for i <- 1..5 do
        {:ok, file} = upload(ctx.user, ctx.library, "priority #{i}")
        assert original_buckets(file) == uuids([ctx.c])
      end
    end

    test "a bucket that is not active, or is disabled, is skipped", ctx do
      profile = put!(ctx.profile, ctx.a, %{status: "draining"})
      profile = put!(profile, ctx.b, %{status: "read_only"})
      profile = put!(profile, ctx.c)
      {:ok, profile} = Profiles.update_profile(profile, %{copies_local: 3})

      {:ok, file} = upload(ctx.user, ctx.library, "only c")
      assert original_buckets(file) == uuids([ctx.c])

      # One copy is all the profile can make now, so the file is placed;
      # making a bucket active again bumps the revision and makes it stale.
      assert placed(file) == {to_string(profile.uuid), profile.revision}

      disable!(ctx.c)
      assert {:error, _} = upload(ctx.user, ctx.library, "nowhere")
    end

    test "a bucket at its capacity is skipped", ctx do
      {:ok, full} = Storage.update_bucket(ctx.a, %{max_size_mb: 1})
      profile = put!(ctx.profile, full, %{write_priority: 1})
      _profile = put!(profile, ctx.b)

      # 2 MB already on bucket a.
      {:ok, existing} = upload(ctx.user, ctx.library, "existing")
      instance = Storage.get_file_instance_by_name(existing.uuid, "original")
      {:ok, _} = Storage.update_file_instance(instance, %{size: 2_000_000})
      Locations.record(instance.file_name, full.uuid)
      :persistent_term.erase({:phoenix_kit_bucket_usage, to_string(full.uuid)})

      {:ok, file} = upload(ctx.user, ctx.library, "not on a")
      assert original_buckets(file) == uuids([ctx.b])
    end

    test "fewer copies than the profile requires fail the upload and leave nothing", ctx do
      profile = put!(ctx.profile, ctx.a)
      profile = put!(profile, ctx.b, %{status: "draining"})

      {:ok, _} =
        Profiles.update_profile(profile, %{copies_local: 2, min_copies_on_write: 2})

      assert {:error, _} = upload(ctx.user, ctx.library, "needs two")
      assert stored_files(ctx.a) == []
    end

    test "a copy that fails leaves the file stale for the reconciler", ctx do
      profile = put!(ctx.profile, ctx.a)
      profile = put!(profile, broken_bucket!())
      {:ok, profile} = Profiles.update_profile(profile, %{copies_local: 2})

      {:ok, file} = upload(ctx.user, ctx.library, "one of two")

      assert original_buckets(file) == uuids([ctx.a])
      assert placed(file) == {to_string(profile.uuid), 0}
    end

    test "a failed copy below the minimum fails the upload and removes the good one", ctx do
      profile = put!(ctx.profile, ctx.a)
      profile = put!(profile, broken_bucket!())

      {:ok, _} =
        Profiles.update_profile(profile, %{copies_local: 2, min_copies_on_write: 2})

      assert {:error, _} = upload(ctx.user, ctx.library, "both or nothing")
      assert stored_files(ctx.a) == []
    end

    test "Media uses the Default profile", ctx do
      {:ok, _} = Storage.set_redundancy_copies(1)
      {:ok, file} = upload(ctx.user, nil, "media")

      default = Profiles.default_profile()
      assert placed(file) == {Profiles.default_uuid(), default.revision}
      assert MapSet.size(original_buckets(file)) == 1
    end
  end

  describe "local and cloud copies" do
    test "a kind the profile wants no copy of is not written, whatever buckets it has", ctx do
      profile = put!(ctx.profile, ctx.a)
      profile = put!(profile, cloud_bucket!())

      {:ok, file} = upload(ctx.user, ctx.library, "local only")

      assert original_buckets(file) == uuids([ctx.a])
      # Nothing was wanted from the cloud bucket, so the file is placed whole.
      assert placed(file) == {to_string(profile.uuid), profile.revision}
    end

    test "the local count is per kind: two copies on local buckets, none in the cloud", ctx do
      profile = put!(ctx.profile, ctx.a)
      profile = put!(profile, ctx.b)
      profile = put!(profile, ctx.c)
      _ = put!(profile, cloud_bucket!())
      {:ok, _} = Profiles.update_profile(Profiles.get_profile(profile.uuid), %{copies_local: 2})

      {:ok, file} = upload(ctx.user, ctx.library, "two local")

      assert MapSet.size(original_buckets(file)) == 2
      assert MapSet.subset?(original_buckets(file), uuids([ctx.a, ctx.b, ctx.c]))
    end

    test "a cloud copy that cannot be written leaves the local one, and the file stale", ctx do
      profile = put!(ctx.profile, ctx.a)
      profile = put!(profile, cloud_bucket!())
      {:ok, profile} = Profiles.update_profile(profile, %{copies_local: 1, copies_cloud: 1})

      {:ok, file} = upload(ctx.user, ctx.library, "cloud is down")

      assert original_buckets(file) == uuids([ctx.a])
      assert placed(file) == {to_string(profile.uuid), 0}
    end

    test "the plan lists each kind's buckets with the copies wanted there", ctx do
      profile = put!(ctx.profile, ctx.a)
      profile = put!(profile, ctx.b, %{role: "replica"})
      cloud = cloud_bucket!()
      profile = put!(profile, cloud)
      {:ok, profile} = Profiles.update_profile(profile, %{copies_local: 2, copies_cloud: 1})

      assert [{:local, local, 2}, {:cloud, [only_cloud], 1}] = Manager.placement_plan(profile)
      # A primary before a replica.
      assert Enum.map(local, & &1.uuid) == [ctx.a.uuid, ctx.b.uuid]
      assert only_cloud.uuid == cloud.uuid
    end
  end

  describe "derived files" do
    test "a variant is placed like its original: on the same buckets", ctx do
      profile = put!(ctx.profile, ctx.a)
      profile = put!(profile, ctx.b)
      {:ok, _} = Profiles.update_profile(profile, %{copies_local: 2})

      {:ok, file} = upload(ctx.user, ctx.library, "variant")
      assert original_buckets(file) == uuids([ctx.a, ctx.b])

      variant = source!("variant bytes")
      key = "#{file.file_path}/variant_small.txt"

      assert {:ok, info} =
               Storage.store_by_profile(variant, file.library_uuid, :derived, path_prefix: key)

      assert MapSet.new(info.bucket_ids, &to_string/1) == uuids([ctx.a, ctx.b])
      assert info.complete?
    end

    test "a tile follows its parent's library", ctx do
      _profile = put!(ctx.profile, ctx.c)
      {:ok, parent} = upload(ctx.user, ctx.library, "parent")

      tile = source!("tile bytes")
      key = "#{parent.file_path}/_tiles/0_0_0.jpg"

      {:ok, %{file: tile_file}} =
        Storage.store_system_file(tile, key,
          parent_file_uuid: parent.uuid,
          mime_type: "image/jpeg"
        )

      assert tile_file.library_uuid == ctx.library.uuid
      assert Locations.bucket_uuids(key) == [to_string(ctx.c.uuid)]
      assert placed(tile_file) == {to_string(ctx.profile.uuid), revision(ctx.profile)}
    end

    test "a derived copy that fails is reported incomplete", ctx do
      profile = put!(ctx.profile, ctx.a)
      profile = put!(profile, broken_bucket!())
      {:ok, _} = Profiles.update_profile(profile, %{copies_local: 2})
      {:ok, file} = upload(ctx.user, ctx.library, "short variant")

      {:ok, info} =
        Storage.store_by_profile(source!("v"), file.library_uuid, :derived,
          path_prefix: "#{file.file_path}/v.txt"
        )

      refute info.complete?
      assert info.bucket_ids == [ctx.a.uuid]
    end
  end

  describe "cross-user copies" do
    test "reuse a donor placed by the same profile and set", ctx do
      _profile = put!(ctx.profile, ctx.a)
      {:ok, donor} = upload(ctx.user, ctx.library, "shared bytes")
      activate!(donor)

      assert {:ok, clone, :duplicate} = upload(user!(), ctx.library, "shared bytes")
      assert clone.file_path == donor.file_path
      assert placed(clone) == placed(donor)
    end

    test "never reuse a donor in a library placed differently", ctx do
      _profile = put!(ctx.profile, ctx.a)
      {:ok, donor} = upload(ctx.user, ctx.library, "other profile")
      activate!(donor)

      # Media is on the Default profile, not this library's.
      assert {:ok, fresh} = upload(user!(), nil, "other profile")
      refute fresh.file_path == donor.file_path
    end

    test "never reuse a donor in another library, however alike they are placed", ctx do
      _profile = put!(ctx.profile, ctx.a)
      {:ok, donor} = upload(ctx.user, ctx.library, "other library")
      activate!(donor)

      n = System.unique_integer([:positive])
      {:ok, other} = Libraries.create_system_library(%{name: "Same profile #{n}"})
      {:ok, other} = Profiles.set_library_profile(other, ctx.profile.uuid)

      # Same profile and variant set, another library: stored fresh, not shared.
      assert {:ok, fresh} = upload(user!(), other, "other library")
      refute fresh.file_path == donor.file_path
      assert fresh.library_uuid == other.uuid
    end
  end

  describe "the redundancy setting" do
    test "is the Default profile's copy count in all, local buckets first" do
      {:ok, _} = Storage.set_redundancy_copies(2)

      default = Profiles.default_profile()
      assert Profiles.copies_total(default) == 2
      assert {default.copies_local, default.copies_cloud} == {2, 0}
      assert Storage.redundancy_copies() == 2
      assert Settings.get_setting("storage_redundancy_copies") == "2"
    end

    test "lowering it keeps min copies on write within range" do
      {:ok, _} = Storage.set_redundancy_copies(3)
      {:ok, _} = Profiles.update_profile(Profiles.default_profile(), %{min_copies_on_write: 3})
      {:ok, _} = Storage.set_redundancy_copies(1)

      assert Profiles.default_profile().min_copies_on_write == 1
    end
  end

  describe "the manager's options" do
    test "forced buckets are written exactly, whatever the profile says", ctx do
      {:ok, info} =
        Manager.store_file(source!("forced"),
          path_prefix: "forced/#{System.unique_integer([:positive])}.txt",
          force_bucket_ids: [ctx.b.uuid]
        )

      assert info.bucket_ids == [ctx.b.uuid]
    end
  end

  defp revision(profile), do: Profiles.get_profile(profile.uuid).revision
end
