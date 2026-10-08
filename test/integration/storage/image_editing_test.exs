defmodule PhoenixKit.Modules.Storage.ImageEditingTest do
  @moduledoc """
  Editing a stored image end to end: `ImageEditing` saves the edit,
  `ApplyImageEditJob` renders and swaps it in, against a real local bucket
  and real ImageMagick.

  What these pin: the file keeps its uuid and serves the edited bytes; the
  unedited original survives in a hidden backup until the owner deletes it
  (or the site bakes every edit); every stored object goes exactly when its
  last reference does; a run for a stale revision never publishes.

  Skipped when ImageMagick isn't installed.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Annotations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ApplyImageEditJob
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.FocalPoint
  alias PhoenixKit.Modules.Storage.ImageEditing
  alias PhoenixKit.Modules.Storage.Manager
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.Modules.Storage.VariantGenerator
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  @moduletag :tmp_dir

  # ExUnit cannot skip from `setup` (a `skip:` it returns is only context), so
  # the ImageMagick check is a module tag. `convert`/`identify` are what
  # `ImageProcessor` runs — ImageMagick 6 has no `magick` binary.
  unless System.find_executable("convert") && System.find_executable("identify"),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  @buckets_cache :phoenix_kit_buckets_cache
  @job_worker "PhoenixKit.Modules.Storage.ApplyImageEditJob"

  setup %{tmp_dir: tmp} do
    if imagemagick?() do
      :persistent_term.erase(@buckets_cache)
      n = System.unique_integer([:positive])

      # Only this test's bucket: the seeded default one lives in the project
      # tree and outlasts the test, so identical uploads would share it.
      Repo.update_all(Bucket, set: [enabled: false])

      {:ok, _bucket} =
        Storage.create_bucket(%{
          name: "image-edit-#{n}",
          provider: "local",
          endpoint: Path.join(tmp, "bucket"),
          enabled: true,
          priority: 0
        })

      start_supervised!(
        {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
      )

      on_exit(fn -> :persistent_term.erase(@buckets_cache) end)

      # The first registered user becomes Owner; the users below must not.
      _owner_role_holder = user!("first", n)
      owner = user!("owner", n)
      file = upload!(owner, image!(tmp, "photo.jpg"), "photo.jpg")

      %{n: n, tmp: tmp, owner: owner, scope: Scope.for_user(owner), photo: file}
    else
      {:ok, skip: true}
    end
  end

  defp imagemagick? do
    match?({_, 0}, System.cmd("identify", ["-version"], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  defp user!(name, n) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{name}-imgedit-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  # 60x40: left half red, right half blue.
  defp image!(dir, name, extra \\ []) do
    path = Path.join(dir, name)

    {_, 0} =
      System.cmd(
        "convert",
        ["-size", "30x40", "xc:red", "-size", "30x40", "xc:blue", "+append"] ++
          extra ++ [path],
        stderr_to_stdout: true
      )

    path
  end

  defp upload!(user, path, name) do
    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
    ext = name |> Path.extname() |> String.trim_leading(".")

    file =
      case Storage.store_file_in_buckets(path, "image", user.uuid, sha, ext, name) do
        {:ok, file} -> file
        {:ok, file, _} -> file
      end

    # Dimensions and variants, as the upload's own job would.
    :ok =
      ProcessFileJob.perform(%Oban.Job{
        args: %{"file_uuid" => file.uuid, "filename" => name}
      })

    Storage.get_file(file.uuid)
  end

  defp reload(file), do: Storage.get_file(file.uuid)

  defp edit_jobs do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == @job_worker and j.state == "available",
        order_by: j.id
      )
    )
  end

  # Runs every queued edit job once, like a queue would.
  defp drain do
    for job <- edit_jobs() do
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "completed"])
      ApplyImageEditJob.perform(%{job | attempt: 1})
    end
  end

  defp edit!(file, params, ctx) do
    assert {:ok, pending} = ImageEditing.edit(file, params, scope: ctx.scope)
    assert pending.edit_state == "pending"
    assert [:ok] = drain()
    reload(file)
  end

  defp keys(uuid) do
    uuid
    |> Storage.list_file_instances()
    |> Map.new(&{&1.variant_name, &1.file_name})
  end

  defp exists?(key), do: Manager.file_exists?(key)

  defp object_sha256(key) do
    tmp = Path.join(System.tmp_dir!(), "pk_edit_sha_#{System.unique_integer([:positive])}")
    {:ok, _} = Manager.retrieve_file(key, destination_path: tmp)
    sha = :sha256 |> :crypto.hash(File.read!(tmp)) |> Base.encode16(case: :lower)
    File.rm(tmp)
    sha
  end

  defp key_lengths(keys),
    do: Map.new(keys, fn {variant, key} -> {variant, String.length(key)} end)

  defp unedited_keys?(keys), do: Enum.all?(Map.values(keys), &ApplyImageEditJob.unedited_key?/1)

  defp original_size(file) do
    %{file_name: key} = Storage.get_file_instance_by_name(file.uuid, "original")
    tmp = Path.join(System.tmp_dir!(), "pk_edit_probe_#{System.unique_integer([:positive])}")
    {:ok, _} = Manager.retrieve_file(key, destination_path: tmp)
    {out, 0} = System.cmd("identify", ["-format", "%w %h", tmp])
    File.rm(tmp)
    out |> String.split() |> Enum.map(&String.to_integer/1)
  end

  describe "saving an edit" do
    test "keeps the uuid, serves the edit, and hides the unedited original", ctx do
      before_keys = keys(ctx.photo.uuid)
      assert map_size(before_keys) > 1, "the upload has variants to move"

      file = edit!(ctx.photo, %{"rotate" => 90}, ctx)

      assert file.edit_state == nil
      assert file.edit_revision == 1
      assert original_size(file) == [40, 60]
      assert {file.width, file.height} == {40, 60}
      refute file.file_checksum == ctx.photo.file_checksum

      backup = ImageEditing.backup(file)
      assert backup.system_managed
      assert backup.parent_file_uuid == file.uuid
      assert backup.file_checksum == ctx.photo.file_checksum
      backup_keys = keys(backup.uuid)
      assert Map.keys(backup_keys) == Map.keys(before_keys), "every unedited row moved"
      assert unedited_keys?(backup_keys), "at private copies, not the served keys"
      assert Enum.all?(Map.values(backup_keys), &exists?/1)
      assert object_sha256(backup_keys["original"]) == ctx.photo.file_checksum

      after_keys = keys(file.uuid)
      assert Map.keys(after_keys) |> Enum.sort() == Map.keys(before_keys) |> Enum.sort()

      assert MapSet.disjoint?(
               MapSet.new(Map.values(after_keys)),
               MapSet.new(Map.values(before_keys))
             )

      assert Enum.all?(Map.values(after_keys), &exists?/1)
    end

    test "a second edit replaces the first one's objects, never the backup's", ctx do
      first = edit!(ctx.photo, %{"rotate" => 90}, ctx)
      first_keys = keys(first.uuid)
      backup_keys = keys(ImageEditing.backup(first).uuid)

      second = edit!(first, %{"flip_h" => true}, ctx)

      assert second.edit_revision == 2
      assert original_size(second) == [60, 40], "applied to the unedited original"
      assert ImageEditing.backup(second).uuid == ImageEditing.backup(first).uuid
      assert keys(ImageEditing.backup(second).uuid) == backup_keys
      assert Enum.all?(Map.values(backup_keys), &exists?/1)
      refute Enum.any?(Map.values(first_keys), &exists?/1)
    end

    test "an edit equal to the current one changes nothing", ctx do
      file = edit!(ctx.photo, %{"rotate" => 90}, ctx)

      assert {:ok, same} = ImageEditing.edit(file, %{rotate: "90"}, scope: ctx.scope)
      assert same.edit_revision == 1
      assert edit_jobs() == []
    end

    test "an edit that changes nothing reverts an edited image", ctx do
      file = edit!(ctx.photo, %{"rotate" => 90}, ctx)
      file = edit!(file, %{"rotate" => 0}, ctx)

      assert file.edits == nil
      assert ImageEditing.backup(file) == nil
      assert original_size(file) == [60, 40]
    end
  end

  describe "the unedited original" do
    test "revert brings it back and deletes the edited objects", ctx do
      unedited = keys(ctx.photo.uuid)
      edited = edit!(ctx.photo, %{"rotate" => 180}, ctx)
      backup = ImageEditing.backup(edited)
      backup_keys = keys(backup.uuid)
      edited_keys = keys(edited.uuid)

      assert {:ok, _} = ImageEditing.revert(edited, scope: ctx.scope)
      assert [:ok] = drain()
      file = reload(edited)

      assert file.edits == nil
      assert file.original_file_uuid == nil
      assert file.file_checksum == ctx.photo.file_checksum
      assert file.user_file_checksum == ctx.photo.user_file_checksum
      assert file.file_name == ctx.photo.file_name
      assert keys(file.uuid) == backup_keys
      assert Map.keys(keys(file.uuid)) == Map.keys(unedited)
      refute Storage.get_file(backup.uuid)
      refute Enum.any?(Map.values(edited_keys), &exists?/1)
      assert Enum.all?(Map.values(keys(file.uuid)), &exists?/1)
      assert {:error, :not_edited} = ImageEditing.revert(file, scope: ctx.scope)
    end

    # A revert hands the backup's `unedited_…` keys back to the file, so the
    # next first edit copies from them. Stacking the prefix grew every key by
    # 42 characters per cycle until the swap overflowed varchar(255).
    test "edit-after-revert cycles do not grow the backup's keys", ctx do
      first = edit!(ctx.photo, %{"rotate" => 180}, ctx)
      lengths = first |> ImageEditing.backup() |> Map.fetch!(:uuid) |> keys() |> key_lengths()

      cycled =
        Enum.reduce(1..3, first, fn _, file ->
          assert {:ok, _} = ImageEditing.revert(file, scope: ctx.scope)
          assert [:ok] = drain()
          edit!(reload(file), %{"rotate" => 90}, ctx)
        end)

      backup_keys = cycled |> ImageEditing.backup() |> Map.fetch!(:uuid) |> keys()

      assert unedited_keys?(backup_keys)
      assert key_lengths(backup_keys) == lengths
    end

    test "never stays at the keys it was served under", ctx do
      # A public bucket hands those keys out as plain bucket URLs: a redaction
      # that left the bytes there would still be one saved link away.
      served = keys(ctx.photo.uuid)

      edited =
        edit!(
          ctx.photo,
          %{"redact" => [%{"x" => 0, "y" => 0, "w" => 50, "h" => 100, "style" => "fill"}]},
          ctx
        )

      refute Enum.any?(Map.values(served), &exists?/1)
      assert unedited_keys?(keys(ImageEditing.backup(edited).uuid))

      # Locations follow the rows.
      backup_original =
        Storage.get_file_instance_by_name(ImageEditing.backup(edited).uuid, "original")

      assert Enum.all?(
               Repo.all(
                 from(l in Storage.FileLocation,
                   where: l.file_instance_uuid == ^backup_original.uuid
                 )
               ),
               &(&1.path == backup_original.file_name)
             )

      # Reverted and edited again: the rows were served again meanwhile.
      assert {:ok, _} = ImageEditing.revert(edited, scope: ctx.scope)
      assert [:ok] = drain()
      served_again = keys(ctx.photo.uuid)

      again = edit!(reload(ctx.photo), %{"rotate" => 90}, ctx)

      refute Enum.any?(Map.values(served_again), &exists?/1)
      assert unedited_keys?(keys(ImageEditing.backup(again).uuid))
    end

    test "a backup still at its served keys moves to private copies on the next edit", ctx do
      edited = edit!(ctx.photo, %{"rotate" => 90}, ctx)
      backup = ImageEditing.backup(edited)
      original = Storage.get_file_instance_by_name(backup.uuid, "original")

      # A backup made before the copies existed: its original at a served key.
      served_key = Path.join(Path.dirname(original.file_name), "legacy_original.jpg")
      tmp = Path.join(ctx.tmp, "legacy.jpg")
      {:ok, _} = Manager.retrieve_file(original.file_name, destination_path: tmp)
      {:ok, _} = Manager.store_file(tmp, path_prefix: served_key)

      Repo.update_all(from(fi in Storage.FileInstance, where: fi.uuid == ^original.uuid),
        set: [file_name: served_key]
      )

      Repo.update_all(
        from(l in Storage.FileLocation, where: l.file_instance_uuid == ^original.uuid),
        set: [path: served_key]
      )

      again = edit!(edited, %{"rotate" => 180}, ctx)
      moved = Storage.get_file_instance_by_name(ImageEditing.backup(again).uuid, "original")

      assert ApplyImageEditJob.unedited_key?(moved.file_name)
      assert object_sha256(moved.file_name) == ctx.photo.file_checksum
      refute exists?(served_key)
    end

    test "bytes another file still references stay put", ctx do
      other = user!("sharer", ctx.n)
      shared = upload!(other, image!(ctx.tmp, "photo.jpg"), "theirs.jpg")
      shared_keys = keys(shared.uuid)

      _edited = edit!(ctx.photo, %{"rotate" => 90}, ctx)

      # Their own copy of the bytes is theirs to serve; only this file's
      # references moved.
      assert Enum.all?(Map.values(keys(reload(shared).uuid)), &exists?/1)
      assert keys(reload(shared).uuid) == shared_keys
    end

    test "deleting it bakes the edit in", ctx do
      unedited = keys(ctx.photo.uuid)
      edited = edit!(ctx.photo, %{"rotate" => 90}, ctx)
      backup = ImageEditing.backup(edited)

      assert {:ok, file} = ImageEditing.delete_unedited_original(edited, scope: ctx.scope)

      assert file.edits == nil
      refute ImageEditing.edited?(file)
      refute Storage.get_file(backup.uuid)
      refute Enum.any?(Map.values(unedited), &exists?/1)
      assert original_size(file) == [40, 60]
      assert Enum.all?(Map.values(keys(file.uuid)), &exists?/1)
    end

    test "a stale revision cannot delete it", ctx do
      edited = edit!(ctx.photo, %{"rotate" => 90}, ctx)
      _newer = edit!(edited, %{"rotate" => 270}, ctx)

      assert {:error, :edit_changed} =
               ImageEditing.delete_unedited_original(edited, scope: ctx.scope)

      assert ImageEditing.backup(reload(edited))
    end

    test "is not kept at all in replace-original mode", ctx do
      {:ok, _} = Settings.update_setting(ImageEditing.mode_setting(), "replace_original")
      unedited = keys(ctx.photo.uuid)

      file = edit!(ctx.photo, %{"rotate" => 90}, ctx)

      assert ImageEditing.mode() == "replace_original"
      assert file.edits == nil
      assert ImageEditing.backup(file) == nil
      assert Storage.list_system_children(file.uuid) == []
      refute Enum.any?(Map.values(unedited), &exists?/1)
      assert original_size(file) == [40, 60]
    end

    test "is never an upload's dedup target", ctx do
      edited = edit!(ctx.photo, %{"rotate" => 90}, ctx)
      backup = ImageEditing.backup(edited)
      same_bytes = image!(ctx.tmp, "again.jpg")

      again = upload!(ctx.owner, same_bytes, "again.jpg")
      refute again.uuid in [edited.uuid, backup.uuid]

      other = upload!(user!("other", ctx.n), same_bytes, "theirs.jpg")
      refute other.uuid in [edited.uuid, backup.uuid]
      refute other.file_name == ImageEditing.backup_name(), "not a clone of the hidden backup"
    end

    test "goes with its file", ctx do
      edited = edit!(ctx.photo, %{"rotate" => 90}, ctx)
      backup = ImageEditing.backup(edited)
      all_keys = Map.values(keys(backup.uuid)) ++ Map.values(keys(edited.uuid))

      assert {:ok, _} = Storage.delete_file_completely(edited)

      refute Storage.get_file(backup.uuid)
      refute Enum.any?(all_keys, &exists?/1)
    end
  end

  describe "overlapping runs" do
    # A fresh install's Default set carries the smart squares (V213);
    # this starts from a set with no subject crop.
    setup do
      Repo.delete_all(
        from d in PhoenixKit.Modules.Storage.Dimension, where: d.crop_mode == "focus"
      )

      :ok
    end

    test "changing a manual point invalidates the crop and gives it its own object", ctx do
      {:ok, dimension} =
        Storage.create_dimension(%{
          name: "focus_square",
          applies_to: "image",
          width: 20,
          height: 20,
          maintain_aspect_ratio: false,
          crop_mode: "focus",
          format: "png",
          quality: 85
        })

      assert {:ok, _} = FocalPoint.put(ctx.photo, 0.0, 0.5, "manual")
      assert {:ok, left} = VariantGenerator.generate_variant(reload(ctx.photo), dimension)
      left_sha = object_sha256(left.file_name)

      assert {:ok, _} = FocalPoint.put(ctx.photo, 1.0, 0.5, "manual")
      assert Storage.get_file_instance(left.uuid).spec_hash == "focal_changed"
      assert reload(ctx.photo).placed_variant_revision == 0
      assert {:ok, right} = VariantGenerator.generate_variant(reload(ctx.photo), dimension)

      refute left.file_name == right.file_name
      refute left_sha == object_sha256(right.file_name)
      assert :ok = FocalPoint.clear(ctx.photo)
      assert Storage.get_file_instance(right.uuid).spec_hash == "focal_changed"
    end

    test "a render for a superseded revision is thrown away", ctx do
      assert {:ok, pending} = ImageEditing.edit(ctx.photo, %{"rotate" => 90}, scope: ctx.scope)
      assert {:ok, {:render, rendered} = prepared} = ApplyImageEditJob.prepare(pending)
      assert exists?(rendered.key)

      assert {:ok, newer} = ImageEditing.edit(pending, %{"rotate" => 180}, scope: ctx.scope)
      assert newer.edit_revision == pending.edit_revision + 1

      assert {:superseded, ^prepared} =
               ApplyImageEditJob.publish(pending.uuid, pending.edit_revision, prepared)

      assert reload(pending).file_checksum == ctx.photo.file_checksum
    end

    test "a render whose object was deleted meanwhile is not published", ctx do
      assert {:ok, pending} = ImageEditing.edit(ctx.photo, %{"rotate" => 90}, scope: ctx.scope)
      assert {:ok, {:render, rendered} = prepared} = ApplyImageEditJob.prepare(pending)

      # A deletion of the same (content-addressed) key, finishing between the
      # store and the publish.
      :ok = Manager.delete_file(rendered.key)

      assert {:error, :rendered_missing} =
               ApplyImageEditJob.publish(pending.uuid, pending.edit_revision, prepared)

      assert reload(pending).file_checksum == ctx.photo.file_checksum
      assert ImageEditing.backup(reload(pending)) == nil
    end

    test "a variant made from another original is not recorded", ctx do
      thumb = image!(ctx.tmp, "thumb.png")
      before = keys(ctx.photo.uuid)

      assert {:error, :stale_source} =
               VariantGenerator.store_prepared_variant(
                 ctx.photo,
                 "thumbnail_annotated",
                 thumb,
                 "png",
                 "image/png",
                 source_key: "#{ctx.photo.file_path}/replaced_original.jpg"
               )

      assert keys(ctx.photo.uuid) == before

      %{file_name: source} = Storage.get_file_instance_by_name(ctx.photo.uuid, "original")

      assert {:ok, _} =
               VariantGenerator.store_prepared_variant(
                 ctx.photo,
                 "thumbnail_annotated",
                 image!(ctx.tmp, "thumb2.png"),
                 "png",
                 "image/png",
                 source_key: source
               )
    end

    test "an edit forgets the old focal point and a revert restores it", ctx do
      assert {:ok, _} = FocalPoint.put(ctx.photo, 0.8, 0.2, "manual")
      edited = edit!(ctx.photo, %{"rotate" => 90}, ctx)

      assert FocalPoint.get(reload(edited)) == nil
      assert {:ok, _} = FocalPoint.put(edited, 0.2, 0.8, "auto")
      assert {:ok, _} = ImageEditing.revert(edited, scope: ctx.scope)
      assert [:ok] = drain()

      assert FocalPoint.get(reload(edited)) == {{0.8, 0.2}, "manual"}
    end

    test "dimensions read from a replaced original are not recorded", ctx do
      %{file_name: source} = Storage.get_file_instance_by_name(ctx.photo.uuid, "original")
      edited = edit!(ctx.photo, %{"rotate" => 90}, ctx)
      bogus = %{width: 1, height: 1}

      # Started before the edit: the old checksum.
      assert :ok = ProcessFileJob.update_file_with_metadata(ctx.photo, source, bogus)
      # Read the edited row, but the bytes of the old original.
      assert :ok = ProcessFileJob.update_file_with_metadata(edited, source, bogus)
      assert {reload(edited).width, reload(edited).height} == {40, 60}

      %{file_name: current} = Storage.get_file_instance_by_name(edited.uuid, "original")
      assert :ok = ProcessFileJob.update_file_with_metadata(edited, current, bogus)
      assert {reload(edited).width, reload(edited).height} == {1, 1}
    end

    test "every save gets a run, even while one is executing" do
      states = ApplyImageEditJob.__opts__()[:unique][:states]

      refute :executing in states,
             "a save landing as a run finishes would be merged into it and never rendered"

      assert :available in states
      assert :scheduled in states
    end

    test "publishing a revision twice changes nothing", ctx do
      file = edit!(ctx.photo, %{"rotate" => 90}, ctx)
      published = keys(file.uuid)
      backup = ImageEditing.backup(file)
      original = Storage.get_file_instance_by_name(file.uuid, "original")

      # A second run for the same revision (it overlapped the first).
      Repo.update_all(from(f in Storage.File, where: f.uuid == ^file.uuid),
        set: [edit_state: "pending"]
      )

      {:ok, _} =
        %{"file_uuid" => file.uuid, "mode" => "apply"}
        |> ApplyImageEditJob.new()
        |> Oban.insert()

      assert [:ok] = drain()
      again = reload(file)

      assert again.edit_state == nil
      assert keys(file.uuid) == published
      assert Storage.get_file_instance_by_name(file.uuid, "original").uuid == original.uuid
      assert ImageEditing.backup(again).uuid == backup.uuid
      assert Enum.all?(Map.values(published), &exists?/1)
    end

    test "a run with nothing pending does nothing", ctx do
      file = edit!(ctx.photo, %{"rotate" => 90}, ctx)
      published = keys(file.uuid)

      assert :ok =
               ApplyImageEditJob.perform(%Oban.Job{
                 args: %{"file_uuid" => file.uuid, "mode" => "apply"},
                 attempt: 1,
                 max_attempts: 3
               })

      assert keys(file.uuid) == published
    end

    test "a variant cut from a replaced original is not published", ctx do
      stale = ctx.photo
      edited = edit!(ctx.photo, %{"rotate" => 90}, ctx)
      published = keys(edited.uuid)
      backup_keys = keys(ImageEditing.backup(edited).uuid)

      # A run that read the file before the edit: its variants are named after
      # the old checksum, and cut from whatever the original is now.
      _ = VariantGenerator.generate_variants(stale)

      assert keys(edited.uuid) == published
      assert keys(ImageEditing.backup(edited).uuid) == backup_keys
      assert Enum.all?(Map.values(published) ++ Map.values(backup_keys), &exists?/1)
    end
  end

  describe "failures" do
    test "an unreadable original fails the edit, which stays a placeholder until retried", ctx do
      %{file_name: key} = Storage.get_file_instance_by_name(ctx.photo.uuid, "original")
      garbage = Path.join(ctx.tmp, "garbage")
      File.write!(garbage, "not an image")
      {:ok, _} = Manager.store_file(garbage, path_prefix: key)

      assert {:ok, _} = ImageEditing.edit(ctx.photo, %{"rotate" => 90}, scope: ctx.scope)
      assert [{:cancel, {:unreadable, _}}] = drain()

      failed = reload(ctx.photo)
      assert failed.edit_state == "failed"
      assert ImageEditing.edit_in_progress?(failed)
      assert keys(failed.uuid) |> Map.values() |> Enum.all?(&exists?/1)

      assert {:ok, retried} = ImageEditing.retry(failed, scope: ctx.scope)
      assert retried.edit_state == "pending"
      assert retried.edit_revision == failed.edit_revision + 1
      assert [_] = edit_jobs()
    end

    test "a retry from a stale view re-renders the saved edit, not the one it showed", ctx do
      assert {:ok, first} = ImageEditing.edit(ctx.photo, %{"rotate" => 90}, scope: ctx.scope)

      Repo.update_all(from(f in Storage.File, where: f.uuid == ^first.uuid),
        set: [edit_state: "failed"]
      )

      stale = reload(ctx.photo)

      # Another tab saves a different edit meanwhile (a redaction, say).
      assert {:ok, newer} = ImageEditing.edit(stale, %{"rotate" => 180}, scope: ctx.scope)

      assert {:ok, retried} = ImageEditing.retry(stale, scope: ctx.scope)
      assert retried.edits == newer.edits
      refute retried.edits == stale.edits
    end

    test "a run that crashes on its last attempt leaves the edit failed, not pending", ctx do
      # An edit no render can take (stored behind normalize/1's back).
      Repo.update_all(from(f in Storage.File, where: f.uuid == ^ctx.photo.uuid),
        set: [edits: %{"crop" => "everything"}, edit_state: "pending", edit_revision: 1]
      )

      job = %Oban.Job{
        args: %{"file_uuid" => ctx.photo.uuid, "mode" => "apply"},
        attempt: 1,
        max_attempts: 3
      }

      assert_raise FunctionClauseError, fn -> ApplyImageEditJob.perform(job) end
      assert reload(ctx.photo).edit_state == "pending", "a retry is still coming"

      assert_raise FunctionClauseError, fn -> ApplyImageEditJob.perform(%{job | attempt: 3}) end
      assert reload(ctx.photo).edit_state == "failed"
    end

    defp discard_event(state, worker, job) do
      ApplyImageEditJob.handle_oban_exception(
        [:oban, :job, :exception],
        %{},
        %{
          state: state,
          reason: %Oban.TimeoutError{message: "timed out"},
          job: %Oban.Job{id: job.id, worker: worker, args: job.args}
        },
        nil
      )
    end

    defp start_executing!(job) do
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])
    end

    test "a run Oban discards without an answer (a timeout) leaves the edit failed", ctx do
      assert {:ok, pending} = ImageEditing.edit(ctx.photo, %{"rotate" => 90}, scope: ctx.scope)
      [job] = edit_jobs()
      start_executing!(job)

      event = fn state, worker -> discard_event(state, worker, job) end

      # A retry is still coming, or it is some other worker's job.
      assert :ok = event.(:failure, @job_worker)
      assert :ok = event.(:discard, "Some.OtherWorker")
      assert reload(pending).edit_state == "pending"

      assert :ok = event.(:discard, @job_worker)
      assert reload(pending).edit_state == "failed"

      assert :ok = ApplyImageEditJob.attach_telemetry()

      handler = &ApplyImageEditJob.handle_oban_exception/4

      assert Enum.any?(
               :telemetry.list_handlers([:oban, :job, :exception]),
               fn %{function: function} -> function == handler end
             )
    end

    test "a discarded run leaves a save that landed meanwhile to its own run", ctx do
      assert {:ok, _} = ImageEditing.edit(ctx.photo, %{"rotate" => 90}, scope: ctx.scope)
      [first] = edit_jobs()
      start_executing!(first)

      # Uniqueness ignores an executing run, so this save gets a run of its own.
      assert {:ok, newer} = ImageEditing.edit(ctx.photo, %{"rotate" => 180}, scope: ctx.scope)
      assert [_second] = edit_jobs()

      assert :ok = discard_event(:discard, @job_worker, first)

      assert %{edit_state: "pending", edit_revision: revision} = reload(ctx.photo)
      assert revision == newer.edit_revision
    end

    test "a file deleted meanwhile is a tidy error, not a crash", ctx do
      stale = ctx.photo
      {:ok, _} = Storage.delete_file_completely(ctx.photo)

      assert {:error, :not_found} = ImageEditing.edit(stale, %{"rotate" => 90}, scope: ctx.scope)
    end

    test "only a failed or pending edit can be retried", ctx do
      assert {:error, :nothing_to_retry} = ImageEditing.retry(ctx.photo, scope: ctx.scope)
    end

    test "the uploader's extension never picks ImageMagick's coder", ctx do
      # `.mvg` / `.msl` select coders with no magic bytes; the stored ext is
      # the uploader's filename, so neither temp copy may carry it.
      {:ok, rendered} = ApplyImageEditJob.render(%{ctx.photo | ext: "mvg"}, %{"rotate" => 90})

      try do
        assert Path.extname(rendered.path) == ".jpg"
      after
        File.rm(rendered.path)
      end

      assert ApplyImageEditJob.output_extension("image/png") == ".png"
      assert ApplyImageEditJob.output_extension("image/svg+xml") == ""
      assert ApplyImageEditJob.output_extension(nil) == ""
    end

    test "edited bytes the owner already has as another file still publish", ctx do
      edit = %{"rotate" => 90}
      {:ok, rendered} = ApplyImageEditJob.render(ctx.photo, edit)
      twin = upload!(ctx.owner, rendered.path, "twin.jpg")

      file = edit!(ctx.photo, edit, ctx)

      assert file.file_checksum == twin.file_checksum
      assert file.user_file_checksum == "edited:#{file.uuid}"
      assert reload(twin).user_file_checksum != file.user_file_checksum
    end
  end

  describe "who may edit what" do
    defp scope_of(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

    test "the owner, an Owner/Admin and a media permission holder; nobody else", ctx do
      stranger = user!("stranger", ctx.n)

      admin = user!("admin", ctx.n)
      {:ok, _} = Roles.assign_role(admin, "Admin")

      {:ok, librarian} = Roles.create_role(%{name: "Librarian#{ctx.n}"})
      {:ok, _} = Permissions.grant_permission(librarian.uuid, "media")
      {:ok, _} = Permissions.grant_permission(librarian.uuid, "media.view_all")
      holder = user!("holder", ctx.n)
      {:ok, _} = Roles.assign_role(holder, librarian.name)

      assert ImageEditing.can_edit?(ctx.photo, ctx.scope)
      assert ImageEditing.can_edit?(ctx.photo, scope_of(admin))
      assert ImageEditing.can_edit?(ctx.photo, scope_of(holder))
      assert ImageEditing.can_edit?(ctx.photo, system: true)
      refute ImageEditing.can_edit?(ctx.photo, scope_of(stranger))
      refute ImageEditing.can_edit?(ctx.photo, nil)
      refute ImageEditing.can_edit?(ctx.photo, [])

      for call <- [
            &ImageEditing.edit(&1, %{"rotate" => 90}, scope: &2),
            &ImageEditing.save_copy(&1, %{"rotate" => 90}, scope: &2),
            &ImageEditing.revert(&1, scope: &2),
            &ImageEditing.retry(&1, scope: &2),
            &ImageEditing.delete_unedited_original(&1, scope: &2)
          ] do
        assert {:error, :forbidden} = call.(ctx.photo, scope_of(stranger))
      end

      assert edit_jobs() == []
    end

    test "only active, user-owned still images in a writable format", ctx do
      assert ImageEditing.editable?(ctx.photo)

      refute ImageEditing.editable?(%{ctx.photo | mime_type: "image/gif"})
      refute ImageEditing.editable?(%{ctx.photo | status: "trashed"})
      refute ImageEditing.editable?(%{ctx.photo | file_type: "document"})

      backup = ImageEditing.backup(edit!(ctx.photo, %{"rotate" => 90}, ctx))
      refute ImageEditing.editable?(backup)

      assert {:error, :not_editable} =
               ImageEditing.edit(backup, %{"rotate" => 90}, scope: ctx.scope)
    end

    test "annotations drawn on an edited image keep its geometry", ctx do
      turned = edit!(ctx.photo, %{"rotate" => 90}, ctx)

      {:ok, _} =
        Annotations.create(%{
          file_uuid: turned.uuid,
          kind: "rectangle",
          geometry: %{"x" => 0.1, "y" => 0.1, "w" => 0.2, "h" => 0.2}
        })

      assert {:ok, _} =
               ImageEditing.edit(turned, %{"rotate" => 90, "contrast" => 15}, scope: ctx.scope)

      assert [:ok] = drain()
      turned = reload(turned)

      assert {:error, {:annotated, 1}} =
               ImageEditing.edit(turned, %{"contrast" => 15}, scope: ctx.scope)

      assert {:error, {:annotated, 1}} = ImageEditing.revert(turned, scope: ctx.scope)
      assert edit_jobs() == []
    end

    test "an annotated image refuses edits that move pixels", ctx do
      {:ok, _} =
        Annotations.create(%{
          file_uuid: ctx.photo.uuid,
          kind: "rectangle",
          geometry: %{"x" => 0.1, "y" => 0.1, "w" => 0.2, "h" => 0.2}
        })

      assert {:error, {:annotated, 1}} =
               ImageEditing.edit(ctx.photo, %{"rotate" => 90}, scope: ctx.scope)

      assert {:error, {:annotated, 1}} =
               ImageEditing.edit(
                 ctx.photo,
                 %{"crop" => %{"x" => 10, "y" => 0, "w" => 50, "h" => 100}},
                 scope: ctx.scope
               )

      assert {:ok, _} =
               ImageEditing.edit(
                 ctx.photo,
                 %{
                   "brightness" => 10,
                   "redact" => [%{"x" => 0, "y" => 0, "w" => 20, "h" => 20, "style" => "fill"}]
                 },
                 scope: ctx.scope
               )
    end

    test "a geometric edit clears avatar crops made on the old pixels", ctx do
      crop = %{"x" => 0.1, "y" => 0.1, "w" => 0.5, "h" => 0.5}

      {:ok, _} =
        Auth.update_user_custom_fields(ctx.owner, %{
          "avatar_file_uuid" => ctx.photo.uuid,
          "avatar_crop" => crop
        })

      file = edit!(ctx.photo, %{"brightness" => 20}, ctx)
      assert Repo.get!(Auth.User, ctx.owner.uuid).custom_fields["avatar_crop"] == crop

      file = edit!(file, %{"rotate" => 90}, ctx)
      fields = Repo.get!(Auth.User, ctx.owner.uuid).custom_fields
      assert fields["avatar_crop"] == nil
      assert fields["avatar_file_uuid"] == ctx.photo.uuid

      # A crop made on the turned image survives a change that keeps it turned…
      {:ok, _} =
        Auth.update_user_custom_fields(Repo.get!(Auth.User, ctx.owner.uuid), %{
          "avatar_file_uuid" => ctx.photo.uuid,
          "avatar_crop" => crop
        })

      file = edit!(file, %{"rotate" => 90, "brightness" => 30}, ctx)
      assert Repo.get!(Auth.User, ctx.owner.uuid).custom_fields["avatar_crop"] == crop

      # …and goes with a revert, which turns it back.
      assert {:ok, _} = ImageEditing.revert(file, scope: ctx.scope)
      assert [:ok] = drain()
      assert Repo.get!(Auth.User, ctx.owner.uuid).custom_fields["avatar_crop"] == nil
    end
  end

  describe "dimensions" do
    # A JPEG stored sideways with an EXIF orientation of 6 ("turn 90° to
    # view"): 60x40 pixels that display as 40x60. See image_edit_render_test.
    defp sideways_jpeg(dir) do
      plain = image!(dir, "plain.jpg")
      <<0xFF, 0xD8, rest::binary>> = File.read!(plain)

      tiff =
        "MM" <>
          <<42::16, 8::32, 1::16>> <> <<0x0112::16, 3::16, 1::32, 6::16, 0::16>> <> <<0::32>>

      payload = "Exif" <> <<0, 0>> <> tiff
      app1 = <<0xFF, 0xE1, byte_size(payload) + 2::16>> <> payload
      path = Path.join(dir, "sideways.jpg")
      File.write!(path, <<0xFF, 0xD8>> <> app1 <> rest)
      path
    end

    test "are recorded as displayed, after the EXIF orientation", ctx do
      file = upload!(ctx.owner, sideways_jpeg(ctx.tmp), "sideways.jpg")

      assert {file.width, file.height} == {40, 60}

      # And an edit's frame is the same upright image.
      edited = edit!(file, %{"crop" => %{"x" => 0, "y" => 0, "w" => 100, "h" => 50}}, ctx)
      assert {edited.width, edited.height} == {40, 30}
      assert original_size(edited) == [40, 30]
    end
  end

  describe "save as copy" do
    test "renders a new, linked file and leaves the source alone", ctx do
      source_keys = keys(ctx.photo.uuid)

      assert {:ok, _job} =
               ImageEditing.save_copy(ctx.photo, %{"rotate" => 90}, scope: ctx.scope)

      assert [:ok] = drain()

      [copy] =
        Repo.all(from(f in Storage.File, where: f.edited_from_uuid == ^ctx.photo.uuid))

      assert copy.user_uuid == ctx.owner.uuid
      assert copy.folder_uuid == ctx.photo.folder_uuid
      assert copy.original_file_name == "photo (edited).jpg"
      refute copy.file_checksum == ctx.photo.file_checksum
      assert original_size(copy) == [40, 60]

      source = reload(ctx.photo)
      assert source.edits == nil
      assert source.edit_revision == 0
      assert keys(source.uuid) == source_keys
    end

    test "a copy of nothing is refused", ctx do
      assert {:error, :no_edit} = ImageEditing.save_copy(ctx.photo, %{}, scope: ctx.scope)
      assert edit_jobs() == []
    end
  end
end
