defmodule PhoenixKit.Modules.Storage.Reconciler do
  @moduledoc """
  Makes each file match its library's storage profile and variant set
  (V205, plan §6.3). `Storage.Workers.ReconcileJob` runs it.

  A file records the profile and the variant set (each at a revision) it
  was last placed by (`placed_profile_uuid` / `placed_revision`,
  `placed_variant_set_uuid` / `placed_variant_revision`; NULL is the
  Default at revision 1). It is **stale** (`stale_query/0`) when either
  differs from what its library uses now: the library moved to another
  profile or set, one of them changed, or an upload made fewer copies or
  sizes than wanted (which stamps revision 0).

  For a stale file, `reconcile_file/1`:

    * **locations** (G4, G5, G6) — for each completed instance: an original
      upload is an `:original`, everything else (sizes, tiles, renders) is
      `:derived` (G13; an edit's hidden backup of the unedited original is
      an original). Its good copies are on the profile's buckets that store
      that kind and are `active` or `read_only`. While there are fewer than
      the profile wants (capped at the buckets it can use), the object is
      copied to more of its writable buckets and each copy is checked
      before it counts. Once enough are good, copies on buckets the profile
      no longer uses for it (not listed, `draining`, storing the other
      kind) are unlinked: the location row goes, and the object on that
      bucket only when nothing else there names the key (G11,
      `Storage.unlink_location/2`).
    * **variants** (G15, G16) — sizes of the set the file lacks are made,
      those whose `spec_hash` differs from the size's spec now are made
      again, and those the set no longer has (a size deleted from it; a
      disabled size is kept) are deleted.

  A file that ends up matching both is stamped with what it now matches,
  at the revisions read when it was started (a change made meanwhile leaves
  it stale for the next pass). A failure leaves it stale; the next pass
  tries again. Instances not yet checked by the location backfill are
  skipped (their buckets are not known), and so is a file still uploading
  or with an image edit pending.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage

  alias PhoenixKit.Modules.Storage.{
    Bucket,
    FileInstance,
    FileLocation,
    Library,
    Locations,
    Manager,
    Profiles,
    StorageProfile,
    VariantGenerator,
    VariantSet,
    VariantSets
  }

  alias PhoenixKit.Modules.Storage.File, as: StorageFile

  # A file the reconciler could not finish waits this long before the next
  # try, so one that keeps failing (an unreadable original, a bucket that is
  # down) is not retried on every pass, ahead of every other file.
  @retry_after_seconds 600

  # A file still "processing" this long after its last change is not being
  # processed any more (a type the processing job does not handle, or a
  # failed run): its bytes are placed like any other file's.
  @processing_grace_seconds 3600

  @doc """
  The files that are not where, or not what, their library's profile and
  variant set want — **and that the reconciler may work on now**: not a file
  an upload is still processing, nor one with an image edit pending, nor one
  tried in the last few minutes. This is the work-selection query; what a
  library's *state* counts is `out_of_date_query/1`.

  `library_uuid:` limits it to one library.
  """
  @spec stale_query(keyword()) :: Ecto.Query.t()
  def stale_query(opts \\ []) do
    retry_before = NaiveDateTime.add(NaiveDateTime.utc_now(), -@retry_after_seconds)

    opts
    |> out_of_date_query()
    |> where([f], is_nil(f.edit_state) or f.edit_state != "pending")
    |> where([f], is_nil(f.reconcile_attempted_at) or f.reconcile_attempted_at < ^retry_before)
  end

  @doc """
  The files whose placement or sizes are out of date — the revision of their
  library's profile or variant set is not the one they were placed by —
  **whether or not the reconciler may take them now**. A file waiting out its
  retry window, one with an image edit pending: all are out of date. That is
  what "this library is not up to date" means; `stale_query/1` is the subset
  the reconciler picks next (plan `2026-10-03-job-runs.md`, R8).

  Takes the same `library_uuid:` option.
  """
  @spec out_of_date_query(keyword()) :: Ecto.Query.t()
  def out_of_date_query(opts \\ []) do
    profile = Profiles.default_uuid()
    set = VariantSets.default_uuid()
    now = NaiveDateTime.utc_now()
    processing_before = NaiveDateTime.add(now, -@processing_grace_seconds)

    from(f in StorageFile,
      as: :file,
      left_join: l in Library,
      on: l.uuid == f.library_uuid,
      join: p in StorageProfile,
      on: p.uuid == coalesce(l.storage_profile_uuid, type(^profile, UUIDv7)),
      join: s in VariantSet,
      on: s.uuid == coalesce(l.variant_set_uuid, type(^set, UUIDv7)),
      where:
        f.status in ["active", "trashed", "failed"] or
          (f.status == "processing" and f.updated_at < ^processing_before),
      where:
        coalesce(f.placed_profile_uuid, type(^profile, UUIDv7)) != p.uuid or
          coalesce(f.placed_revision, 1) != p.revision or
          (f.status == "active" and
             (coalesce(f.placed_variant_set_uuid, type(^set, UUIDv7)) != s.uuid or
                coalesce(f.placed_variant_revision, 1) != s.revision))
    )
    |> in_library(opts[:library_uuid])
  end

  defp in_library(query, nil), do: query

  defp in_library(query, library_uuid),
    do: where(query, [f], f.library_uuid == type(^library_uuid, UUIDv7))

  @doc """
  What each library has to do, from one grouped query: for every library with
  at least one out-of-date file, `%{out_of_date:, eligible:, failing:}` —

    * `out_of_date` — files not at their library's revisions (`out_of_date_query/1`);
    * `eligible` — of those, the ones the reconciler may take now (`stale_query/1`);
    * `failing` — of those, the ones it tried and could not finish in the last
      few minutes (they wait out `@retry_after_seconds` before the next try).

  Keyed by the library's uuid as a string. A library absent from the map has
  nothing out of date. An optional uuid list limits the query to the libraries
  a screen is showing; omitted, it counts every library.
  """
  @spec counts_by_library([String.t()] | nil) :: %{String.t() => map()}
  def counts_by_library(library_uuids \\ nil) do
    retry_before = NaiveDateTime.add(NaiveDateTime.utc_now(), -@retry_after_seconds)
    query = out_of_date_query()

    query =
      if is_list(library_uuids),
        do: where(query, [f], f.library_uuid in ^library_uuids),
        else: query

    from([f] in query,
      group_by: f.library_uuid,
      select: {
        f.library_uuid,
        %{
          out_of_date: count(f.uuid),
          eligible:
            filter(
              count(f.uuid),
              (is_nil(f.edit_state) or f.edit_state != "pending") and
                (is_nil(f.reconcile_attempted_at) or f.reconcile_attempted_at < ^retry_before)
            ),
          failing: filter(count(f.uuid), f.reconcile_attempted_at >= ^retry_before)
        }
      }
    )
    |> repo().all()
    |> Map.new(fn {uuid, counts} -> {to_string(uuid), counts} end)
  end

  @doc "The libraries that have files the reconciler may take now, as uuid strings."
  @spec libraries_with_work() :: [String.t()]
  def libraries_with_work do
    from([f] in stale_query(), distinct: true, select: f.library_uuid)
    |> repo().all()
    |> Enum.map(&to_string/1)
  end

  @doc "How many files the reconciler looks after (active and trashed ones)."
  @spec total_count() :: non_neg_integer()
  def total_count do
    from(f in StorageFile, where: f.status in ["active", "trashed"], select: count(f.uuid))
    |> repo().one()
  end

  @doc "How many files are stale."
  @spec stale_count(keyword()) :: non_neg_integer()
  def stale_count(opts \\ []), do: stale_query(opts) |> select([f], count(f.uuid)) |> repo().one()

  @doc "Whether any file is stale."
  @spec pending?(keyword()) :: boolean()
  def pending?(opts \\ []), do: repo().exists?(stale_query(opts))

  @doc """
  Up to `limit` stale files for the Health page: the file, its library's
  name, and whether its copies (`:placement`) or its sizes (`:variants`)
  are what is out of date.
  """
  @spec stale_files(pos_integer()) :: [map()]
  def stale_files(limit \\ 200) do
    profile = Profiles.default_uuid()
    set = VariantSets.default_uuid()

    from([f, l, p, s] in stale_query(),
      order_by: [asc: f.original_file_name, asc: f.uuid],
      limit: ^limit,
      select: %{
        file_uuid: f.uuid,
        original_file_name: f.original_file_name,
        file_type: f.file_type,
        library_name: l.name,
        placement:
          coalesce(f.placed_profile_uuid, type(^profile, UUIDv7)) != p.uuid or
            coalesce(f.placed_revision, 1) != p.revision,
        variants:
          f.status == "active" and
            (coalesce(f.placed_variant_set_uuid, type(^set, UUIDv7)) != s.uuid or
               coalesce(f.placed_variant_revision, 1) != s.revision)
      }
    )
    |> repo().all()
  end

  @doc """
  Reconciles up to `limit` stale files after `cursor` (a file uuid; nil
  from the start), in uuid order. Returns `{:more, last_uuid, totals}`
  while a full batch was read, `{:done, totals}` once the walk has passed
  the last one; `totals` counts files `:reconciled`, `:stale` (still) and
  `:skipped`. `library_uuid:` walks one library's files only.
  """
  @spec run_batch(String.t() | nil, pos_integer(), map(), keyword()) ::
          {:more, String.t(), map()} | {:done, map()}
  def run_batch(cursor, limit, totals \\ %{}, opts \\ []) do
    batch =
      stale_query(opts)
      |> after_cursor(cursor)
      |> order_by([f], asc: f.uuid)
      |> limit(^limit)
      |> repo().all()

    totals =
      Enum.reduce(batch, totals, fn file, acc ->
        Map.update(acc, reconcile_file(file), 1, &(&1 + 1))
      end)

    if length(batch) < limit,
      do: {:done, totals},
      else: {:more, batch |> List.last() |> Map.fetch!(:uuid) |> to_string(), totals}
  end

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, cursor), do: where(query, [f], f.uuid > ^cursor)

  @doc """
  Makes `file` match its library's profile and variant set, and stamps it
  when it does. Returns `:reconciled`, `:stale` (something could not be
  done yet; it stays stale) or `:skipped` (another reconciler holds it).
  One reconciler at a time per file, across nodes: a session advisory lock
  on the file, held while its bytes are copied.
  """
  @spec reconcile_file(StorageFile.t()) :: :reconciled | :stale | :skipped
  def reconcile_file(%StorageFile{} = file) do
    repo().checkout(fn ->
      if try_lock(file.uuid) do
        try do
          do_reconcile(file)
        after
          unlock(file.uuid)
        end
      else
        :skipped
      end
    end)
  end

  defp do_reconcile(file) do
    profile = Profiles.for_library(file.library_uuid)
    set = VariantSets.for_library(file.library_uuid)

    # Sizes first: making one writes derived copies, which the locations
    # step then checks.
    variants = if set, do: reconcile_variants(file, set), else: false
    made? = variants != false
    placed? = profile != nil and reconcile_locations(file, profile)

    # Each stamp only while the file still carries the stamp it had when it
    # was read: something that marked it stale meanwhile (an incomplete
    # variant, an upload job) wins, and the next pass looks again.
    if placed? do
      stamp(file, [:placed_profile_uuid, :placed_revision],
        placed_profile_uuid: profile.uuid,
        placed_revision: profile.revision
      )
    end

    # Only when the sizes were really checked: a file in the trash, or not
    # done processing, keeps its old stamp and is looked at again once it is
    # active (the stale query only asks about an active file's sizes).
    if variants == :checked do
      stamp(file, [:placed_variant_set_uuid, :placed_variant_revision],
        placed_variant_set_uuid: set.uuid,
        placed_variant_revision: set.revision
      )
    end

    if placed? and made? do
      :reconciled
    else
      attempted(file)
      :stale
    end
  rescue
    error ->
      Logger.warning("Reconciler: #{file.uuid} failed: #{Exception.message(error)}")
      attempted(file)
      :stale
  end

  defp stamp(file, fields, changes) do
    fields
    |> Enum.reduce(from(f in StorageFile, where: f.uuid == ^file.uuid), fn field, query ->
      case Map.fetch!(file, field) do
        nil -> where(query, [f], is_nil(field(f, ^field)))
        value -> where(query, [f], field(f, ^field) == ^value)
      end
    end)
    |> repo().update_all(set: changes)
  end

  defp attempted(file) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    from(f in StorageFile, where: f.uuid == ^file.uuid)
    |> repo().update_all(set: [reconcile_attempted_at: now])
  end

  # ── Locations ────────────────────────────────────────────────────────

  defp reconcile_locations(file, profile) do
    checked = checked_instances(file)

    instances =
      from(i in FileInstance,
        where: i.file_uuid == ^file.uuid and i.processing_status == "completed"
      )
      |> repo().all()

    Enum.reduce(instances, true, fn instance, ok? ->
      if instance.uuid in checked do
        place_instance(instance, profile) and ok?
      else
        false
      end
    end)
  end

  defp checked_instances(file) do
    unchecked =
      from(i in Locations.unchecked_query(), where: i.file_uuid == ^file.uuid, select: i.uuid)
      |> repo().all()

    from(i in FileInstance, where: i.file_uuid == ^file.uuid, select: i.uuid)
    |> repo().all()
    |> Enum.reject(&(&1 in unchecked))
  end

  # One instance: enough good copies of each kind, then no copies where the
  # profile no longer wants them. True when both hold.
  defp place_instance(instance, profile) do
    # Buckets whose copy counts: in the profile, active or read-only, enabled.
    keep =
      for row <- profile.buckets,
          row.status in ["active", "read_only"],
          match?(%{enabled: true}, row.bucket),
          into: %{},
          do: {to_string(row.bucket_uuid), row.bucket}

    plan = Manager.placement_plan(profile)
    writable = Enum.flat_map(plan, &elem(&1, 1))
    located = located_buckets(instance)
    good = located |> Map.keys() |> Enum.filter(&Map.has_key?(keep, &1))

    # As many copies of each kind as the profile wants, capped at the buckets of
    # that kind that hold one or can take one: a read-only or full bucket without
    # a copy cannot get one, and must not keep the file stale for ever.
    {good, target} =
      Enum.reduce(plan, {good, 0}, fn {kind, candidates, copies}, {good, target} ->
        held = Enum.filter(good, &(Bucket.group(Map.fetch!(keep, &1)) == kind))

        wanted =
          min(copies, length(Enum.uniq(held ++ Map.keys(by_uuid(candidates)))))

        added = copy_to_more(instance, candidates, held, wanted - length(held))
        {good ++ added, target + wanted}
      end)

    good = good ++ servable_copy(instance, profile, writable, good)
    leftovers = Enum.reject(located, fn {uuid, _bucket} -> Map.has_key?(keep, uuid) end)

    cond do
      length(good) < target ->
        false

      # No copy it may serve, while it has somewhere to make one.
      servable_missing?(profile, writable, good) ->
        false

      leftovers == [] ->
        true

      # Before a copy goes, the ones that stay are checked to really be
      # there: a location row can outlive its object, and "enough copies"
      # must never mean unlinking the last real one. Never with none.
      verified_copies(instance, good, keep, located) < max(target, 1) ->
        false

      true ->
        leftovers
        |> Enum.map(fn {_uuid, bucket} -> unlink(instance, bucket) end)
        |> Enum.all?()
    end
  end

  # A backup is never served, so a file needs one copy on a primary or a
  # replica (a role change can leave all of them on backups). One more is
  # made there when the profile has such a bucket to write.
  defp servable_copy(instance, profile, writable, good) do
    roles = Map.new(profile.buckets, &{to_string(&1.bucket_uuid), &1.role})
    servable? = fn uuid -> Map.get(roles, uuid) in ["primary", "replica"] end

    if Enum.any?(good, servable?) do
      []
    else
      writable
      |> Enum.filter(&servable?.(to_string(&1.uuid)))
      |> then(&copy_to_more(instance, &1, good, 1))
    end
  end

  defp servable_missing?(profile, writable, good) do
    roles = Map.new(profile.buckets, &{to_string(&1.bucket_uuid), &1.role})
    servable? = fn uuid -> Map.get(roles, uuid) in ["primary", "replica"] end

    not Enum.any?(good, servable?) and Enum.any?(writable, &servable?.(to_string(&1.uuid)))
  end

  # How many of the `good` copies are really in their bucket.
  defp verified_copies(instance, good, keep, located) do
    Enum.count(good, fn uuid ->
      bucket = Map.get(keep, uuid) || Map.get(located, uuid)
      bucket != nil and Manager.holds?(bucket, instance.file_name)
    end)
  end

  defp by_uuid(buckets), do: Map.new(buckets, &{to_string(&1.uuid), &1})

  # The instance's active locations, by bucket uuid, with the bucket.
  defp located_buckets(instance) do
    from(l in FileLocation,
      where: l.file_instance_uuid == ^instance.uuid and l.status == "active",
      preload: :bucket
    )
    |> repo().all()
    |> Map.new(&{to_string(&1.bucket_uuid), &1.bucket})
  end

  defp copy_to_more(_instance, _writable, _good, missing) when missing <= 0, do: []

  defp copy_to_more(instance, writable, good, missing) do
    targets =
      writable
      |> Enum.reject(&(to_string(&1.uuid) in good))
      |> Enum.take(missing)

    if targets == [] do
      []
    else
      key = instance.file_name

      # Under the key's directory lock, like an unlink: another file's
      # reconciler unlinking the same (shared) key from a bucket must see
      # this copy's row, or not have seen the object at all.
      {:ok, copied} =
        repo().transaction(
          fn ->
            Storage.lock_storage_paths([Path.dirname(key)])
            copy_and_record(key, targets)
          end,
          timeout: :infinity
        )

      copied
    end
  end

  defp copy_and_record(key, targets) do
    case Manager.replicate_to_buckets(key, targets) do
      {:ok, info} ->
        stored = MapSet.new(info.bucket_ids, &to_string/1)

        # A copy counts once it is really there.
        for bucket <- targets,
            to_string(bucket.uuid) in stored,
            Manager.holds?(bucket, key) do
          Locations.record(key, bucket.uuid)
          to_string(bucket.uuid)
        end

      {:error, reason} ->
        Logger.warning("Reconciler: could not copy #{key}: #{inspect(reason)}")
        []
    end
  end

  # A disabled bucket cannot be written to, so its copy is left for a pass
  # after it comes back.
  defp unlink(instance, %{enabled: true} = bucket) do
    match?({:ok, _}, Storage.unlink_location(instance, bucket))
  end

  defp unlink(_instance, _bucket), do: false

  # ── Variants ─────────────────────────────────────────────────────────

  # `:checked` (the file has its set's sizes), `:not_now` (a file whose
  # sizes are not looked after in its state: trashed, still processing,
  # failed) or false (a size could not be made).
  defp reconcile_variants(file, %VariantSet{} = set) do
    cond do
      file.status != "active" -> :not_now
      not VariantGenerator.variant_source?(file) -> :checked
      make_variants(file, set) -> :checked
      true -> false
    end
  end

  defp make_variants(file, set) do
    expected = VariantGenerator.expected_variants(file)
    instances = Storage.list_file_instances(file.uuid)
    by_name = Map.new(instances, &{&1.variant_name, &1})

    # Missing sizes, and sizes made from another spec. An instance in a size
    # slot with no spec hash was not made from a size (a burned annotation
    # thumbnail is written into `thumbnail`): it is someone's content and is
    # never made over.
    to_make =
      Enum.flat_map(expected, fn {dimension, name, format} ->
        case Map.get(by_name, name) do
          nil ->
            [{dimension, name, format, []}]

          %{spec_hash: nil} ->
            []

          instance ->
            if instance.spec_hash == VariantSets.spec_hash(dimension, format),
              do: [],
              else: [{dimension, name, format, remake_opts(file, instance)}]
        end
      end)

    made? =
      Enum.reduce(to_make, true, fn {dimension, name, format, opts}, ok? ->
        match?({:ok, _}, VariantGenerator.generate_variant(file, dimension, name, format, opts)) and
          ok?
      end)

    removed? = remove_dropped_sizes(file, set, instances)
    made? and removed?
  end

  # A variant's key is shared with a cross-user copy (same bytes, same
  # directory). Made again from another spec, it goes under a new key, or it
  # would change the bytes the other file serves under its old spec.
  defp remake_opts(file, instance) do
    shared? =
      repo().exists?(
        from(i in FileInstance,
          where: i.file_name == ^instance.file_name and i.file_uuid != ^file.uuid
        )
      )

    if shared?, do: [fresh_key: true], else: []
  end

  # Instances made from a size (a spec hash) that the set no longer has at
  # all. A disabled size keeps its instances: it stops being made, it is
  # not taken back.
  defp remove_dropped_sizes(file, set, instances) do
    known =
      set.uuid
      |> VariantSets.list_dimensions()
      |> Enum.flat_map(fn d ->
        [d.name | Enum.map(d.alternative_formats || [], &"#{d.name}_#{&1}")]
      end)
      |> MapSet.new()

    case Enum.filter(
           instances,
           &(&1.spec_hash != nil and not MapSet.member?(known, &1.variant_name))
         ) do
      [] -> true
      dropped -> match?({:ok, _}, ok_tuple(Storage.remove_instances(file, dropped)))
    end
  end

  defp ok_tuple(:ok), do: {:ok, :ok}
  defp ok_tuple(other), do: other

  # ── Locks ────────────────────────────────────────────────────────────

  defp try_lock(file_uuid) do
    %{rows: [[locked?]]} =
      repo().query!(
        "SELECT pg_try_advisory_lock(hashtext('phoenix_kit_reconcile:' || $1))",
        [to_string(file_uuid)],
        log: false
      )

    locked?
  end

  defp unlock(file_uuid) do
    repo().query!(
      "SELECT pg_advisory_unlock(hashtext('phoenix_kit_reconcile:' || $1))",
      [to_string(file_uuid)],
      log: false
    )
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
