defmodule PhoenixKit.Modules.Storage.ApplyImageEditJob do
  @moduledoc """
  Renders a saved image edit and swaps it in (see
  `PhoenixKit.Modules.Storage.ImageEditing`).

  `"apply"` (one per file at a time): renders `file.edits` from the unedited
  original, stores the result, and in one transaction — the file row locked,
  its storage directory locked — replaces the file's original with it. On a
  first edit the file's existing instance rows move to a new hidden backup;
  on later edits the previous edit's rows are dropped. `edits: nil` reverts:
  the backup's rows move back and the backup goes. Then the variants are
  generated from the new original, and `edit_state` is cleared.

  Every save enqueues a run; runs that have not started yet are merged (the
  job is unique per file while waiting, not while executing — a save that
  lands as a run finishes must still get a run of its own). Two runs can
  therefore overlap, so every step checks `edit_revision`: a result for an
  older revision is thrown away and the run starts over with the current
  one, and publishing a revision that is already published changes nothing.
  After a few rounds a run snoozes, so a stream of saves cannot keep it busy
  forever. A render that fails for good leaves `edit_state: "failed"` (for
  that revision only) — the file keeps serving a placeholder rather than
  bytes the edit was meant to change.

  `"copy"`: renders `args["edits"]` into a brand-new file (same owner and
  folder, `edited_from_uuid` set).
  """

  @unique_states Oban.Job.states() -- [:executing, :completed, :cancelled, :discarded]
  @max_rounds 5

  use Oban.Worker,
    queue: :file_processing,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:file_uuid, :mode, :nonce], states: @unique_states]

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.FileLocation
  alias PhoenixKit.Modules.Storage.ImageEdit
  alias PhoenixKit.Modules.Storage.ImageEditing
  alias PhoenixKit.Modules.Storage.ImageProcessor
  alias PhoenixKit.Modules.Storage.Locations
  alias PhoenixKit.Modules.Storage.Manager
  alias PhoenixKit.Modules.Storage.VariantGenerator

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"file_uuid" => uuid, "mode" => "copy"} = args} = job) do
    case Storage.get_file(uuid) do
      nil -> {:cancel, :file_not_found}
      file -> copy(file, args["edits"]) |> finish_copy(job)
    end
  end

  def perform(%Oban.Job{args: %{"file_uuid" => uuid, "mode" => "apply"}} = job) do
    run_apply(uuid, job)
  rescue
    # A crash on the last attempt leaves no run behind: the file must not stay
    # "pending" (a placeholder) with nothing left to render it.
    error ->
      if final_attempt?(job), do: mark_current_failed(uuid, job, error)
      reraise error, __STACKTRACE__
  end

  defp run_apply(uuid, job) do
    case apply_edit(uuid, 0) do
      :ok ->
        :ok

      {:snooze, _} = snooze ->
        snooze

      {:cancel, :file_not_found} ->
        {:cancel, :file_not_found}

      {:cancel, revision, reason} ->
        mark_failed(uuid, revision, reason)
        {:cancel, reason}

      {:error, revision, reason} ->
        if final_attempt?(job), do: mark_failed(uuid, revision, reason)
        {:error, reason}
    end
  end

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt >= max

  @telemetry_handler "phoenix-kit-image-edit-discards"

  @doc false
  # A run Oban gave up on without `perform/1` returning — a timeout kills
  # the process, so neither the result handling nor the rescue above runs —
  # would leave the file "pending" with nothing left to render it. Oban
  # reports every discard; mark the edit failed from there. Attached once at
  # application start.
  def attach_telemetry do
    case :telemetry.attach(
           @telemetry_handler,
           [:oban, :job, :exception],
           &__MODULE__.handle_oban_exception/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_oban_exception(_event, _measurements, meta, _config) do
    case meta do
      %{
        state: :discard,
        job: %Oban.Job{worker: worker, args: %{"mode" => "apply", "file_uuid" => uuid}} = job
      } ->
        if worker == inspect(__MODULE__),
          do: mark_current_failed(uuid, job, Map.get(meta, :reason))

      _other ->
        :ok
    end

    :ok
  end

  # The run always works on the file's current revision — unless a save
  # landed while it ran: that save enqueued a run of its own (uniqueness
  # ignores an executing job), which owns the current revision now. Failing
  # it here would leave the newer save on the failed placeholder, and its
  # own run would find nothing pending and stop.
  defp mark_current_failed(uuid, job, error) do
    case Storage.get_file(uuid) do
      %StorageFile{edit_revision: revision} ->
        unless another_run?(uuid, job), do: mark_failed(uuid, revision, error)

      nil ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp another_run?(uuid, %Oban.Job{id: id}) do
    from(j in Oban.Job,
      where:
        j.worker == ^inspect(__MODULE__) and
          j.state in ["available", "scheduled", "retryable", "executing"] and
          fragment("?->>'file_uuid' = ?", j.args, ^uuid) and
          fragment("?->>'mode' = 'apply'", j.args)
    )
    |> then(fn query -> if id, do: where(query, [j], j.id != ^id), else: query end)
    |> repo().exists?(prefix: Application.get_env(:phoenix_kit, :prefix))
  end

  ## Apply

  defp apply_edit(_uuid, round) when round >= @max_rounds, do: {:snooze, 1}

  defp apply_edit(uuid, round) do
    case Storage.get_file(uuid) do
      nil -> {:cancel, :file_not_found}
      %StorageFile{edit_state: "pending"} = file -> apply_revision(file, round)
      # Nothing pending: already done, or failed and waiting for a retry.
      %StorageFile{} -> :ok
    end
  end

  defp apply_revision(file, round) do
    revision = file.edit_revision

    result =
      with {:ok, prepared} <- prepare(file) do
        case publish_or_discard(file.uuid, revision, prepared) do
          {:ok, outcome} ->
            release_unused_copies(prepared)
            after_publish(file.uuid, revision, outcome)

          {:superseded, prepared} ->
            discard_then(:superseded, prepared)

          other ->
            other
        end
      end

    case result do
      :ok -> :ok
      :superseded -> apply_edit(file.uuid, round + 1)
      {:cancel, reason} -> {:cancel, revision, reason}
      {:error, reason} -> {:error, revision, reason}
    end
  end

  # `publish/3` discards what `prepare/1` stored on every tuple it returns,
  # but a RAISE inside its transaction (an `update!`, a failed match, a lost
  # connection) unwinds past all of that. The render and the private copies of
  # the unedited bytes would stay in the bucket under keys no row points at —
  # out of reach of every later cleanup — and each retry would add a fresh
  # set. `discard/1` re-checks references under the directory lock, so it is
  # safe whatever the transaction got to before it rolled back.
  defp publish_or_discard(uuid, revision, prepared) do
    publish(uuid, revision, prepared)
  rescue
    error ->
      discard(prepared)
      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      discard(prepared)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @doc false
  # What the swap needs, computed outside any transaction (rendering is slow).
  def prepare(%StorageFile{edits: nil} = file) do
    case ImageEditing.backup(file) do
      nil -> {:ok, :nothing}
      backup -> {:ok, {:revert, backup}}
    end
  end

  def prepare(%StorageFile{} = file) do
    with {:ok, rendered} <- render(file, file.edits) do
      key = "#{file.file_path}/#{rendered.md5}_original.#{file.ext}"

      case Manager.store_file(rendered.path, [path_prefix: key] ++ where_the_original_is(file)) do
        {:ok, %{bucket_ids: bucket_ids}} ->
          File.rm(rendered.path)
          rendered = Map.merge(rendered, %{key: key, bucket_ids: bucket_ids, copies: %{}})

          case copy_unedited(file) do
            {:ok, copies} ->
              {:ok, {:render, %{rendered | copies: copies}}}

            {:error, reason} ->
              discard({:render, rendered})
              {:error, reason}
          end

        {:error, reason} ->
          File.rm(rendered.path)
          {:error, {:store_failed, reason}}
      end
    end
  end

  # The unedited original must not stay at the keys it was served under.
  # On a public bucket those keys were handed out as plain bucket URLs
  # (`Manager.get_file_access/1` redirects to them), so a redaction that
  # left the bytes there would still be one saved link away. The backup's
  # objects are therefore copied to fresh, unguessable keys before the swap;
  # the swap points the backup's rows at the copies and the old keys are
  # deleted once nothing references them.
  #
  # Which objects: all of the file's when this edit creates the backup, else
  # the backup's rows that still sit at a served key (a backup made before
  # this existed). Copying happens here, outside the transaction; the swap
  # checks every row it moves has its copy and starts over when one does not
  # (a variant generated in between).
  defp copy_unedited(file) do
    keys =
      case ImageEditing.backup(file) do
        nil ->
          ImageEditing.instance_keys([file.uuid])

        backup ->
          backup.uuid
          |> List.wrap()
          |> ImageEditing.instance_keys()
          |> Enum.reject(&unedited_key?/1)
      end

    keys
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn key, {:ok, copies} ->
      case copy_object(key) do
        {:ok, copy} ->
          {:cont, {:ok, Map.put(copies, key, copy)}}

        {:error, reason} ->
          Storage.delete_stored_objects(Enum.map(Map.values(copies), & &1.key))
          {:halt, {:error, {:copy_failed, key, reason}}}
      end
    end)
  end

  defp copy_object(key) do
    copy_key = unedited_key(key)
    temp = temp_path(Manager.temp_extension(key))

    try do
      with {:ok, _} <- Manager.retrieve_file(key, destination_path: temp),
           {:ok, %{bucket_ids: bucket_ids}} <-
             Manager.store_file(temp, [path_prefix: copy_key] ++ same_buckets_as(key)) do
        {:ok, %{key: copy_key, bucket_ids: bucket_ids}}
      end
    after
      File.rm(temp)
    end
  end

  # The edited bytes go where the picture is now, not to whatever buckets
  # the pool would pick today: the buckets its current original's key is
  # recorded in (V204). With nothing recorded, the usual selection.
  defp where_the_original_is(file) do
    case Storage.get_file_instance_by_name(file.uuid, "original") do
      %{file_name: key} when is_binary(key) -> same_buckets_as(key)
      _ -> []
    end
  end

  defp same_buckets_as(key) do
    case Locations.bucket_uuids(key) do
      [] -> []
      bucket_uuids -> [force_bucket_ids: bucket_uuids]
    end
  end

  @unedited_prefix "unedited_"

  # Same directory (the directory lock covers it), a name no upload,
  # variant or render produces, and 128 random bits nobody can guess.
  #
  # A prefix already on the name is REPLACED, not stacked. A revert hands the
  # backup's `unedited_…` keys back to the file, so the next first edit copies
  # from them; stacking added 42 characters per edit-after-revert cycle until
  # the key outgrew `file_instances.file_name` (varchar(255)), the swap raised,
  # and the file could never be edited again.
  @doc false
  def unedited_key(key) do
    token = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    Path.join(Path.dirname(key), "#{@unedited_prefix}#{token}_#{bare_basename(key)}")
  end

  defp bare_basename(key) do
    String.replace(Path.basename(key), ~r/^(?:#{@unedited_prefix}[0-9a-f]{32}_)+/, "")
  end

  @doc false
  def unedited_key?(key) when is_binary(key),
    do: String.starts_with?(Path.basename(key), @unedited_prefix)

  def unedited_key?(_key), do: false

  @doc false
  # Renders `edit` from the file's unedited original into a temp file.
  def render(%StorageFile{} = file, edit) do
    with %FileInstance{file_name: source_key} <- ImageEditing.source_instance(file),
         source = temp_path(Manager.temp_extension("source." <> to_string(file.ext))),
         {:ok, _} <- Manager.retrieve_file(source_key, destination_path: source) do
      try do
        render_from(source, file, edit)
      after
        File.rm(source)
      end
    else
      nil -> {:cancel, :original_missing}
      {:error, reason} -> {:error, {:retrieve_failed, reason}}
    end
  end

  defp render_from(source, file, edit) do
    output = temp_path(output_extension(file.mime_type))

    with {:ok, {w, h, frames}} <- oriented_info(source),
         :ok <- if(frames > 1, do: {:cancel, :animated}, else: :ok),
         :ok <- run_render(source, output, edit, {w, h}),
         {:ok, {ow, oh, _}} <- oriented_info(output) do
      bytes = File.read!(output)

      {:ok,
       %{
         path: output,
         sha256: hex(:sha256, bytes),
         md5: hex(:md5, bytes),
         size: byte_size(bytes),
         width: ow,
         height: oh
       }}
    else
      {:cancel, _} = cancel ->
        File.rm(output)
        cancel

      {:error, reason} ->
        File.rm(output)
        {:error, {:render_failed, reason}}
    end
  end

  defp oriented_info(path) do
    case ImageProcessor.oriented_info(path) do
      {:ok, info} -> {:ok, info}
      # An unreadable source will not become readable on a retry.
      {:error, reason} -> {:cancel, {:unreadable, reason}}
    end
  end

  defp run_render(source, output, edit, size) do
    case ImageProcessor.render_edit(source, output, edit, size) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # The swap, all or nothing. `{:superseded, prepared}` when a newer save
  # arrived while this rendered.
  def publish(uuid, revision, prepared) do
    repo().transaction(fn ->
      file = ImageEditing.lock_file(uuid) || repo().rollback(:file_not_found)

      if file.edit_revision != revision or file.edit_state != "pending" do
        repo().rollback({:superseded, prepared})
      end

      backup = ImageEditing.backup(file)
      Storage.lock_storage_paths([file.file_path | if(backup, do: [backup.file_path], else: [])])

      case {prepared, backup} do
        {{:render, rendered}, _} -> swap_in(file, backup, rendered)
        {{:revert, _stale}, %StorageFile{}} -> swap_back(file, backup)
        # Nothing to revert (never edited, or the backup is already gone).
        _ -> {:published, file, [], {:nothing, false}}
      end
    end)
    |> case do
      {:ok, outcome} -> {:ok, outcome}
      {:error, {:superseded, _} = superseded} -> superseded
      {:error, :file_not_found} -> discard_then({:cancel, :file_not_found}, prepared)
      {:error, reason} -> discard_then({:error, reason}, prepared)
    end
  end

  defp discard_then(result, prepared) do
    discard(prepared)
    result
  end

  # A rendered object that never got published: delete it unless something
  # references it (an identical earlier render can share its key).
  defp discard({:render, %{key: key} = rendered}),
    do: Storage.delete_stored_objects([key | copy_keys(rendered)])

  defp discard(_), do: :ok

  # After a publish: the copies the swap did not use (the backup already had
  # them, or an overlapping run published first). A used copy is referenced
  # and stays.
  defp release_unused_copies({:render, rendered}),
    do: Storage.delete_stored_objects(copy_keys(rendered))

  defp release_unused_copies(_), do: :ok

  defp copy_keys(rendered),
    do: rendered |> Map.get(:copies, %{}) |> Map.values() |> Enum.map(& &1.key)

  # Already published (an overlapping run, or this run's own earlier
  # attempt): only the variants are still to be made.
  defp swap_in(%StorageFile{} = file, %StorageFile{} = backup, rendered)
       when file.file_checksum == rendered.sha256 do
    case Storage.get_file_instance_by_name(file.uuid, "original") do
      %FileInstance{file_name: key} when key == rendered.key ->
        {:published, file, [], {:rendered, false}}

      _ ->
        swap_in_new(file, backup, rendered)
    end
  end

  defp swap_in(file, backup, rendered), do: swap_in_new(file, backup, rendered)

  defp swap_in_new(file, backup, rendered) do
    backup_uuid = backup && backup.uuid

    # The owner may already have these exact bytes as another file; that
    # file keeps the checksum (an upload of them resolves to it), and this
    # one gets a value no upload can match.
    user_checksum =
      Storage.calculate_user_file_checksum(file.user_uuid, rendered.sha256, file.library_uuid)

    user_checksum =
      if duplicate?(file, backup_uuid, user_checksum),
        do: "edited:#{file.uuid}",
        else: user_checksum

    # Stored before the lock was taken; a deletion of the same bytes' key
    # (they are content-addressed) may have run since.
    unless Manager.file_exists?(rendered.key), do: repo().rollback(:rendered_missing)

    {backup, dropped_keys} =
      case backup do
        nil ->
          backup = create_backup!(file)
          {backup, move_to_copies!(backup, :all, rendered)}

        backup ->
          keys = ImageEditing.instance_keys([file.uuid])
          repo().delete_all(from(fi in FileInstance, where: fi.file_uuid == ^file.uuid))
          {backup, keys ++ move_to_copies!(backup, :served, rendered)}
      end

    previous = applied_edit(backup)
    backup = record_applied_edit!(backup, file.edits)

    {:ok, instance} =
      Storage.create_file_instance(%{
        variant_name: "original",
        file_name: rendered.key,
        mime_type: file.mime_type,
        ext: file.ext,
        checksum: rendered.sha256,
        size: rendered.size,
        width: rendered.width,
        height: rendered.height,
        processing_status: "completed",
        file_uuid: file.uuid
      })

    {:ok, _} =
      Storage.create_file_locations_for_instance(instance.uuid, rendered.bucket_ids, rendered.key)

    {:ok, file} =
      file
      |> Ecto.Changeset.change(
        file_checksum: rendered.sha256,
        user_file_checksum: user_checksum,
        file_name: "#{rendered.md5}.#{file.ext}",
        size: rendered.size,
        width: rendered.width,
        height: rendered.height,
        # The rotation is in the pixels now; a view rotation on top of it
        # would turn the image again.
        metadata: Map.delete(file.metadata || %{}, "rotation"),
        original_file_uuid: backup.uuid
      )
      |> repo().update()

    tile_keys = drop_tiles!(file, backup.uuid)

    {:published, file, Storage.unreferenced_keys(dropped_keys ++ tile_keys),
     rendered_outcome(previous, file.edits)}
  end

  defp rendered_outcome(previous, applied) do
    {:rendered, ImageEdit.geometry(previous) != ImageEdit.geometry(applied)}
  end

  # What the file's bytes currently show: recorded on the backup, which
  # lives exactly as long as there is an applied edit to compare against.
  defp applied_edit(backup), do: get_in(backup.metadata || %{}, ["applied_edit"])

  defp record_applied_edit!(backup, edit) do
    backup
    |> Ecto.Changeset.change(metadata: Map.put(backup.metadata || %{}, "applied_edit", edit))
    |> repo().update!()
  end

  defp swap_back(file, backup) do
    previous = applied_edit(backup)
    dropped_keys = ImageEditing.instance_keys([file.uuid])
    repo().delete_all(from(fi in FileInstance, where: fi.file_uuid == ^file.uuid))

    repo().update_all(
      from(fi in FileInstance, where: fi.file_uuid == ^backup.uuid),
      set: [file_uuid: file.uuid]
    )

    # The unedited content's checksum is the file's again — unless the owner
    # has since uploaded the same bytes as another file, which now holds it.
    user_checksum =
      Storage.calculate_user_file_checksum(
        file.user_uuid,
        backup.file_checksum,
        file.library_uuid
      )

    user_checksum =
      if duplicate?(file, backup.uuid, user_checksum),
        do: "reverted:#{file.uuid}",
        else: user_checksum

    rotation = get_in(backup.metadata || %{}, ["rotation"])

    metadata =
      if rotation,
        do: Map.put(file.metadata || %{}, "rotation", rotation),
        else: Map.delete(file.metadata || %{}, "rotation")

    tile_keys = drop_tiles!(file, backup.uuid)
    {:ok, _} = repo().delete(backup)

    {:ok, file} =
      file
      |> Ecto.Changeset.change(
        file_checksum: backup.file_checksum,
        user_file_checksum: user_checksum,
        file_name: (backup.metadata || %{})["file_name"] || file.file_name,
        size: backup.size,
        width: backup.width,
        height: backup.height,
        metadata: metadata,
        original_file_uuid: nil
      )
      |> repo().update()

    {:published, file, Storage.unreferenced_keys(dropped_keys ++ tile_keys),
     {:reverted, ImageEdit.geometry(previous) != %{}}}
  end

  # Points the backup's rows at the copies `prepare/1` made (see
  # `copy_unedited/1`) and returns the keys they left, for deletion once
  # unreferenced. `:all` for a backup this swap created (every row sat at a
  # served key); `:served` for an existing one. A row without a copy means
  # the rows changed since `prepare/1`: start over rather than leave it.
  defp move_to_copies!(backup, which, rendered) do
    from(fi in FileInstance, where: fi.file_uuid == ^backup.uuid)
    |> repo().all()
    |> Enum.reject(&(which == :served and unedited_key?(&1.file_name)))
    |> Enum.map(fn instance ->
      case Map.fetch(rendered.copies, instance.file_name) do
        {:ok, %{key: copy_key, bucket_ids: bucket_ids}} ->
          repo().delete_all(
            from(l in FileLocation, where: l.file_instance_uuid == ^instance.uuid)
          )

          instance |> Ecto.Changeset.change(file_name: copy_key) |> repo().update!()

          {:ok, _} =
            Storage.create_file_locations_for_instance(instance.uuid, bucket_ids, copy_key)

          instance.file_name

        :error ->
          repo().rollback({:superseded, {:render, rendered}})
      end
    end)
  end

  # The unedited original as a hidden child of `file`: the file's current
  # instance rows (and their locations) move to it. `move_to_copies!/3` then
  # points them at private copies of their bytes.
  defp create_backup!(file) do
    {:ok, backup} =
      %StorageFile{}
      |> StorageFile.changeset(%{
        original_file_name: file.original_file_name,
        file_name: ImageEditing.backup_name(),
        file_path: file.file_path,
        mime_type: file.mime_type,
        file_type: file.file_type,
        ext: file.ext,
        file_checksum: file.file_checksum,
        # Never a real hash: an upload of the unedited bytes must not
        # resolve to this hidden file.
        user_file_checksum: "unedited:#{file.uuid}",
        size: file.size,
        width: file.width,
        height: file.height,
        status: "active",
        user_uuid: file.user_uuid,
        metadata: %{
          "file_name" => file.file_name,
          "rotation" => get_in(file.metadata || %{}, ["rotation"])
        },
        system_managed: true,
        parent_file_uuid: file.uuid,
        library_uuid: file.library_uuid
      })
      |> repo().insert()

    repo().update_all(
      from(fi in FileInstance, where: fi.file_uuid == ^file.uuid),
      set: [file_uuid: backup.uuid]
    )

    backup
  end

  # Tile chunks were cut from the old original; drop them (rows now, objects
  # after commit) so the next request cuts them from the new one.
  defp drop_tiles!(file, backup_uuid) do
    tiles =
      from(f in StorageFile,
        where:
          f.parent_file_uuid == ^file.uuid and f.system_managed == true and
            f.uuid != ^backup_uuid,
        select: f.uuid
      )
      |> repo().all()

    keys = ImageEditing.instance_keys(tiles)
    repo().delete_all(from(f in StorageFile, where: f.uuid in ^tiles))
    keys
  end

  defp duplicate?(file, backup_uuid, user_checksum) do
    excluded = Enum.reject([file.uuid, backup_uuid], &is_nil/1)

    from(f in StorageFile,
      where: f.user_file_checksum == ^user_checksum and f.uuid not in ^excluded
    )
    |> repo().exists?()
  end

  defp after_publish(uuid, revision, {:published, file, dropped_keys, {how, moved?}}) do
    _ = Storage.delete_stored_objects(dropped_keys)

    # A revert brings the unedited variants back with the rows; only a new
    # render needs its variants generated.
    with {:ok, _variants} <- if(how == :rendered, do: generate_variants(file), else: {:ok, []}),
         :ok <- finalize(uuid, revision) do
      settle(file, revision, dropped_keys, moved?)
      :ok
    else
      :superseded -> :superseded
      {:error, reason} -> {:error, {:variants_failed, reason}}
    end
  end

  defp generate_variants(%StorageFile{} = file) do
    case VariantGenerator.generate_variants(file) do
      {:ok, variants} -> {:ok, variants}
      {:error, reason} -> {:error, reason}
    end
  end

  # Clears `edit_state` only if the file is still at the revision this run
  # rendered; otherwise a newer save is waiting.
  defp finalize(uuid, revision) do
    {count, _} =
      from(f in StorageFile,
        where: f.uuid == ^uuid and f.edit_revision == ^revision and f.edit_state == "pending"
      )
      |> repo().update_all(set: [edit_state: nil, updated_at: now()])

    if count == 1, do: :ok, else: :superseded
  end

  # `moved?`: the pixels are somewhere else than before this run (the
  # geometry of the shown edit changed).
  defp settle(file, revision, dropped_keys, moved?) do
    if file.edits && ImageEditing.mode() == "replace_original" do
      _ = ImageEditing.bake(file.uuid, revision)
    end

    maybe_refresh_annotated_thumbnail(file)

    if moved?, do: clear_avatar_crops(file.uuid)

    Storage.broadcast_file_processed(file.uuid)
    Storage.broadcast_file_thumbnail_updated(file.uuid)

    :telemetry.execute(
      [:phoenix_kit, :storage, :file_edited],
      %{revision: revision},
      %{
        file_uuid: file.uuid,
        reverted: is_nil(file.edits),
        geometric: ImageEdit.geometric?(file.edits),
        moved: moved?,
        removed_keys: dropped_keys
      }
    )
  end

  defp maybe_refresh_annotated_thumbnail(file) do
    alias PhoenixKit.Modules.Storage.AnnotationThumbnail

    if Code.ensure_loaded?(AnnotationThumbnail) and AnnotationThumbnail.enabled_for_file?(file) do
      AnnotationThumbnail.refresh(file.uuid)
    end
  rescue
    _ -> :ok
  end

  # A user's avatar crop is fractions of the image it was drawn on; after a
  # geometric edit (or a revert) those fractions point at other pixels.
  defp clear_avatar_crops(file_uuid) do
    alias PhoenixKit.Users.Auth.User

    from(u in User,
      where: fragment("?->>'avatar_file_uuid' = ?::text", u.custom_fields, ^file_uuid),
      update: [
        set: [
          custom_fields:
            fragment(
              "COALESCE(?, '{}'::jsonb) || '{\"avatar_crop\": null}'::jsonb",
              u.custom_fields
            )
        ]
      ]
    )
    |> repo().update_all([])
  rescue
    error -> Logger.warning("ApplyImageEditJob: avatar crops not cleared: #{inspect(error)}")
  end

  # Only the revision that failed: a newer save is another run's business.
  defp mark_failed(uuid, revision, reason) do
    Logger.warning("ApplyImageEditJob: edit #{revision} of #{uuid} failed: #{inspect(reason)}")

    from(f in StorageFile,
      where: f.uuid == ^uuid and f.edit_revision == ^revision and f.edit_state == "pending"
    )
    |> repo().update_all(set: [edit_state: "failed", updated_at: now()])

    Storage.broadcast_file_processed(uuid)
  end

  ## Copy

  defp copy(file, edits) do
    with {:ok, edit} <- normalize_copy(edits),
         {:ok, rendered} <- render(file, edit) do
      name = copy_name(file.original_file_name)

      result =
        Storage.store_file_in_buckets(
          rendered.path,
          file.file_type,
          file.user_uuid,
          rendered.sha256,
          file.ext,
          name,
          mime_type: file.mime_type,
          library_uuid: file.library_uuid
        )

      File.rm(rendered.path)

      case result do
        {:ok, copy} -> link_copy(copy, file)
        {:ok, copy, _duplicate} -> {:ok, copy}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp normalize_copy(edits) do
    case ImageEdit.normalize(edits) do
      {:ok, edit} -> {:ok, edit}
      {:error, reason} -> {:cancel, {:invalid_edit, reason}}
    end
  end

  defp link_copy(copy, file) do
    copy
    |> Ecto.Changeset.change(edited_from_uuid: file.uuid, folder_uuid: file.folder_uuid)
    |> repo().update()
  end

  defp finish_copy({:ok, copy}, _job) do
    Storage.broadcast_file_processed(copy.uuid)
    :ok
  end

  defp finish_copy({:cancel, _} = cancel, _job), do: cancel
  defp finish_copy({:error, reason}, _job), do: {:error, reason}

  defp copy_name(name) do
    ext = Path.extname(name)
    "#{Path.basename(name, ext)} (edited)#{ext}"
  end

  ## Helpers

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  # The temp names never carry the uploader's extension as-is: ImageMagick
  # picks a coder by extension, so `x.mvg` uploaded as `image/png` would be
  # read (and written) as MVG. The source keeps its extension only when it
  # names a media type (`Manager.temp_extension/1`, as the variant pipeline
  # does); the output's comes from the file's MIME type, which is on the
  # editable allowlist.
  defp temp_path(extension) do
    Path.join(System.tmp_dir!(), "pk_edit_#{System.unique_integer([:positive])}#{extension}")
  end

  @doc false
  def output_extension(mime_type) when is_binary(mime_type) do
    if ImageEditing.editable_mime?(mime_type) do
      case MIME.extensions(mime_type) do
        [ext | _] -> "." <> ext
        [] -> ""
      end
    else
      ""
    end
  end

  def output_extension(_mime_type), do: ""

  defp hex(algorithm, bytes), do: algorithm |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
