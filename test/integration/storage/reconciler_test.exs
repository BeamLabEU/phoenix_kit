defmodule PhoenixKit.Modules.Storage.ReconcilerTest do
  @moduledoc """
  The reconciler (V205, step 5), against real local buckets: a file whose
  library moved to another profile, or whose profile changed, is stale; the
  reconciler copies it where the profile wants it (checking each copy),
  unlinks copies the profile no longer uses (a draining bucket, one taken
  out of the profile, one that stores the other kind) and deletes the
  object there only when nothing else on that bucket names the key (G11);
  it makes, remakes and deletes sizes by the variant set; and it stamps a
  file only once it matches.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage

  alias PhoenixKit.Modules.Storage.{
    Bucket,
    FileLocation,
    Libraries,
    LocationCheck,
    Locations,
    ProcessFileJob,
    Profiles,
    Reconciler,
    VariantSets
  }

  alias PhoenixKit.Modules.Storage.Workers.ReconcileJob
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  import Ecto.Query

  setup do
    n = System.unique_integer([:positive])
    roots = for side <- ~w(a b c), do: Path.join(System.tmp_dir!(), "pk_reconcile_#{n}_#{side}")

    [a, b, c] =
      for root <- roots do
        {:ok, bucket} =
          Storage.create_bucket(%{
            name: "reconcile-#{Path.basename(root)}",
            provider: "local",
            endpoint: root,
            enabled: true,
            priority: 0
          })

        bucket
      end

    on_exit(fn -> Enum.each(roots, &File.rm_rf/1) end)

    {:ok, library} = Libraries.create_system_library(%{name: "Reconcile #{n}"})
    {:ok, profile} = Profiles.create_profile(%{name: "Reconcile #{n}"})
    {:ok, _} = Profiles.put_bucket(profile, a.uuid, %{})
    {:ok, library} = Profiles.set_library_profile(library, profile.uuid)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "reconcile-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    %{a: a, b: b, c: c, library: library, profile: profile, user: user, n: n}
  end

  defp profile(ctx), do: Profiles.get_profile(ctx.profile.uuid)

  defp upload!(ctx, content, library \\ nil, user \\ nil) do
    path = Path.join(System.tmp_dir!(), "pk_reconcile_src_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    sha = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    result =
      Storage.store_file_in_buckets(
        path,
        "document",
        (user || ctx.user).uuid,
        sha,
        "txt",
        "a.txt",
        library_uuid: (library || ctx.library).uuid
      )

    file =
      case result do
        {:ok, file} -> file
        {:ok, file, :duplicate} -> file
      end

    {:ok, file} = Storage.update_file(file, %{status: "active"})
    file
  end

  defp key(file), do: Storage.get_file_instance_by_name(file.uuid, "original").file_name
  defp on(bucket, key), do: File.exists?(Path.join(bucket.endpoint, key))
  defp buckets_of(key), do: key |> Locations.bucket_uuids() |> MapSet.new()
  defp uuids(buckets), do: MapSet.new(buckets, &to_string(&1.uuid))

  defp stale?(file),
    do: Repo.exists?(from(f in Reconciler.stale_query(), where: f.uuid == ^file.uuid))

  describe "staleness" do
    test "a placed file is not stale; a profile change or a move makes it stale", ctx do
      file = upload!(ctx, "fresh")
      refute stale?(file)

      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{})
      assert stale?(file)

      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled
      refute stale?(file)

      {:ok, other} = Profiles.create_profile(%{name: "Other #{ctx.n}"})
      {:ok, _} = Profiles.put_bucket(other, ctx.c.uuid, %{})
      {:ok, _} = Profiles.set_library_profile(ctx.library, other.uuid)
      assert stale?(file)
    end

    test "a file still uploading is left alone", ctx do
      file = upload!(ctx, "uploading")
      {:ok, _} = Storage.update_file(file, %{status: "processing"})
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{})

      refute stale?(file)
    end
  end

  describe "copies" do
    test "a missing copy is made on the profile's buckets, checked and recorded", ctx do
      file = upload!(ctx, "one more copy")
      key = key(file)
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{})
      {:ok, _} = Profiles.update_profile(profile(ctx), %{copies_local: 2})

      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled

      assert buckets_of(key) == uuids([ctx.a, ctx.b])
      assert on(ctx.b, key)
      file = Storage.get_file(file.uuid)

      assert {file.placed_profile_uuid, file.placed_revision} ==
               {ctx.profile.uuid, profile(ctx).revision}
    end

    test "a draining bucket is emptied once the copy is elsewhere", ctx do
      file = upload!(ctx, "drain me")
      key = key(file)
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{})
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.a.uuid, %{status: "draining"})

      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled

      assert buckets_of(key) == uuids([ctx.b])
      assert on(ctx.b, key)
      refute on(ctx.a, key)
    end

    test "a copy on a bucket taken out of the profile moves to one in it", ctx do
      file = upload!(ctx, "moved out")
      key = key(file)
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.c.uuid, %{})
      :ok = Profiles.remove_bucket(profile(ctx), ctx.a.uuid)

      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled
      assert buckets_of(key) == uuids([ctx.c])
      refute on(ctx.a, key)
    end

    test "a read-only bucket's copy still counts, and gets no new ones", ctx do
      file = upload!(ctx, "read only")
      key = key(file)
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.a.uuid, %{status: "read_only"})
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{})
      {:ok, _} = Profiles.update_profile(profile(ctx), %{copies_local: 2})

      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled
      assert buckets_of(key) == uuids([ctx.a, ctx.b])
    end

    test "a bucket is held to the count of its own kind: no cloud copies wanted, none made",
         ctx do
      file = upload!(ctx, "local is enough")
      key = key(file)

      cloud =
        Repo.insert!(%Bucket{
          name: "recon-cloud-#{System.unique_integer([:positive])}",
          provider: "r2",
          bucket_name: "nowhere",
          endpoint: "127.0.0.1:9",
          access_type: "signed",
          enabled: true,
          priority: 0
        })

      {:ok, _} = Profiles.put_bucket(profile(ctx), cloud.uuid, %{})

      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled
      assert buckets_of(key) == uuids([ctx.a])
    end

    test "with nowhere to copy to, nothing is unlinked and the file stays stale", ctx do
      file = upload!(ctx, "nowhere")
      key = key(file)
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.a.uuid, %{status: "draining"})

      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :stale
      assert buckets_of(key) == uuids([ctx.a])
      assert on(ctx.a, key)

      # Tried and left: it waits before the next try, then is stale again.
      assert Storage.get_file(file.uuid).reconcile_attempted_at
      refute stale?(file)
      back_off!(file, 3600)
      assert stale?(file)
    end

    test "an instance the location backfill has not checked is left alone", ctx do
      file = upload!(ctx, "unchecked")
      instance = Storage.get_file_instance_by_name(file.uuid, "original")
      Repo.delete_all(from(c in LocationCheck, where: c.file_instance_uuid == ^instance.uuid))
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.a.uuid, %{status: "draining"})
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{})

      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :stale
      assert on(ctx.a, key(file))
    end
  end

  describe "a key shared by two files (G11)" do
    test "leaves a bucket only when neither needs it there", ctx do
      donor = upload!(ctx, "shared")
      clone = upload!(ctx, "shared", nil, user!(ctx))
      key = key(donor)
      assert key(clone) == key

      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{})
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.a.uuid, %{status: "draining"})

      assert Reconciler.reconcile_file(Storage.get_file(donor.uuid)) == :reconciled
      # The clone's row still names the key on a: the object stays.
      assert on(ctx.a, key)

      assert Reconciler.reconcile_file(Storage.get_file(clone.uuid)) == :reconciled
      refute on(ctx.a, key)
      assert on(ctx.b, key)

      refute Repo.exists?(
               from(l in FileLocation, where: l.path == ^key and l.bucket_uuid == ^ctx.a.uuid)
             )
    end
  end

  describe "variants" do
    setup ctx do
      {:ok, set} = VariantSets.create_variant_set(%{name: "Reconcile #{ctx.n}"})
      {:ok, library} = VariantSets.set_library_variant_set(ctx.library, set.uuid)
      dir = Path.join(System.tmp_dir!(), "pk_reconcile_img_#{ctx.n}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      Map.merge(ctx, %{set: set, library: library, dir: dir})
    end

    defp image!(ctx) do
      path = Path.join(ctx.dir, "i#{System.unique_integer([:positive])}.png")

      {_, 0} =
        System.cmd("convert", ["-size", "400x200", "xc:blue", path], stderr_to_stdout: true)

      sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

      {:ok, file} =
        Storage.store_file_in_buckets(path, "image", ctx.user.uuid, sha, "png", "i.png",
          library_uuid: ctx.library.uuid
        )

      :ok =
        ProcessFileJob.perform(%Oban.Job{
          args: %{"file_uuid" => file.uuid, "filename" => "i.png"}
        })

      Storage.get_file(file.uuid)
    end

    defp names(file),
      do: file.uuid |> Storage.list_file_instances() |> MapSet.new(& &1.variant_name)

    test "a new size is made, a changed one remade, a deleted one removed", ctx do
      file = image!(ctx)
      refute stale?(file)

      {:ok, extra} =
        Storage.create_dimension(
          %{name: "extra", width: 40, quality: 80, applies_to: "image", format: "jpg"},
          ctx.set.uuid
        )

      assert stale?(file)
      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled
      assert "extra" in names(file)
      refute stale?(file)

      {:ok, extra} = Storage.update_dimension(extra, %{width: 60})
      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled

      instance = Storage.get_file_instance_by_name(file.uuid, "extra")
      assert instance.spec_hash == VariantSets.spec_hash(extra)
      assert instance.width == 60

      key = instance.file_name
      {:ok, _} = Storage.delete_dimension(extra)
      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled
      refute "extra" in names(file)
      refute on(ctx.a, key)
    end

    test "a disabled size is kept, not made again", ctx do
      file = image!(ctx)
      small = Storage.get_dimension_by_name("small", ctx.set.uuid)
      {:ok, _} = Storage.update_dimension(small, %{enabled: false})

      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled
      assert "small" in names(file)
    end
  end

  test "the job walks every stale file", ctx do
    files = for i <- 1..3, do: upload!(ctx, "walk #{i}")
    {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{})
    {:ok, _} = Profiles.update_profile(profile(ctx), %{copies_local: 2})

    totals = ReconcileJob.run_pass()

    assert totals[:reconciled] >= 3
    for file <- files, do: refute(stale?(file))
  end

  defp back_off!(file, seconds) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(), -seconds) |> NaiveDateTime.truncate(:second)

    Repo.update_all(from(f in Storage.File, where: f.uuid == ^file.uuid),
      set: [reconcile_attempted_at: at]
    )
  end

  defp user!(ctx) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "reconcile-#{ctx.n}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end
end
