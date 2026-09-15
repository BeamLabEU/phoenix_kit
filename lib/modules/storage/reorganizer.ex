defmodule PhoenixKit.Modules.Storage.Reorganizer do
  @moduledoc """
  Moves every module's legacy media folders to where the host's
  `attachments_parent_folder` / `attachments_folder_name` hooks now put new
  ones.

  The engine itself knows nothing about any module's schemas — it collects
  plans (plain maps, see `PhoenixKit.Modules.Storage.Reorganizer.Action`)
  from every enabled module's `PhoenixKit.Modules.Storage.Reorganizer.Source`
  (`PhoenixKit.ModuleRegistry.all_media_reorganizers/0`), diffs each plan
  against the current folder state, and — when asked to `apply?` — applies
  each action in its own transaction. A source raising, a single action
  failing, or a naming conflict never halts the run; every outcome is kept
  in the report.

  Nothing is ever hard-deleted. `:trash` only soft-deletes a folder that is
  still empty (0 files, 0 links, 0 live child folders) at apply time
  (`PhoenixKit.Modules.Storage.trash_folder/1`); the engine never creates
  folders.

  A real unique-constraint violation aborts the surrounding Postgres
  transaction, so a failed `UPDATE` can't be retried inside the same
  transaction. Rather than retry, the engine SELECTs the target name for a
  collision *before* writing (`on_conflict: :suffix` picks a free
  `"name (N)"`, `on_conflict: :report` just checks): the transaction either
  hits no naming constraint at all, or is the one query it ever attempts.

      {:ok, report} = PhoenixKit.Modules.Storage.Reorganizer.run(actor_uuid, apply?: false)
      IO.puts(PhoenixKit.Modules.Storage.Reorganizer.format_report(report))
  """

  require Logger
  import Ecto.Query

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKit.Modules.Storage.FolderLink
  alias PhoenixKit.Modules.Storage.Reorganizer.Action

  @columns [
    :total,
    :moved,
    :renamed,
    :backfilled,
    :restored,
    :conflicts,
    :failed,
    :trashed,
    :reported
  ]
  # Each column's width is the header word's own length (min 7), so a word
  # like "backfilled" (10 chars) gets room instead of being padded to a
  # fixed width shorter than itself, which ran header words into each other.
  @column_widths Map.new(@columns, &{&1, max(String.length(Atom.to_string(&1)), 7)})
  @default_opts [apply?: false, pending_days: 7]

  # ===== PLAN =====

  @doc """
  Collects and normalizes actions from every source, dropping no-ops.
  Never writes (engine-side) — a `Source`'s own hooks may still create
  folders/pointers, since `plan/2` calls into the module's normal
  parent/name resolution.

  A source's `plan/2` is isolated: a raise, throw, exit, or a non-list
  return becomes one `:source_error` `:report` action for that source and
  every other source still runs. Within a source's own list, one action
  `Action.new!/1` can't normalize (missing/invalid field) becomes one
  `:invalid_action` `:report` for that action only — the rest of that
  source's plan (and every other source) is unaffected.
  """
  @spec plan(String.t() | nil, keyword()) :: [Action.t()]
  def plan(actor_uuid, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    opts
    |> Keyword.get(:sources, :all)
    |> sources()
    |> Enum.flat_map(&collect(&1, actor_uuid, opts))
    |> Enum.reject(&Action.noop?/1)
  end

  defp collect(source_module, actor_uuid, opts) do
    case safe_plan(source_module, actor_uuid, opts) do
      {:ok, actions} when is_list(actions) ->
        Enum.flat_map(actions, &normalize_action(&1, source_module))

      {:ok, other} ->
        [Action.new!(source_error_action(source_module, {:invalid_plan_return, inspect(other)}))]

      {:error, reason} ->
        [Action.new!(source_error_action(source_module, reason))]
    end
  end

  defp safe_plan(source_module, actor_uuid, opts) do
    {:ok, source_module.plan(actor_uuid, opts)}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_action(attrs, _source_module) do
    [Action.new!(attrs)]
  rescue
    error -> [Action.new!(invalid_action(attrs, error))]
  catch
    kind, reason -> [Action.new!(invalid_action(attrs, {kind, reason}))]
  end

  defp source_error_action(source_module, reason) do
    %{
      source: inspect(source_module),
      kind: :source_error,
      label: "#{inspect(source_module)}.plan/2 raised",
      op: :report,
      reason: inspect(reason)
    }
  end

  defp invalid_action(attrs, reason) do
    %{
      source: action_source(attrs, reason),
      kind: :invalid_action,
      label: "invalid action: #{inspect(attrs)}",
      op: :report,
      reason: format_invalid_action_reason(reason)
    }
  end

  defp action_source(%{source: source}, _reason) when is_binary(source), do: source
  defp action_source(_attrs, _reason), do: "unknown"

  defp format_invalid_action_reason(%_{} = exception), do: Exception.message(exception)
  defp format_invalid_action_reason(reason), do: inspect(reason)

  @doc """
  Resolves the `sources:` option to a list of `Source` modules.

  `:all` collects every enabled module's `media_reorganizer/0`
  (`PhoenixKit.ModuleRegistry.all_media_reorganizers/0`). A list of
  module-key strings resolves each to the enabled module's registered
  source. A list of modules is used as-is (accepted directly so tests can
  exercise a stub `Source` without registering a fake `PhoenixKit.Module`).
  """
  @spec sources(:all | [String.t()] | [module()]) :: [module()]
  def sources(:all), do: ModuleRegistry.all_media_reorganizers()

  def sources(list) when is_list(list) do
    list
    |> Enum.map(&resolve_source_with_warning/1)
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_source_with_warning(mod) when is_atom(mod) and not is_nil(mod), do: mod

  defp resolve_source_with_warning(key) when is_binary(key) do
    case resolve_source(key) do
      nil ->
        Logger.warning(
          "[Reorganizer] unresolved source key #{inspect(key)} (unknown or disabled module) — skipped"
        )

        nil

      mod ->
        mod
    end
  end

  defp resolve_source(key) do
    Enum.find_value(ModuleRegistry.enabled_modules(), fn mod ->
      if function_exported?(mod, :module_key, 0) and mod.module_key() == key and
           function_exported?(mod, :media_reorganizer, 0) do
        mod.media_reorganizer()
      end
    end)
  end

  # ===== RUN =====

  @doc """
  `plan/2`, then — when `apply?: true` — applies every planned action, each
  in its own transaction. Never halts: a failure, conflict, or source error
  is kept in the report and the run continues.
  """
  @spec run(String.t() | nil, keyword()) ::
          {:ok, %{actions: [Action.t()], summary: map(), applied?: boolean()}}
  def run(actor_uuid, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)
    apply? = Keyword.fetch!(opts, :apply?)
    planned = plan(actor_uuid, opts)

    actions = if apply?, do: Enum.map(planned, &apply_one/1), else: planned

    {:ok, %{actions: actions, summary: summarize(actions), applied?: apply?}}
  end

  # ===== APPLY =====

  @doc """
  Applies a single normalized action, returning it with `:outcome` set (and
  `:error`/`:reason` on anything that isn't a clean success). Runs in one
  transaction — a failure at any step rolls back everything the action did.

  Never raises: an exception, throw, or exit anywhere in the apply path
  (including an `after_move` callback) is caught and turned into outcome
  `:failed` — a single bad action never loses the already-committed actions
  from the report.
  """
  @spec apply_one(Action.t()) :: Action.t()
  def apply_one(action) do
    do_apply_one(action)
  rescue
    error -> failed(action, {:exception, Exception.message(error)})
  catch
    kind, reason -> failed(action, {kind, reason})
  end

  defp do_apply_one(%{op: :report} = action), do: Map.put(action, :outcome, :reported)

  defp do_apply_one(%{op: :move, folder: nil} = action),
    do: Map.merge(action, %{outcome: :reported, reason: "no folder to move"})

  defp do_apply_one(%{op: :trash, folder: nil} = action),
    do: Map.merge(action, %{outcome: :reported, reason: "no folder to trash"})

  defp do_apply_one(%{op: :move, folder: %Folder{} = folder} = action) do
    case repo().transaction(fn -> do_move(folder, action) end) do
      {:ok, result} -> result
      {:error, {:conflict, reason}} -> conflicted(action, reason)
      {:error, reason} -> failed(action, reason)
    end
  end

  defp do_apply_one(%{op: :trash, folder: %Folder{} = folder} = action) do
    case repo().transaction(fn -> do_trash(folder, action) end) do
      {:ok, result} -> result
      {:error, reason} -> failed(action, reason)
    end
  end

  defp do_move(folder, action) do
    with :ok <- verify_counts(folder.uuid, Map.get(action, :counts)),
         :ok <- verify_target_parent(Map.get(action, :parent_uuid)),
         folder = restore_if_trashed(folder),
         attrs = move_attrs(folder, action),
         {:ok, updated, final_attrs} <- perform_update(folder, attrs, action),
         :ok <- run_after_move(action),
         :ok <- verify_counts(updated.uuid, Map.get(action, :counts)) do
      Map.put(action, :outcome, outcome_for(attrs, final_attrs, action))
    else
      {:error, {:conflict, reason}} -> repo().rollback({:conflict, reason})
      {:error, reason} -> repo().rollback(reason)
    end
  end

  # A target parent must exist and be live: a folder can't be moved under one
  # that's trashed (it would be dragged along on the next restore/cleanup of
  # that subtree) or gone.
  defp verify_target_parent(nil), do: :ok

  defp verify_target_parent(parent_uuid) do
    case Storage.get_folder(parent_uuid) do
      nil -> {:error, {:target_parent_missing, parent_uuid}}
      %Folder{trashed_at: nil} -> :ok
      %Folder{} -> {:error, {:target_parent_trashed, parent_uuid}}
    end
  end

  defp do_trash(folder, action) do
    case counts(folder.uuid) do
      {0, 0} ->
        case child_folder_count(folder.uuid) do
          0 ->
            case Storage.trash_folder(folder) do
              {:ok, _} -> Map.put(action, :outcome, :trashed)
              {:error, reason} -> repo().rollback(reason)
            end

          n ->
            Map.merge(action, %{
              outcome: :reported,
              reason: "#{n} live child folder(s) still present"
            })
        end

      {files, links} ->
        Map.merge(action, %{
          outcome: :reported,
          reason: "#{files} file(s) and #{links} link(s) still present"
        })
    end
  end

  defp child_folder_count(folder_uuid) do
    from(f in Folder, where: f.parent_uuid == ^folder_uuid and is_nil(f.trashed_at), select: count())
    |> repo().one()
  end

  defp restore_if_trashed(%Folder{trashed_at: nil} = folder), do: folder

  defp restore_if_trashed(%Folder{} = folder) do
    case Storage.restore_folder(folder) do
      {:ok, _} -> Storage.get_folder(folder.uuid)
      {:error, _reason} -> folder
    end
  end

  defp move_attrs(folder, action) do
    %{}
    |> maybe_put_parent(folder, action)
    |> maybe_put_name(folder, action)
  end

  defp maybe_put_parent(attrs, folder, action) do
    wanted = Map.get(action, :parent_uuid)

    if folder.parent_uuid != wanted do
      Map.put(attrs, :parent_uuid, wanted)
    else
      attrs
    end
  end

  defp maybe_put_name(attrs, folder, action) do
    wanted = Map.get(action, :name)

    cond do
      is_nil(wanted) -> attrs
      Action.matches_name?(folder.name, wanted) -> attrs
      true -> Map.put(attrs, :name, wanted)
    end
  end

  # A real unique-constraint violation aborts the surrounding Postgres
  # transaction (Ecto/Postgrex issue no automatic SAVEPOINT around a plain
  # `Repo.transaction`), so a second query — a retry — is unusable once that
  # happens. Instead, `on_conflict: :suffix` resolves the collision with a
  # SELECT *before* writing, so the single `update_folder` call either hits
  # no constraint at all (suffix path) or is the one query the transaction
  # ever attempts (report path, which just rolls back on conflict).
  defp perform_update(folder, %{} = attrs, _action) when map_size(attrs) == 0 do
    # Folder already sits at the wanted parent/name — nothing to write. This
    # still reaches here (not filtered as a noop) when the action carries
    # `after_move`: the folder position matching doesn't mean the pointer
    # back-fill has run yet.
    {:ok, folder, attrs}
  end

  defp perform_update(folder, attrs, action) do
    attrs = maybe_presuffix(folder, attrs, action)

    case Storage.update_folder(folder, attrs) do
      {:ok, updated} ->
        {:ok, updated, attrs}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if unique_name_conflict?(errors) do
          {:error, {:conflict, {:name_taken, Map.get(attrs, :parent_uuid, folder.parent_uuid), Map.get(attrs, :name, folder.name)}}}
        else
          {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Only a real unique-constraint violation on :name is a naming conflict —
  # any other :name error (e.g. length > 255) is a genuine failure, not a
  # collision `on_conflict: :suffix`/`:report` should resolve.
  defp unique_name_conflict?(errors) do
    Enum.any?(errors, fn
      {:name, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp maybe_presuffix(folder, attrs, action) do
    if Map.get(action, :on_conflict) == :suffix do
      target_parent = Map.get(attrs, :parent_uuid, folder.parent_uuid)
      wanted_name = Map.get(attrs, :name, folder.name)

      if name_taken?(wanted_name, target_parent, folder.uuid) do
        base_name = Map.get(action, :name) || folder.name
        Map.put(attrs, :name, free_name(base_name, target_parent, folder.uuid))
      else
        attrs
      end
    else
      attrs
    end
  end

  defp name_taken?(name, parent_uuid, own_uuid) do
    parent_uuid
    |> live_siblings_query()
    |> where([f], f.name == ^name and f.uuid != ^own_uuid)
    |> repo().exists?()
  end

  defp free_name(base_name, parent_uuid, own_uuid) do
    parent_uuid
    |> live_siblings_query()
    |> where([f], f.uuid != ^own_uuid)
    |> select([f], f.name)
    |> repo().all()
    |> pick_free_name(base_name)
  end

  defp live_siblings_query(nil) do
    from(f in Folder, where: is_nil(f.parent_uuid) and is_nil(f.trashed_at))
  end

  defp live_siblings_query(parent_uuid) do
    from(f in Folder, where: f.parent_uuid == ^parent_uuid and is_nil(f.trashed_at))
  end

  defp pick_free_name(existing_names, base_name) do
    existing = MapSet.new(existing_names)

    if base_name not in existing do
      base_name
    else
      Enum.find_value(Stream.iterate(2, &(&1 + 1)), fn n ->
        candidate = "#{base_name} (#{n})"
        if candidate not in existing, do: candidate
      end)
    end
  end

  defp run_after_move(%{after_move: fun}) when is_function(fun, 0) do
    case fun.() do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_after_move_return, other}}
    end
  end

  defp run_after_move(_action), do: :ok

  defp outcome_for(attrs, final_attrs, action) do
    moved? = Map.has_key?(attrs, :parent_uuid)
    renamed? = Map.has_key?(final_attrs, :name)

    cond do
      is_function(Map.get(action, :after_move), 0) -> :backfilled
      moved? and renamed? -> :moved_renamed
      moved? -> :moved
      renamed? -> :renamed
      # Reached only when the folder was already at the wanted parent/name
      # (nothing written) with no after_move — since a noop `:move` action
      # this shape never reaches `apply_one/1` (see `Action.noop?/1`), the
      # only way here is a trashed folder that `restore_if_trashed/1` just
      # brought back: the restore itself is the change.
      true -> :restored
    end
  end

  # `counts: nil` disables the built-in guard entirely — a Source must
  # always measure and pass counts for a `:move` with a folder; treating a
  # missing measurement as "skip the check" let a folder move with files
  # still inside it slip through silently.
  defp verify_counts(folder_uuid, nil), do: {:error, {:counts_missing, folder_uuid}}

  defp verify_counts(folder_uuid, expected) do
    case counts(folder_uuid) do
      ^expected -> :ok
      actual -> {:error, {:count_mismatch, folder_uuid, expected, actual}}
    end
  end

  defp counts(folder_uuid) do
    files =
      from(f in StorageFile, where: f.folder_uuid == ^folder_uuid, select: count())
      |> repo().one()

    links =
      from(l in FolderLink, where: l.folder_uuid == ^folder_uuid, select: count())
      |> repo().one()

    {files || 0, links || 0}
  end

  defp failed(action, reason) do
    Logger.warning("[Reorganizer] #{action.kind} #{action.label}: #{inspect(reason)}")
    Map.merge(action, %{outcome: :failed, error: reason})
  end

  defp conflicted(action, reason) do
    Logger.warning("[Reorganizer] #{action.kind} #{action.label} conflict: #{inspect(reason)}")
    Map.merge(action, %{outcome: :conflict, error: reason})
  end

  # ===== REPORT =====

  @doc "Groups actions by `{source, kind}` and counts outcomes per group."
  @spec summarize([Action.t()]) :: %{{String.t(), atom()} => map()}
  def summarize(actions) do
    actions
    |> Enum.group_by(&{&1.source, &1.kind})
    |> Map.new(fn {key, group} -> {key, summarize_group(group)} end)
  end

  defp summarize_group(actions) do
    %{
      total: length(actions),
      moved:
        Enum.count(
          actions,
          &(Map.get(&1, :outcome) in [:moved, :renamed, :moved_renamed, :backfilled])
        ),
      renamed: Enum.count(actions, &(Map.get(&1, :outcome) in [:renamed, :moved_renamed])),
      backfilled: Enum.count(actions, &(Map.get(&1, :outcome) == :backfilled)),
      restored: Enum.count(actions, &(Map.get(&1, :outcome) == :restored)),
      conflicts: Enum.count(actions, &(Map.get(&1, :outcome) == :conflict)),
      failed: Enum.count(actions, &(Map.get(&1, :outcome) == :failed)),
      trashed: Enum.count(actions, &(Map.get(&1, :outcome) == :trashed)),
      reported: Enum.count(actions, &(Map.get(&1, :outcome) == :reported))
    }
  end

  @doc """
  Renders the report as a fixed-width text table: one row per `{source,
  kind}` with columns `total moved renamed backfilled conflicts failed
  trashed reported`, then a details section — everything not a clean move
  (conflicts, failures, reports, trashes), and in dry-run every planned
  action, so the owner sees what `--apply` would do.
  """
  @spec format_report(%{actions: [Action.t()], summary: map(), applied?: boolean()}) :: String.t()
  def format_report(%{actions: actions, summary: summary, applied?: applied?}) do
    header = format_row("source kind", Map.new(@columns, &{&1, Atom.to_string(&1)}))

    rows =
      summary
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {{source, kind}, counts} -> format_row("#{source} #{kind}", counts) end)

    note = if applied?, do: "applied", else: "dry run — planned actions, nothing written"

    [header | rows]
    |> Enum.join("\n")
    |> Kernel.<>("\n\n#{note}")
    |> Kernel.<>(format_details(actions, applied?))
  end

  defp format_row(label, values_by_column) do
    cells =
      Enum.map(@columns, fn col ->
        values_by_column
        |> Map.get(col, 0)
        |> to_string()
        |> String.pad_leading(@column_widths[col])
      end)

    Enum.join([String.pad_trailing(label, 24) | cells], " ")
  end

  defp format_details(actions, applied?) do
    noteworthy =
      Enum.filter(actions, fn action ->
        not applied? or
          Map.get(action, :outcome) in [:conflict, :failed, :reported, :trashed, :restored]
      end)

    case noteworthy do
      [] -> ""
      list -> "\n\nDetails:\n" <> Enum.map_join(list, "\n", &detail_line(&1, resolve_parent_names(list)))
    end
  end

  # One batched query for every parent name a detail line needs (current +
  # desired parent of every `:move` action), instead of one lookup per line.
  defp resolve_parent_names(actions) do
    uuids =
      actions
      |> Enum.flat_map(fn action -> [Map.get(action, :parent_uuid), current_parent_uuid(action)] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case uuids do
      [] ->
        %{}

      _ ->
        from(f in Folder, where: f.uuid in ^uuids, select: {f.uuid, f.name})
        |> repo().all()
        |> Map.new()
    end
  end

  defp current_parent_uuid(%{folder: %Folder{parent_uuid: parent_uuid}}), do: parent_uuid
  defp current_parent_uuid(_action), do: nil

  defp detail_line(%{source: source, kind: kind, op: op, label: label} = action, parent_names) do
    "  [#{source}/#{kind}] #{op} #{label}"
    |> append_transition(action, parent_names)
    |> maybe_append(Map.get(action, :outcome), &" -> #{&1}")
    |> maybe_append(Map.get(action, :reason) || Map.get(action, :error), &" (#{inspect(&1)})")
  end

  defp append_transition(line, %{op: :move, folder: %Folder{} = folder} = action, parent_names) do
    from_name = Map.get(parent_names, folder.parent_uuid, "root")
    to_name = Map.get(parent_names, Map.get(action, :parent_uuid), "root")
    old_name = folder.name
    new_name = Map.get(action, :name) || old_name

    line <> ": #{from_name} → #{to_name}, name \"#{old_name}\" → \"#{new_name}\""
  end

  defp append_transition(line, _action, _parent_names), do: line

  defp maybe_append(line, nil, _fun), do: line
  defp maybe_append(line, value, fun), do: line <> fun.(value)

  defp repo, do: PhoenixKit.Config.get_repo()
end
