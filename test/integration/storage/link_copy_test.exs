defmodule PhoenixKit.Modules.Storage.LinkCopyTest do
  @moduledoc """
  `Storage.link_copy/3`: an explicit copy of a file into another library that
  names the donor's stored objects (the original and the variants its
  library's set made) instead of writing the bytes again, as a record of its
  own. What these pin: what is shared and what is not (a burned thumbnail is
  never), that deleting, editing or trashing the donor does not reach the
  copy, that an unfit donor is refused, and that a donor that went away under
  the caller is `:donor_changed`.

  Skipped when ImageMagick isn't installed.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.TestSupport.LinkCopyHelpers

  alias PhoenixKit.Modules.Storage

  alias PhoenixKit.Modules.Storage.{
    ApplyImageEditJob,
    ImageEditing,
    Manager,
    Profiles,
    Reconciler
  }

  alias PhoenixKit.Modules.Storage.VariantSets
  alias PhoenixKit.Users.Auth.Scope

  @moduletag :tmp_dir

  unless imagemagick?(),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  @job_worker "PhoenixKit.Modules.Storage.ApplyImageEditJob"

  setup %{tmp_dir: tmp} do
    if imagemagick?() do
      env = setup_storage(tmp)
      owner = user!("owner", env.n)
      copier = user!("copier", env.n)
      donor = upload!(owner, image!(tmp, "photo.jpg"))
      target = library!(env.n)

      Map.merge(env, %{owner: owner, copier: copier, donor: donor, target: target})
    else
      {:ok, skip: true}
    end
  end

  defp link!(ctx, opts \\ [], donor \\ nil) do
    opts = Keyword.put_new(opts, :library_uuid, ctx.target.uuid)
    assert {:ok, copy} = Storage.link_copy(donor || ctx.donor, ctx.copier.uuid, opts)
    copy
  end

  describe "into another library" do
    test "is a record of its own on the donor's objects, and writes none", ctx do
      assert map_size(keys(ctx.donor)) > 1, "the donor has no variants to share"
      before = object_count(ctx.root)

      copy = link!(ctx, original_filename: "mail.jpg")

      assert copy.uuid != ctx.donor.uuid
      assert copy.library_uuid == ctx.target.uuid
      assert copy.user_uuid == ctx.copier.uuid
      assert copy.status == "active"
      assert copy.original_file_name == "mail.jpg"
      assert copy.file_path == ctx.donor.file_path
      assert copy.file_name == ctx.donor.file_name
      assert copy.file_checksum == ctx.donor.file_checksum
      assert copy.size == ctx.donor.size
      assert {copy.width, copy.height} == {ctx.donor.width, ctx.donor.height}
      assert copy.mime_type == ctx.donor.mime_type
      assert copy.user_file_checksum == "nodedup:" <> copy.uuid

      assert keys(copy) == keys(ctx.donor)
      refute Enum.any?(Map.keys(keys(copy)), &String.starts_with?(&1, "burned"))
      assert object_count(ctx.root) == before

      # Placed as the donor is, and not waiting for sizes it already has.
      assert copy.placed_variant_revision == reload(ctx.donor).placed_variant_revision
      assert queued_jobs(copy) == []

      for inst <- instances(copy) do
        donor_inst = instance(ctx.donor, inst.variant_name)
        assert inst.checksum == donor_inst.checksum
        assert inst.spec_hash == donor_inst.spec_hash

        assert Storage.get_file_instance_by_name(copy.uuid, inst.variant_name).uuid !=
                 donor_inst.uuid

        assert locations(inst) == locations(donor_inst)
        assert locations(inst) != []
      end
    end

    test "takes the folder asked for, and the answer is not a duplicate", ctx do
      {:ok, folder} =
        Storage.create_folder(%{
          name: "mail #{ctx.n}",
          user_uuid: ctx.copier.uuid,
          library_uuid: ctx.target.uuid
        })

      copy = link!(ctx, folder_uuid: folder.uuid)
      assert copy.folder_uuid == folder.uuid
      assert reload(copy).folder_uuid == folder.uuid
    end

    test "an ordinary upload of the same bytes into the library does not return the copy", ctx do
      copy = link!(ctx)

      source = Path.join(ctx.tmp, "photo.jpg")
      sha = copy.file_checksum

      result =
        Storage.store_file_in_buckets(source, "image", ctx.copier.uuid, sha, "jpg", "photo.jpg",
          library_uuid: ctx.target.uuid
        )

      other =
        case result do
          {:ok, file} -> file
          {:ok, file, _} -> file
        end

      assert other.uuid != copy.uuid
    end

    test "a burned thumbnail of the donor is not shared; the rest of the set is", ctx do
      burned = burn!(ctx.donor, "thumbnail", ctx.tmp)
      assert burned.spec_hash == nil
      donor = reload(ctx.donor)
      donor_keys = keys(donor)
      assert donor_keys["thumbnail"] == burned.file_name
      burned_sha = object_sha256(burned.file_name)

      copy = link!(ctx, [], donor)

      copy_keys = keys(copy)
      refute Map.has_key?(copy_keys, "thumbnail")
      assert Map.delete(copy_keys, "thumbnail") == Map.delete(donor_keys, "thumbnail")
      assert copy.placed_variant_revision == 0
      # No job that would make every size again: the reconciler makes the one.
      assert queued_jobs(copy) == []
      count = object_count(ctx.root)

      assert :reconciled = Reconciler.reconcile_file(copy)

      copy = reload(copy)
      fresh = instance(copy, "thumbnail")
      assert fresh.spec_hash != nil
      assert fresh.checksum != burned.checksum
      assert fresh.file_name != burned.file_name
      assert object_sha256(fresh.file_name) != burned_sha
      assert object_sha256(burned.file_name) == burned_sha
      assert instance(donor, "thumbnail").checksum == burned.checksum

      # Shared sizes stay on the donor's keys, and nothing but one object was written.
      assert Map.delete(keys(copy), "thumbnail") == Map.delete(donor_keys, "thumbnail")
      assert object_count(ctx.root) == count + 1
    end

    test "a PNG with alpha (sizes not byte-stable): shared sizes survive the catch-up", ctx do
      donor = upload!(ctx.owner, alpha_png!(ctx.tmp, "alpha.png"))
      assert instance(donor, "large").file_name =~ ".png"
      burn!(donor, "thumbnail", ctx.tmp)
      donor = reload(donor)
      donor_keys = keys(donor)

      copy = link!(ctx, [], donor)
      assert Map.delete(keys(copy), "thumbnail") == Map.delete(donor_keys, "thumbnail")
      count = object_count(ctx.root)
      Process.sleep(1100)

      assert :reconciled = Reconciler.reconcile_file(copy)

      copy = reload(copy)
      assert Map.delete(keys(copy), "thumbnail") == Map.delete(donor_keys, "thumbnail")
      assert Map.has_key?(keys(copy), "thumbnail")
      assert object_count(ctx.root) == count + 1
      assert all_keys_exist?(Map.values(donor_keys))
    end

    test "an annotation thumbnail outside the set is not shared and costs the copy nothing",
         ctx do
      burn!(ctx.donor, "thumbnail_annotated", ctx.tmp)
      donor = reload(ctx.donor)
      assert Map.has_key?(keys(donor), "thumbnail_annotated")

      copy = link!(ctx, [], donor)

      refute Map.has_key?(keys(copy), "thumbnail_annotated")
      assert Map.delete(keys(donor), "thumbnail_annotated") == keys(copy)
      assert copy.placed_variant_revision == donor.placed_variant_revision
      assert queued_jobs(copy) == []
    end

    test "a variant made from another spec than the target's set is not shared", ctx do
      inst = instance(ctx.donor, "small")

      Repo.update_all(from(i in Storage.FileInstance, where: i.uuid == ^inst.uuid),
        set: [spec_hash: "old"]
      )

      copy = link!(ctx)

      refute Map.has_key?(keys(copy), "small")
      assert copy.placed_variant_revision == 0
    end
  end

  describe "keys that cannot be trusted are not shared" do
    setup ctx do
      sha = ctx.donor.file_checksum

      assert {:ok, clone, :duplicate} =
               Storage.store_file_in_buckets(
                 Path.join(ctx.tmp, "photo.jpg"),
                 "image",
                 ctx.copier.uuid,
                 sha,
                 "jpg",
                 "p.jpg"
               )

      assert keys(clone) == keys(ctx.donor)
      %{clone: clone}
    end

    test "a cross-user clone whose key an old burn wrote over in place", ctx do
      # What a burn did before it got keys of its own: the owner's row says
      # "no size, other bytes" on the key the clone still calls the thumbnail.
      inst = instance(ctx.donor, "thumbnail")

      Repo.update_all(from(i in Storage.FileInstance, where: i.uuid == ^inst.uuid),
        set: [spec_hash: nil, checksum: "markup"]
      )

      copy = link!(ctx, [], ctx.clone)

      refute Map.has_key?(keys(copy), "thumbnail")
      assert Map.delete(keys(copy), "thumbnail") == Map.delete(keys(ctx.clone), "thumbnail")
      assert copy.placed_variant_revision == 0
    end

    test "a thumbnail whose object does not hold what its row says is not shared", ctx do
      # The row of whoever burned in place has left the key (they burned again
      # or went away); the clone's row alone names it, as it was generated.
      assert keys(ctx.clone)["thumbnail"] == keys(ctx.donor)["thumbnail"]
      inst = instance(ctx.donor, "thumbnail")
      Repo.delete!(inst)
      # ...and the object holds what the burn wrote there.
      File.write!(Path.join(ctx.root, inst.file_name), "burned markup")

      copy = link!(ctx, [], ctx.clone)

      refute Map.has_key?(keys(copy), "thumbnail")
      assert Map.delete(keys(copy), "thumbnail") == Map.delete(keys(ctx.clone), "thumbnail")
      assert copy.placed_variant_revision == 0
    end

    test "a second copy of the same donor shares the thumbnail the first one names", ctx do
      first = link!(ctx, [], ctx.donor)
      second = link!(ctx, [], ctx.donor)

      assert keys(first) == keys(ctx.donor)
      assert keys(second) == keys(ctx.donor)
      assert second.placed_variant_revision == reload(ctx.donor).placed_variant_revision
    end

    test "a variant that is not completed is not shared", ctx do
      inst = instance(ctx.clone, "small")

      Repo.update_all(from(i in Storage.FileInstance, where: i.uuid == ^inst.uuid),
        set: [processing_status: "pending"]
      )

      copy = link!(ctx, [], ctx.clone)
      refute Map.has_key?(keys(copy), "small")
      assert copy.placed_variant_revision == 0
    end

    test "a variant whose object is not in the bucket is not shared", ctx do
      :ok = Manager.delete_file(instance(ctx.clone, "medium").file_name)

      copy = link!(ctx, [], ctx.clone)
      refute Map.has_key?(keys(copy), "medium")
      assert Map.has_key?(keys(copy), "large")
      assert copy.placed_variant_revision == 0
    end
  end

  describe "the folder asked for" do
    test "another library's, a missing and a trashed one are :other_library; nothing is written",
         ctx do
      {:ok, elsewhere} =
        Storage.create_folder(%{name: "media #{ctx.n}", user_uuid: ctx.copier.uuid})

      {:ok, trashed} =
        Storage.create_folder(%{
          name: "trashed #{ctx.n}",
          user_uuid: ctx.copier.uuid,
          library_uuid: ctx.target.uuid
        })

      {:ok, _} = Storage.trash_folder(trashed)
      before = Repo.aggregate(Storage.File, :count)

      for folder_uuid <- [elsewhere.uuid, trashed.uuid, Ecto.UUID.generate()] do
        assert {:error, :other_library} =
                 Storage.link_copy(ctx.donor, ctx.copier.uuid,
                   library_uuid: ctx.target.uuid,
                   folder_uuid: folder_uuid
                 )
      end

      assert Repo.aggregate(Storage.File, :count) == before
    end
  end

  # Storage is asked before the transaction (fotki.ee, 2026-11-10: a slow S3
  # answer inside it outlived the pool's 15 s and rolled the copy back). The
  # donor's thumbnail object is swapped for a named pipe: the copy's check
  # reads it, and blocks until the test writes the bytes, so the test can look
  # at the copying process in the middle of the check.
  describe "the buckets are asked before the transaction" do
    test "no connection is held while storage answers", ctx do
      assert map_size(keys(ctx.donor)) > 1, "the donor has no variants to share"
      {fifo, bytes} = thumbnail_pipe!(ctx)
      copier = Task.async(fn -> link_copy(ctx) end)

      {:ok, writer} = open_pipe(fifo)
      refute holds_connection?(copier.pid)
      IO.binwrite(writer, bytes)
      :ok = File.close(writer)

      assert {:ok, copy} = Task.await(copier, 30_000)
      assert keys(copy) == keys(ctx.donor)
      assert copy.placed_variant_revision == reload(ctx.donor).placed_variant_revision
    end

    test "the probe sees a held connection (so the test above can fail)", _ctx do
      test = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            send(test, :inside)

            receive do
              :done -> :ok
            end
          end)
        end)

      assert_receive :inside, 5_000
      assert holds_connection?(holder.pid)
      send(holder.pid, :done)
      Task.await(holder)
    end

    test "a size whose row changed while storage answered is not shared", ctx do
      {fifo, bytes} = thumbnail_pipe!(ctx)
      small = instance(ctx.donor, "small")
      assert small, "the donor has no small size"
      copier = Task.async(fn -> link_copy(ctx) end)

      {:ok, writer} = open_pipe(fifo)
      # What a burn does to the row of the size it rewrites.
      Repo.update_all(from(i in Storage.FileInstance, where: i.uuid == ^small.uuid),
        set: [checksum: String.duplicate("0", 64)]
      )

      IO.binwrite(writer, bytes)
      :ok = File.close(writer)

      assert {:ok, copy} = Task.await(copier, 30_000)
      copy_keys = keys(copy)
      refute Map.has_key?(copy_keys, "small")
      assert copy_keys["thumbnail"] == keys(ctx.donor)["thumbnail"]
      assert copy.placed_variant_revision == 0
    end

    test "an original whose row changed is asked about again", ctx do
      {fifo, bytes} = thumbnail_pipe!(ctx)
      original = instance(ctx.donor, "original")
      copier = Task.async(fn -> link_copy(ctx) end)

      {:ok, writer} = open_pipe(fifo)

      Repo.update_all(from(i in Storage.FileInstance, where: i.uuid == ^original.uuid),
        set: [size: original.size + 1, checksum: String.duplicate("1", 64)]
      )

      # The second round reads an ordinary file (raw, as `open_pipe/1`).
      :ok = :file.delete(fifo, [:raw])
      File.write!(fifo, bytes, [:raw])
      IO.binwrite(writer, bytes)
      :ok = File.close(writer)

      assert {:ok, copy} = Task.await(copier, 30_000)
      assert keys(copy)["original"] == original.file_name
      assert instance(copy, "original").checksum == String.duplicate("1", 64)
    end

    test "what the rows refuse is refused without asking a bucket", ctx do
      # Nobody writes to the pipe: a check reading it would wait out its 8 s.
      {_fifo, _bytes} = thumbnail_pipe!(ctx)

      {micros, result} =
        :timer.tc(fn ->
          Storage.link_copy(ctx.donor, ctx.copier.uuid, library_uuid: Ecto.UUID.generate())
        end)

      assert result == {:error, :incompatible}
      assert micros < 3_000_000
    end

    test "a check that runs out of time does not share that size", ctx do
      Application.put_env(:phoenix_kit, :storage_check_timeout_ms, 300)
      on_exit(fn -> Application.delete_env(:phoenix_kit, :storage_check_timeout_ms) end)
      {fifo, _bytes} = thumbnail_pipe!(ctx)

      result = link_copy(ctx)
      # The killed check is still opening the pipe; let it go.
      release_pipe(fifo)

      assert {:ok, copy} = result
      copy_keys = keys(copy)
      refute Map.has_key?(copy_keys, "thumbnail")
      assert Map.delete(copy_keys, "thumbnail") == Map.delete(keys(ctx.donor), "thumbnail")
      assert copy.placed_variant_revision == 0
    end
  end

  describe "inside the caller's transaction" do
    test "a refusal leaves the outer transaction usable", ctx do
      record = upload!(ctx.owner, image!(ctx.tmp, "record.jpg", "blue"))
      {:ok, _} = Storage.trash_file(ctx.donor)
      gone = Storage.get_file(ctx.donor.uuid)
      missing_lib = Ecto.UUID.generate()

      assert {:ok, folder} =
               Repo.transaction(fn ->
                 assert {:error, :donor_unavailable} =
                          Storage.link_copy(gone, ctx.copier.uuid, library_uuid: ctx.target.uuid)

                 assert {:error, :incompatible} =
                          Storage.link_copy(gone, ctx.copier.uuid, library_uuid: missing_lib)

                 assert {:error, :incompatible} = Storage.relink_file(gone, gone)

                 assert {:error, :donor_changed} =
                          Storage.link_copy(
                            %{gone | uuid: Ecto.UUID.generate()},
                            ctx.copier.uuid,
                            library_uuid: ctx.target.uuid
                          )

                 assert {:error, :donor_unavailable} = Storage.relink_file(record, gone)

                 {:ok, folder} =
                   Storage.create_folder(%{
                     name: "after refusal #{ctx.n}",
                     user_uuid: ctx.copier.uuid,
                     library_uuid: ctx.target.uuid
                   })

                 folder
               end)

      assert Repo.get(Storage.Folder, folder.uuid)
    end

    test "relink_file with delete_old: true is refused inside it and deletes nothing", ctx do
      snap =
        upload!(ctx.copier, Path.join(ctx.tmp, "photo.jpg"),
          library_uuid: ctx.target.uuid,
          dedup: false
        )

      old = Map.values(keys(snap))

      assert {:error, :rolled_back} =
               Repo.transaction(fn ->
                 assert {:error, :in_transaction} =
                          Storage.relink_file(snap, ctx.donor, delete_old: true)

                 Repo.rollback(:rolled_back)
               end)

      assert all_keys_exist?(old)
      assert Map.values(keys(reload(snap))) == Map.values(keys(snap))
      assert {:ok, _, _} = Storage.relink_file(snap, ctx.donor, delete_old: true)
    end

    test "a success inside it is part of it", ctx do
      assert {:error, :undone} =
               Repo.transaction(fn ->
                 copy = link!(ctx)
                 assert Storage.get_file(copy.uuid)
                 Repo.rollback(:undone)
               end)

      assert Repo.aggregate(
               from(f in Storage.File, where: f.library_uuid == ^ctx.target.uuid),
               :count
             ) ==
               0
    end
  end

  describe "the capture date" do
    setup ctx do
      Repo.update_all(from(f in Storage.File, where: f.uuid == ^ctx.donor.uuid),
        set: [
          taken_at: ~U[2020-01-02 03:04:05Z],
          taken_on: ~D[2020-01-02],
          taken_at_offset: 0,
          taken_at_source: "manual"
        ]
      )

      %{dated: reload(ctx.donor)}
    end

    test "is not copied to another user's copy", ctx do
      copy = link!(ctx, [], ctx.dated)

      assert copy.user_uuid != ctx.dated.user_uuid
      assert {copy.taken_at, copy.taken_on, copy.taken_at_source} == {nil, nil, nil}
    end

    test "that the bytes gave (exif, container) is copied to another user's copy", ctx do
      for source <- ~w(exif container) do
        Repo.update_all(from(f in Storage.File, where: f.uuid == ^ctx.donor.uuid),
          set: [taken_at_source: source]
        )

        copy = link!(ctx, [], reload(ctx.donor))
        assert copy.taken_at == ctx.dated.taken_at
        assert copy.taken_at_source == source
      end
    end

    test "from a filename or the insert time is not copied to another user's copy", ctx do
      for source <- ~w(filename inserted_at) do
        Repo.update_all(from(f in Storage.File, where: f.uuid == ^ctx.donor.uuid),
          set: [taken_at_source: source]
        )

        copy = link!(ctx, [], reload(ctx.donor))
        assert copy.taken_at == nil
      end
    end

    test "is the donor owner's own to keep", ctx do
      assert {:ok, copy} =
               Storage.link_copy(ctx.dated, ctx.owner.uuid, library_uuid: ctx.target.uuid)

      assert copy.taken_at == ctx.dated.taken_at
      assert copy.taken_at_source == "manual"
    end
  end

  describe "the donor and the copy live their own lives" do
    test "the donor deleted completely: the copy is still readable; then deleted: the keys go",
         ctx do
      copy = link!(ctx)
      all = Map.values(keys(copy))
      assert all_keys_exist?(all)

      assert {:ok, _} = Storage.delete_file_completely(ctx.donor)

      assert all_keys_exist?(all)
      assert {:ok, path, _file} = Storage.retrieve_file(copy.uuid)
      assert File.read!(path) == File.read!(Path.join(ctx.tmp, "photo.jpg"))

      assert {:ok, _} = Storage.delete_file_completely(copy)
      refute Enum.any?(all, &exists?/1)
    end

    test "the copy deleted: the donor's keys stay", ctx do
      copy = link!(ctx)
      donor_keys = Map.values(keys(ctx.donor))

      assert {:ok, _} = Storage.delete_file_completely(copy)

      assert all_keys_exist?(donor_keys)
      assert {:ok, _path, _file} = Storage.retrieve_file(ctx.donor.uuid)
    end

    test "an edit of the donor's image does not change what the copy serves", ctx do
      copy = link!(ctx)
      %{file_name: key, checksum: checksum} = instance(copy, "original")
      before_sha = object_sha256(key)

      scope = Scope.for_user(ctx.owner)
      assert {:ok, pending} = ImageEditing.edit(ctx.donor, %{"rotate" => 90}, scope: scope)
      assert pending.edit_state == "pending"
      drain()

      edited = reload(ctx.donor)
      assert instance(edited, "original").file_name != key
      assert edited.file_checksum != checksum

      assert %{file_name: ^key, checksum: ^checksum} = instance(copy, "original")
      assert exists?(key)
      assert object_sha256(key) == before_sha
      assert reload(copy).file_checksum == checksum
    end

    test "trashing and restoring the donor leaves the copy as it is", ctx do
      copy = link!(ctx)
      before = {keys(copy), reload(copy).status, reload(copy).placed_variant_revision}

      assert {:ok, _} = Storage.trash_file(ctx.donor)
      assert {keys(copy), reload(copy).status, reload(copy).placed_variant_revision} == before

      assert {:ok, _} = Storage.restore_file(ctx.donor)
      assert {keys(copy), reload(copy).status, reload(copy).placed_variant_revision} == before
      assert all_keys_exist?(Map.values(keys(copy)))
    end
  end

  describe "a donor that does not fit" do
    test "another storage profile is :incompatible", ctx do
      {:ok, profile} = Profiles.create_profile(%{name: "Other #{ctx.n}"})
      {:ok, target} = Profiles.set_library_profile(ctx.target, profile.uuid)

      assert {:error, :incompatible} =
               Storage.link_copy(ctx.donor, ctx.copier.uuid, library_uuid: target.uuid)
    end

    test "another variant set is :incompatible", ctx do
      {:ok, set} = VariantSets.create_variant_set(%{name: "Other #{ctx.n}"})
      {:ok, target} = VariantSets.set_library_variant_set(ctx.target, set.uuid)

      assert {:error, :incompatible} =
               Storage.link_copy(ctx.donor, ctx.copier.uuid, library_uuid: target.uuid)
    end

    test "a donor in the trash, system-managed or being edited is :donor_unavailable", ctx do
      opts = [library_uuid: ctx.target.uuid]
      row = from(f in Storage.File, where: f.uuid == ^ctx.donor.uuid)

      Repo.update_all(row, set: [edit_state: "pending"])
      assert {:error, :donor_unavailable} = Storage.link_copy(ctx.donor, ctx.copier.uuid, opts)
      Repo.update_all(row, set: [edit_state: nil])

      Repo.update_all(row, set: [system_managed: true])
      assert {:error, :donor_unavailable} = Storage.link_copy(ctx.donor, ctx.copier.uuid, opts)
      Repo.update_all(row, set: [system_managed: false])

      assert {:ok, _} = Storage.trash_file(ctx.donor)
      assert {:error, :donor_unavailable} = Storage.link_copy(ctx.donor, ctx.copier.uuid, opts)
    end

    test "an original that is not in the bucket is :donor_unavailable", ctx do
      %{file_name: key} = instance(ctx.donor, "original")
      :ok = Manager.delete_file(key)

      assert {:error, :donor_unavailable} =
               Storage.link_copy(ctx.donor, ctx.copier.uuid, library_uuid: ctx.target.uuid)

      assert Repo.aggregate(
               from(f in Storage.File, where: f.library_uuid == ^ctx.target.uuid),
               :count
             ) == 0
    end

    test "a checksum or size the caller does not expect is :donor_unavailable", ctx do
      %{checksum: checksum, size: size} = instance(ctx.donor, "original")
      opts = [library_uuid: ctx.target.uuid]

      assert {:error, :donor_unavailable} =
               Storage.link_copy(ctx.donor, ctx.copier.uuid, [checksum: "0" <> checksum] ++ opts)

      assert {:error, :donor_unavailable} =
               Storage.link_copy(ctx.donor, ctx.copier.uuid, [size: size + 1] ++ opts)

      assert {:ok, _} =
               Storage.link_copy(
                 ctx.donor,
                 ctx.copier.uuid,
                 [checksum: checksum, size: size] ++ opts
               )
    end

    test "a library that does not exist is :incompatible", ctx do
      assert {:error, :incompatible} =
               Storage.link_copy(ctx.donor, ctx.copier.uuid, library_uuid: Ecto.UUID.generate())
    end

    test "nothing is left behind by a refusal", ctx do
      before = Repo.aggregate(Storage.File, :count)
      :ok = Manager.delete_file(instance(ctx.donor, "original").file_name)
      {:error, _} = Storage.link_copy(ctx.donor, ctx.copier.uuid, library_uuid: ctx.target.uuid)
      assert Repo.aggregate(Storage.File, :count) == before
    end
  end

  describe "a donor that went away under the caller" do
    # The copy runs in one transaction under the donor's row lock and its
    # directory's lock (the order a deletion takes them in), and reads the
    # donor again there: a deletion either ran first — then the row is gone
    # and nothing is copied — or is held behind the copy and finds its keys
    # referenced (the "deleted completely" test above). One connection serves
    # a test, so the first half is pinned with the donor struct the caller
    # holds going stale.
    test "deleted before the copy is made", ctx do
      assert {:ok, _} = Storage.delete_file_completely(ctx.donor)

      assert {:error, :donor_changed} =
               Storage.link_copy(ctx.donor, ctx.copier.uuid, library_uuid: ctx.target.uuid)
    end

    test "moved (another file_path) since the caller read it", ctx do
      Repo.update_all(from(f in Storage.File, where: f.uuid == ^ctx.donor.uuid),
        set: [file_path: "elsewhere"]
      )

      assert {:error, :donor_changed} =
               Storage.link_copy(ctx.donor, ctx.copier.uuid, library_uuid: ctx.target.uuid)
    end

    test "changed (another original) since the caller read it", ctx do
      Repo.update_all(from(f in Storage.File, where: f.uuid == ^ctx.donor.uuid),
        set: [file_checksum: "changed"]
      )

      assert {:error, :donor_changed} =
               Storage.link_copy(ctx.donor, ctx.copier.uuid, library_uuid: ctx.target.uuid)
    end
  end

  defp link_copy(ctx),
    do: Storage.link_copy(ctx.donor, ctx.copier.uuid, library_uuid: ctx.target.uuid)

  # Replaces the donor's thumbnail object (local bucket) with a named pipe and
  # returns its path and the bytes it held.
  defp thumbnail_pipe!(ctx) do
    path = Path.join(ctx.root, keys(ctx.donor)["thumbnail"])
    bytes = File.read!(path)
    File.rm!(path)
    {_, 0} = System.cmd("mkfifo", [path])
    {path, bytes}
  end

  # Opening a pipe for writing returns once a reader has it open. Raw: the
  # reader (the check's `File.cp`) holds the file server until then, and an
  # ordinary open would wait behind it.
  defp open_pipe(fifo), do: File.open(fifo, [:write, :binary, :raw])

  defp release_pipe(fifo) do
    writer = Task.async(fn -> with {:ok, w} <- open_pipe(fifo), do: File.close(w) end)
    Task.yield(writer, 1_000) || Task.shutdown(writer, :brutal_kill)
  end

  # Ecto keeps the connection a process has checked out (a transaction, a
  # `checkout`) in its dictionary under `{Ecto.Adapters.SQL, pool}`.
  defp holds_connection?(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    Enum.any?(dictionary, &match?({{Ecto.Adapters.SQL, _pool}, _conn}, &1))
  end

  defp locations(instance) do
    Repo.all(
      from(l in Storage.FileLocation,
        where: l.file_instance_uuid == ^instance.uuid,
        order_by: [l.bucket_uuid, l.path],
        select: {l.bucket_uuid, l.path, l.status}
      )
    )
  end

  defp drain do
    jobs =
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == @job_worker and j.state == "available",
          order_by: j.id
        )
      )

    for job <- jobs do
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "completed"])
      assert :ok = ApplyImageEditJob.perform(%{job | attempt: 1})
    end
  end
end
