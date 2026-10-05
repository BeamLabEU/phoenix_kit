defmodule PhoenixKit.Modules.Storage.V205ReviewTest do
  @moduledoc """
  What the review of V205 found, each as a test against real local buckets:
  the reconciler checks the copies it keeps before it unlinks one, never
  makes over a burned thumbnail, caps its target at buckets it can use,
  remakes a size shared with another file under a key of its own, and backs
  off a file it could not finish; an unlink leaves a key an in-flight upload
  or a moved instance still needs; an upload tries a spare bucket for a
  failed one and never rolls back bytes another file owns; bucket usage
  counts files under a megabyte; a restored file is checked for sizes again;
  and the settings aliases and size rules keep what an admin set.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Storage

  alias PhoenixKit.Modules.Storage.{
    Dimension,
    FileInstance,
    Libraries,
    Locations,
    Manager,
    Profiles,
    Reconciler,
    VariantSets
  }

  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  setup do
    n = System.unique_integer([:positive])
    roots = for side <- ~w(a b c), do: Path.join(System.tmp_dir!(), "pk_review_#{n}_#{side}")

    [a, b, c] =
      for root <- roots do
        {:ok, bucket} =
          Storage.create_bucket(%{
            name: "review-#{Path.basename(root)}",
            provider: "local",
            endpoint: root,
            enabled: true,
            priority: 0
          })

        bucket
      end

    on_exit(fn -> Enum.each(roots, &File.rm_rf/1) end)

    {:ok, library} = Libraries.create_system_library(%{name: "Review #{n}"})
    {:ok, profile} = Profiles.create_profile(%{name: "Review #{n}"})
    {:ok, _} = Profiles.put_bucket(profile, a.uuid, %{})
    {:ok, library} = Profiles.set_library_profile(library, profile.uuid)

    %{a: a, b: b, c: c, library: library, profile: profile, user: user!(), n: n}
  end

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "review-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp profile(ctx), do: Profiles.get_profile(ctx.profile.uuid)

  defp source!(content) do
    path = Path.join(System.tmp_dir!(), "pk_review_src_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp upload!(ctx, content, user \\ nil, library \\ nil) do
    sha = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    {:ok, file} =
      case Storage.store_file_in_buckets(
             source!(content),
             "document",
             (user || ctx.user).uuid,
             sha,
             "txt",
             "a.txt",
             library_uuid: (library || ctx.library).uuid
           ) do
        {:ok, file} -> {:ok, file}
        {:ok, file, _} -> {:ok, file}
      end

    {:ok, file} = Storage.update_file(file, %{status: "active"})
    file
  end

  defp key(file), do: Storage.get_file_instance_by_name(file.uuid, "original").file_name
  defp on(bucket, key), do: File.exists?(Path.join(bucket.endpoint, key))

  defp broken_bucket! do
    root = Path.join(System.tmp_dir!(), "pk_review_broken_#{System.unique_integer([:positive])}")
    File.write!(root, "not a directory")
    on_exit(fn -> File.rm(root) end)

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "review-broken-#{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    bucket
  end

  describe "the reconciler" do
    test "does not unlink a copy while the one it keeps is only a row", ctx do
      file = upload!(ctx, "row without object")
      key = key(file)
      # The profile moves to b, where a row says the object is but it is not.
      Locations.record(key, ctx.b.uuid)
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{})
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.a.uuid, %{status: "draining"})
      refute on(ctx.b, key)

      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :stale
      assert on(ctx.a, key)
    end

    test "a read-only bucket without a copy does not keep the file stale", ctx do
      file = upload!(ctx, "read only spare")
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{status: "read_only"})
      {:ok, _} = Profiles.update_profile(profile(ctx), %{copies_local: 2})

      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled
    end

    test "backs off a file it could not finish", ctx do
      file = upload!(ctx, "back off")
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.a.uuid, %{status: "draining"})

      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :stale
      refute Repo.exists?(from(f in Reconciler.stale_query(), where: f.uuid == ^file.uuid))
    end

    test "places a file stuck in processing", ctx do
      file = upload!(ctx, "stuck")
      hour_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -7200)

      Repo.update_all(from(f in Storage.File, where: f.uuid == ^file.uuid),
        set: [status: "processing", updated_at: hour_ago]
      )

      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{})
      assert Repo.exists?(from(f in Reconciler.stale_query(), where: f.uuid == ^file.uuid))
    end
  end

  describe "sizes" do
    setup ctx do
      {:ok, set} = VariantSets.create_variant_set(%{name: "Review #{ctx.n}"})
      {:ok, library} = VariantSets.set_library_variant_set(ctx.library, set.uuid)
      dir = Path.join(System.tmp_dir!(), "pk_review_img_#{ctx.n}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      Map.merge(ctx, %{set: set, library: library, dir: dir})
    end

    defp image!(ctx) do
      path = Path.join(ctx.dir, "i#{System.unique_integer([:positive])}.png")

      {_, 0} =
        System.cmd("convert", ["-size", "400x200", "xc:green", path], stderr_to_stdout: true)

      File.read!(path)
    end

    defp upload_image!(ctx, bytes, user) do
      path = Path.join(ctx.dir, "u#{System.unique_integer([:positive])}.png")
      File.write!(path, bytes)
      sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

      file =
        case Storage.store_file_in_buckets(path, "image", user.uuid, sha, "png", "i.png",
               library_uuid: ctx.library.uuid
             ) do
          {:ok, file} -> file
          {:ok, file, _} -> file
        end

      :ok =
        Storage.ProcessFileJob.perform(%Oban.Job{
          args: %{"file_uuid" => file.uuid, "filename" => "i.png"}
        })

      {:ok, file} = Storage.update_file(Storage.get_file(file.uuid), %{status: "active"})
      file
    end

    test "a burned thumbnail (no spec hash) is never made over", ctx do
      file = upload_image!(ctx, image!(ctx), ctx.user)
      thumb = Storage.get_file_instance_by_name(file.uuid, "thumbnail")
      {:ok, _} = Storage.update_file_instance(thumb, %{spec_hash: nil, checksum: "burned"})

      # A change that makes every file of the set stale.
      small = Storage.get_dimension_by_name("small", ctx.set.uuid)
      {:ok, _} = Storage.update_dimension(small, %{quality: 70})

      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled
      assert Storage.get_file_instance_by_name(file.uuid, "thumbnail").checksum == "burned"
    end

    test "a size shared with another file is remade under a key of its own", ctx do
      bytes = image!(ctx)
      donor = upload_image!(ctx, bytes, ctx.user)
      clone = upload_image!(ctx, bytes, user!())
      donor_medium = Storage.get_file_instance_by_name(donor.uuid, "medium")

      assert Storage.get_file_instance_by_name(clone.uuid, "medium").file_name ==
               donor_medium.file_name

      # Only the donor's library moves to a set whose medium differs.
      n = System.unique_integer([:positive])
      {:ok, other} = VariantSets.create_variant_set(%{name: "Other #{n}"})
      medium = Storage.get_dimension_by_name("medium", other.uuid)
      {:ok, _} = Storage.update_dimension(medium, %{width: 120})
      {:ok, other_library} = Libraries.create_system_library(%{name: "Other #{n}"})
      {:ok, other_library} = Profiles.set_library_profile(other_library, ctx.profile.uuid)
      {:ok, _} = VariantSets.set_library_variant_set(other_library, other.uuid)

      {:ok, _} =
        Storage.update_file(Storage.get_file(donor.uuid), %{library_uuid: other_library.uuid})

      assert Reconciler.reconcile_file(Storage.get_file(donor.uuid)) == :reconciled

      remade = Storage.get_file_instance_by_name(donor.uuid, "medium")
      refute remade.file_name == donor_medium.file_name
      # The clone still serves its own bytes at the old key.
      assert on(ctx.a, donor_medium.file_name)
    end

    test "a restored file is checked for sizes again", ctx do
      file = upload_image!(ctx, image!(ctx), ctx.user)
      {:ok, trashed} = Storage.trash_file(file)
      {:ok, _} = Storage.restore_file(trashed)

      assert Storage.get_file(file.uuid).placed_variant_revision == 0
    end
  end

  describe "unlinking" do
    test "keeps a key an upload into its directory is still writing", ctx do
      file = upload!(ctx, "in flight")
      key = key(file)
      instance = Storage.get_file_instance_by_name(file.uuid, "original")

      # Another upload of the same bytes has its row, not yet its instance.
      {:ok, _} =
        Storage.create_file(%{
          original_file_name: "b.txt",
          file_name: file.file_name,
          file_path: file.file_path,
          mime_type: "text/plain",
          file_type: "document",
          ext: "txt",
          file_checksum: Ecto.UUID.generate(),
          user_file_checksum: Ecto.UUID.generate(),
          size: 1,
          status: "processing",
          user_uuid: user!().uuid
        })

      assert {:ok, :kept} = Storage.unlink_location(instance, ctx.a)
      assert on(ctx.a, key)
    end

    test "leaves a row moved to another key alone", ctx do
      file = upload!(ctx, "moved")
      instance = Storage.get_file_instance_by_name(file.uuid, "original")

      Repo.update_all(from(i in FileInstance, where: i.uuid == ^instance.uuid),
        set: [file_name: "moved/elsewhere.txt"]
      )

      assert {:ok, :kept} = Storage.unlink_location(instance, ctx.a)
      assert on(ctx.a, instance.file_name)
    end
  end

  describe "uploads" do
    test "a failed bucket is replaced by a spare", ctx do
      {:ok, _} = Profiles.put_bucket(profile(ctx), broken_bucket!().uuid, %{write_priority: 1})
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{})

      {:ok, _} =
        Profiles.update_profile(profile(ctx), %{copies_local: 2, min_copies_on_write: 2})

      file = upload!(ctx, "spare")
      assert MapSet.new(Locations.bucket_uuids(key(file))) == MapSet.new([ctx.a.uuid, ctx.b.uuid])
    end

    test "a rolled-back write leaves bytes another file owns", ctx do
      owner = upload!(ctx, "owned bytes")
      key = key(owner)

      {:ok, _} = Profiles.put_bucket(profile(ctx), broken_bucket!().uuid, %{})

      {:ok, _} =
        Profiles.update_profile(profile(ctx), %{copies_local: 2, min_copies_on_write: 2})

      assert {:error, _} =
               Manager.store_file(source!("owned bytes"),
                 path_prefix: key,
                 profile: profile(ctx)
               )

      assert on(ctx.a, key)
    end

    test "bucket usage counts files under a megabyte", ctx do
      _file = upload!(ctx, "a few bytes")
      assert Storage.calculate_bucket_usage(ctx.a.uuid) > 0
    end
  end

  describe "settings and sizes" do
    test "the redundancy alias sets the copy count in all, local buckets first", ctx do
      default = Profiles.default_profile()
      {:ok, _} = Profiles.update_profile(default, %{copies_local: 1, copies_cloud: 0})
      _ = ctx

      {:ok, _} = Storage.set_redundancy_copies(2)
      assert %{copies_local: 2, copies_cloud: 0, copies_originals: 2} = Profiles.default_profile()

      {:ok, _} = Storage.set_redundancy_copies(3)
      default = Profiles.default_profile()
      assert Profiles.copies_total(default) == 3
      assert %{copies_originals: 3, copies_variants: 3} = default
    end

    test "a rename moves nothing: the counts and the revision stay", ctx do
      _ = ctx
      {:ok, profile} = Profiles.create_profile(%{name: "Old counts #{System.unique_integer()}"})
      {:ok, profile} = Profiles.update_profile(profile, %{copies_local: 2})

      {:ok, renamed} =
        Profiles.update_profile(profile, %{name: "Renamed #{System.unique_integer()}"})

      # Nothing about where files live changed, so nothing is placed again.
      assert renamed.revision == profile.revision
      assert Profiles.copies_total(renamed) == 2

      {:ok, changed} = Profiles.update_profile(renamed, %{copies_local: 3})
      assert changed.revision > renamed.revision
      # The total and the older column follow the counts.
      assert {changed.copies_originals, changed.copies_variants} == {3, 3}
    end

    test "how many copies an upload needs changes no revision", ctx do
      {:ok, profile} = Profiles.update_profile(profile(ctx), %{copies_local: 2})
      {:ok, updated} = Profiles.update_profile(profile, %{min_copies_on_write: 2})
      assert updated.revision == profile.revision
    end

    test "resetting the Default's sizes bumps its revision" do
      before = VariantSets.default_variant_set().revision
      {:ok, _} = Storage.reset_dimensions_to_defaults()
      assert VariantSets.default_variant_set().revision > before
    end

    test "a cropped small from before V205 can still be switched off" do
      {:ok, set} = VariantSets.create_variant_set(%{name: "Cropped #{System.unique_integer()}"})
      small = Storage.get_dimension_by_name("small", set.uuid)

      Repo.update_all(from(d in Dimension, where: d.uuid == ^small.uuid),
        set: [maintain_aspect_ratio: false, height: 300]
      )

      small = Storage.get_dimension_by_name("small", set.uuid)
      assert {:ok, _} = Storage.update_dimension(small, %{enabled: false})
    end

    test "variant_for gives a video's poster, or a transcode when asked" do
      file = %Storage.File{library_uuid: nil, file_type: "video"}

      assert Storage.variant_for(file, min_width: 300) == "video_thumbnail"
      refute Storage.variant_for(file, min_width: 300, output: :video) == "video_thumbnail"
    end
  end

  describe "Grok's review" do
    test "a rolled-back write keeps a key another upload into the directory is writing", ctx do
      owner = upload!(ctx, "racing bytes")
      key = key(owner)
      instance = Storage.get_file_instance_by_name(owner.uuid, "original")
      Repo.delete_all(from(i in FileInstance, where: i.uuid == ^instance.uuid))

      # The other upload: its row exists, its instance not yet.
      Repo.update_all(from(f in Storage.File, where: f.uuid == ^owner.uuid),
        set: [status: "processing"]
      )

      :ok = Storage.undo_store(key, [ctx.a.uuid], nil)
      assert on(ctx.a, key)

      # Its own row does not hold the rollback back.
      :ok = Storage.undo_store(key, [ctx.a.uuid], owner.uuid)
      refute on(ctx.a, key)
    end

    test "a copy is served by its own file's profile, not a clone's", ctx do
      donor = upload!(ctx, "shared served")
      clone = upload!(ctx, "shared served", user!())
      key = key(donor)
      assert key(clone) == key

      # The clone's library moves to a profile that calls bucket a a backup.
      {:ok, cold} = Profiles.create_profile(%{name: "Cold #{ctx.n}"})
      {:ok, _} = Profiles.put_bucket(cold, ctx.a.uuid, %{role: "backup"})
      {:ok, cold_library} = Libraries.create_system_library(%{name: "Cold #{ctx.n}"})
      {:ok, cold_library} = Profiles.set_library_profile(cold_library, cold.uuid)

      {:ok, _} =
        Storage.update_file(Storage.get_file(clone.uuid), %{library_uuid: cold_library.uuid})

      assert {:local, _} = Manager.get_file_access(key, file_uuid: donor.uuid)
      assert {:error, :not_found} = Manager.get_file_access(key, file_uuid: clone.uuid)
    end

    test "a backup without a location row is not probed for serving", ctx do
      file = upload!(ctx, "backup fallback")
      key = key(file)
      File.mkdir_p!(Path.dirname(Path.join(ctx.b.endpoint, key)))
      File.cp!(Path.join(ctx.a.endpoint, key), Path.join(ctx.b.endpoint, key))
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{role: "backup"})
      File.rm!(Path.join(ctx.a.endpoint, key))
      Repo.delete_all(from(l in Storage.FileLocation, where: l.path == ^key))

      assert {:error, :not_found} = Manager.get_file_access(key, file_uuid: file.uuid)
    end

    test "a trashed file keeps its size stamp and is not stale for sizes", ctx do
      file = upload!(ctx, "trashed sizes")
      {:ok, _} = Storage.trash_file(file)
      {:ok, set} = VariantSets.create_variant_set(%{name: "Trash #{ctx.n}"})
      {:ok, _} = VariantSets.set_library_variant_set(ctx.library, set.uuid)

      refute Repo.exists?(from(f in Reconciler.stale_query(), where: f.uuid == ^file.uuid))
    end

    test "a shared key is counted once in a bucket's usage", ctx do
      donor = upload!(ctx, String.duplicate("x", 600_000))
      one = Storage.calculate_bucket_usage(ctx.a.uuid)
      _clone = upload!(ctx, String.duplicate("x", 600_000), user!())

      assert key(donor)
      assert Storage.calculate_bucket_usage(ctx.a.uuid) == one
    end

    test "a serve order or write priority edit makes no file stale; a role edit does", ctx do
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{})
      before = profile(ctx).revision

      {:ok, _} =
        Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{serve_order: 9, write_priority: 3})

      assert profile(ctx).revision == before

      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{role: "replica"})
      assert profile(ctx).revision == before + 1
    end

    test "a file whose only copy is on a backup gets one it may serve", ctx do
      file = upload!(ctx, "needs a primary")
      key = key(file)
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.a.uuid, %{role: "backup"})
      {:ok, _} = Profiles.put_bucket(profile(ctx), ctx.b.uuid, %{})

      assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled
      assert on(ctx.b, key)
      assert {:local, path} = Manager.get_file_access(key, file_uuid: file.uuid)
      assert String.starts_with?(path, ctx.b.endpoint)
    end
  end
end
