defmodule PhoenixKit.Modules.Storage.Manager do
  @moduledoc """
  Storage manager for handling file operations with redundancy and failover.

  This module coordinates file storage across multiple buckets with automatic
  redundancy, failover, and variant generation.

  ## Where an object is read from (V204)

  Reads, existence checks, public URLs and serving go to the buckets the
  object's location rows name first (`PhoenixKit.Modules.Storage.Locations`),
  in the usual order: local buckets, then by priority. Only when none of
  them has it are the other enabled buckets tried, and a bucket found to
  hold it that way is recorded as a location. Deletes still remove an
  unreferenced key from every enabled bucket.

  ## Where an object is written (V205)

  By the storage profile of the file's library (`store_file/2`): its
  buckets, their roles and write priorities, and its copy counts.
  """

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.BucketLog
  alias PhoenixKit.Modules.Storage.Locations
  alias PhoenixKit.Modules.Storage.ProfileBucket
  alias PhoenixKit.Modules.Storage.Profiles
  alias PhoenixKit.Modules.Storage.ProviderRegistry
  alias PhoenixKit.Modules.Storage.Providers.Local
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # Cache TTL for bucket list (5 minutes)
  @buckets_cache_ttl 300_000

  @doc """
  Stores a file across buckets.

  ## Where it goes (V205)

  By a storage profile: `:profile` (a `StorageProfile` with its buckets
  preloaded, `Storage.Profiles.for_library/1`), or the Default profile
  when none is given. `:kind` says what the object is: `:original` (an
  original upload, the default) or `:derived` (a size, a tile, a render),
  which only matters to the copies an upload must make. Every file gets the
  profile's copies per kind of bucket: `copies_local` on local buckets and
  `copies_cloud` on cloud ones. Buckets that are enabled, `active` in the
  profile and not over their `max_size_mb` are written, primaries before
  replicas before backups, each role by fixed write priority and then in
  random order, up to the count for their kind.

  An original fails unless at least the profile's `min_copies_on_write`
  copies were written (what was written is removed again). The result
  says whether every copy the profile wants was made (`complete?`); the
  rest are made by the reconciler.

  ## Options

  - `:path_prefix` - the object key
  - `:profile` / `:kind` - see above
  - `:force_bucket_ids` - exactly these buckets (every one that is enabled,
    in the order given), whatever any profile says
  - `:redundancy_copies` / `:priority_buckets` - the pre-profile selection
    (the enabled buckets by priority, up to the count), kept for callers
    that ask for it

  ## Returns

  - `{:ok, file_result}` - `destination_path`, `bucket_ids` (the buckets
    written), `stored_in`, `successful_storages`, `complete?`
  - `{:error, reason}` - Failed to store file
  """
  def store_file(source_path, opts \\ []) do
    force_bucket_ids = Keyword.get(opts, :force_bucket_ids, [])

    # `force_bucket_ids` are exactly the buckets to write to (an edit's
    # output goes where the key it replaces is): every one that is enabled,
    # in the order given.
    # `groups`: `{buckets, want}` pairs, the buckets in write order; the first
    # `want` of each are written, and a failed one is replaced by the next
    # (spares only exist for a profile).
    {groups, min_copies, backups} =
      cond do
        force_bucket_ids != [] ->
          forced = forced_buckets(force_bucket_ids)
          {[{forced, length(forced)}], 1, MapSet.new()}

        legacy_selection?(opts) ->
          redundancy = Keyword.get(opts, :redundancy_copies, 1)

          selected =
            select_buckets_for_storage(redundancy, Keyword.get(opts, :priority_buckets, []))

          {[{selected, length(selected)}], 1, MapSet.new()}

        profile = Keyword.get(opts, :profile) || Profiles.default_profile() ->
          profile_placement(profile, Keyword.get(opts, :kind, :original))

        # No profiles on this database yet: the pre-V205 pool.
        true ->
          selected = select_buckets_for_storage(1, [])
          {[{selected, length(selected)}], 1, MapSet.new()}
      end

    target = groups |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if target == 0 do
      {:error, "No available storage buckets"}
    else
      with {:ok, info} <- store_groups(source_path, groups, opts) do
        require_copies(info, min_copies, target, Keyword.get(opts, :file_uuid), backups)
      end
    end
  rescue
    error -> {:error, "Error storing file: #{inspect(error)}"}
  end

  defp legacy_selection?(opts),
    do:
      Keyword.has_key?(opts, :redundancy_copies) or Keyword.get(opts, :priority_buckets, []) != []

  # What `profile` writes an object of `kind` to: per kind of bucket the buckets
  # in write order and how many copies it wants there (capped at the buckets it
  # can use), and how many copies an upload must make. A kind it wants no copy of
  # is not written, whatever buckets it has.
  defp profile_placement(profile, kind) do
    groups =
      for {_group, buckets, copies} <- placement_plan(profile),
          want = min(copies, length(buckets)),
          want > 0,
          do: {buckets, want}

    min_copies = if kind == :original, do: profile.min_copies_on_write, else: 1

    {groups, min_copies, backup_uuids(profile)}
  end

  # The buckets this profile keeps only as backups: never served, so a copy there
  # does not count toward the copies an upload must make.
  defp backup_uuids(profile) do
    for %{role: "backup"} = row <- profile.buckets,
        into: MapSet.new(),
        do: to_string(row.bucket_uuid)
  end

  # Writes each group's first `want` buckets, then, while a group has fewer than
  # `want` copies, its next ones one at a time: a bucket that fails does not cost
  # a copy while another of its kind could take it. A group that fails does not
  # fail the upload while another wrote: `require_copies/5` decides.
  defp store_groups(source_path, groups, opts) do
    destination_path = destination_path(source_path, opts)

    written =
      Enum.flat_map(groups, fn {buckets, want} ->
        write_group(source_path, buckets, want, destination_path, opts)
      end)

    if written == [] do
      {:error, "Failed to store file in any bucket"}
    else
      {:ok,
       %{
         destination_path: destination_path,
         stored_in: groups |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
         successful_storages: length(written),
         bucket_ids: Enum.map(written, & &1.uuid)
       }}
    end
  end

  defp write_group(source_path, buckets, want, destination_path, opts) do
    {first, spares} = Enum.split(buckets, want)
    written = write_to(source_path, first, destination_path, opts)

    Enum.reduce_while(spares, written, fn bucket, acc ->
      if length(acc) >= want,
        do: {:halt, acc},
        else: {:cont, acc ++ write_to(source_path, [bucket], destination_path, opts)}
    end)
  end

  @doc false
  # Per kind of bucket (`:local`, then `:cloud`): `{kind, buckets, copies}`, the
  # buckets `profile` may write to in write order (enabled, active in the
  # profile, not over capacity; by role, then fixed write priority, then the
  # shuffled pool) and how many copies the profile wants there, not capped.
  def placement_plan(profile) do
    by_kind =
      profile.buckets
      |> Enum.filter(fn row ->
        row.status == "active" and match?(%{enabled: true}, row.bucket) and
          not bucket_full?(row.bucket)
      end)
      |> Enum.group_by(&Bucket.group(&1.bucket))

    for kind <- [:local, :cloud] do
      buckets =
        by_kind
        |> Map.get(kind, [])
        |> Enum.group_by(& &1.role)
        |> then(fn by_role ->
          Enum.flat_map(ProfileBucket.roles(), fn role ->
            {fixed, pool} = by_role |> Map.get(role, []) |> Enum.split_with(& &1.write_priority)
            Enum.sort_by(fixed, & &1.write_priority) ++ Enum.shuffle(pool)
          end)
        end)
        |> Enum.map(& &1.bucket)

      {kind, buckets, Profiles.copies(profile, kind)}
    end
  end

  @doc false
  # Every bucket `placement_plan/1` lists, whatever the copy counts.
  def placement_candidates(profile) do
    profile |> placement_plan() |> Enum.flat_map(&elem(&1, 1))
  end

  # Fewer copies than an original needs undo the write; fewer than wanted
  # are reported, for the reconciler. Keys are content-addressed: when a
  # row already names this key (another upload of the same bytes, not yet
  # a dedup donor), the object was there before this write, and stays.
  # `file_uuid` is the row the write is for, if it has one yet.
  defp require_copies(info, min_copies, target, file_uuid, backups) do
    written = info.successful_storages

    # A copy on a backup is not a copy anyone can be served from: only the
    # others count toward the minimum, or a backup alone could satisfy an upload
    # whose file then could not be opened.
    servable = Enum.count(info.bucket_ids, &(to_string(&1) not in backups))

    if servable < min_copies do
      :ok = Storage.undo_store(info.destination_path, info.bucket_ids, file_uuid)

      {:error, "Stored #{servable} of the #{min_copies} copies required"}
    else
      {:ok, Map.put(info, :complete?, written >= target)}
    end
  end

  # Capacity (G9): a bucket with a `max_size_mb` is full when what its
  # active locations hold reaches it. The sum is cached for a minute per
  # bucket; a bucket with no cap is never full.
  @usage_ttl 60_000

  defp bucket_full?(%{max_size_mb: max} = bucket) when is_integer(max) and max > 0 do
    key = {:phoenix_kit_bucket_usage, to_string(bucket.uuid)}
    now = System.monotonic_time(:millisecond)

    used =
      case :persistent_term.get(key, nil) do
        {at, used} when now - at < @usage_ttl ->
          used

        _ ->
          used = Storage.calculate_bucket_usage(bucket.uuid)
          :persistent_term.put(key, {now, used})
          used
      end

    used >= max
  rescue
    _ -> false
  end

  defp bucket_full?(_bucket), do: false

  @doc """
  Retrieves a file from storage with failover.

  Tries each bucket in priority order until the file is found.
  """
  def retrieve_file(file_path, opts \\ []) do
    {located, fallback} =
      read_order(file_path, Keyword.get(opts, :priority_buckets, []), :read)

    case retrieve_with_failover(file_path, located, opts) do
      {:ok, path, _bucket} ->
        {:ok, path}

      {:error, _} ->
        case retrieve_with_failover(file_path, fallback, opts) do
          {:ok, path, bucket} ->
            Locations.record(file_path, bucket.uuid)
            {:ok, path}

          error ->
            error
        end
    end
  end

  @doc """
  Deletes a file from all storage buckets.
  """
  def delete_file(file_path, opts \\ []) do
    priority_buckets = Keyword.get(opts, :priority_buckets, [])
    buckets = select_buckets_for_retrieval(priority_buckets)

    results =
      buckets
      |> Enum.map(fn bucket ->
        provider = get_provider_for_bucket(bucket)
        result = provider.delete_file(bucket, file_path)
        unless result == :ok, do: report(bucket, "delete", result)
        result
      end)

    # Return success if at least one deletion succeeded
    if Enum.any?(results, &(&1 == :ok)) do
      :ok
    else
      {:error, "Failed to delete file from all buckets"}
    end
  end

  @doc """
  Checks if a file exists in any storage bucket.
  """
  def file_exists?(file_path, opts \\ []) do
    {located, fallback} =
      read_order(file_path, Keyword.get(opts, :priority_buckets, []), :read)

    holds? = fn bucket -> bucket_holds?(bucket, file_path) end

    Enum.any?(located, holds?) or
      case Enum.find(fallback, holds?) do
        nil ->
          false

        bucket ->
          Locations.record(file_path, bucket.uuid)
          true
      end
  end

  @doc """
  Gets a public URL for a file from the highest priority bucket that has it.
  """
  def public_url(file_path, opts \\ []) do
    {located, fallback} =
      read_order(
        file_path,
        Keyword.get(opts, :priority_buckets, []),
        :serve,
        Keyword.get(opts, :file_uuid)
      )

    url_from = fn bucket, record? ->
      # Only a public bucket hands out a plain object URL: a private or
      # signed one answers it with a denial, so it is not a URL to give out.
      if public_bucket?(bucket) and bucket_holds?(bucket, file_path) do
        if record?, do: Locations.record(file_path, bucket.uuid)
        get_provider_for_bucket(bucket).public_url(bucket, file_path)
      end
    end

    Enum.find_value(located, &url_from.(&1, false)) ||
      Enum.find_value(fallback, &url_from.(&1, true))
  end

  @doc """
  Replicates a file to specific target buckets.

  Retrieves the file from any available bucket, then stores it to
  each target bucket. Returns the list of bucket UUIDs that succeeded.
  """
  def replicate_to_buckets(file_path, target_buckets, opts \\ []) do
    # First retrieve the file to a temp location
    temp_path = generate_temp_path() <> Path.extname(file_path)

    case retrieve_file(file_path, destination_path: temp_path) do
      {:ok, local_path} ->
        try do
          store_across_buckets(local_path, target_buckets, [{:path_prefix, file_path} | opts])
        after
          File.rm(local_path)
        end

      {:error, reason} ->
        {:error, "Cannot retrieve source file for replication: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Replication failed: #{inspect(error)}"}
  end

  @doc """
  Whether `bucket` has the object at `key`: the reconciler's check that a
  copy it made is really there before it unlinks another. A bucket that
  raises does not have it.
  """
  def holds?(bucket, key), do: bucket_holds?(bucket, key)

  @doc """
  The SHA-256 (lower-case hex) and size of the object at `key` in `bucket`
  alone, read from that bucket and from no other: what "verify this copy"
  needs, since `retrieve_file/2` would fail over to a bucket that has it.

  `{:error, :not_found}` when the bucket does not hold it, `{:error, reason}`
  when it could not be read. The object is streamed through the hash and the
  temporary copy is removed.
  """
  @spec checksum_in(Bucket.t(), String.t()) ::
          {:ok, %{checksum: String.t(), size: non_neg_integer()}} | {:error, term()}
  def checksum_in(%Bucket{} = bucket, key) when is_binary(key) do
    provider = get_provider_for_bucket(bucket)

    if bucket_holds?(bucket, key) do
      destination = generate_temp_path() <> temp_extension(key)

      try do
        case safe_retrieve(provider, bucket, key, destination) do
          :ok -> {:ok, hash_file(destination)}
          {:error, reason} -> {:error, reason}
        end
      after
        File.rm(destination)
      end
    else
      {:error, :not_found}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp hash_file(path) do
    {hash, size} =
      path
      |> File.stream!(65_536)
      |> Enum.reduce({:crypto.hash_init(:sha256), 0}, fn chunk, {state, size} ->
        {:crypto.hash_update(state, chunk), size + byte_size(chunk)}
      end)

    %{checksum: hash |> :crypto.hash_final() |> Base.encode16(case: :lower), size: size}
  end

  @doc """
  Deletes the object at `key` from `bucket` only, never from any other
  bucket. `Storage.unlink_location/2` is what decides that nothing else on
  that bucket needs it (G11).
  """
  def delete_from_bucket(bucket, key) do
    result = get_provider_for_bucket(bucket).delete_file(bucket, key)
    unless result == :ok, do: report(bucket, "delete", result)
    result
  rescue
    error ->
      report(bucket, "delete", error)
      {:error, Exception.message(error)}
  end

  # Private functions

  defp select_buckets_for_storage(redundancy_copies, priority_buckets) do
    if Enum.empty?(priority_buckets) do
      # Get fresh bucket list from database (don't use cache for selection)
      # This ensures we get the current state and can shuffle properly
      all_buckets = Storage.list_enabled_buckets()

      # Separate buckets by priority
      {auto_priority_buckets, fixed_priority_buckets} =
        Enum.split_with(all_buckets, &(&1.priority == 0))

      # Shuffle auto-priority buckets (priority = 0) for random distribution
      # Fixed priority buckets are deterministic
      shuffled_auto = Enum.shuffle(auto_priority_buckets)

      # Combine: fixed priority buckets first (sorted), then shuffled auto-priority
      (Enum.sort_by(fixed_priority_buckets, & &1.priority) ++ shuffled_auto)
      |> Enum.take(redundancy_copies)
    else
      # Use specified buckets
      Storage.list_enabled_buckets()
      |> Enum.filter(&(&1.uuid in priority_buckets))
      |> Enum.take(redundancy_copies)
    end
  end

  # Whether `bucket` has the object. A bucket that raises (credentials, a
  # timeout) does not have it, for this request: the next bucket is tried
  # instead of the whole read failing. The recorded buckets are tried first
  # now, so a sick one must not take a file down that another copy serves.
  defp bucket_holds?(bucket, file_path) do
    get_provider_for_bucket(bucket).file_exists?(bucket, file_path)
  rescue
    error ->
      Logger.warning(
        "Storage: could not check #{file_path} on bucket #{bucket.name}: #{Exception.message(error)}"
      )

      report(bucket, "read", error)
      false
  end

  # Exactly these buckets, enabled ones only, in the order given. Looked up by
  # uuid rather than in the site's pool: an edit's output goes where the key it
  # replaces is, and that may be a user's own bucket (V206).
  defp forced_buckets(bucket_uuids) do
    uuids = bucket_uuids |> Enum.map(&to_string/1) |> Enum.uniq()

    enabled =
      uuids
      |> Storage.get_buckets()
      |> Enum.filter(& &1.enabled)
      |> Map.new(&{to_string(&1.uuid), &1})

    Enum.flat_map(uuids, &List.wrap(Map.get(enabled, &1)))
  end

  defp select_buckets_for_retrieval(priority_buckets) do
    if Enum.empty?(priority_buckets) do
      # Use all enabled buckets ordered by priority (simple sort, no usage calculation needed for retrieval)
      get_enabled_buckets()
      |> Enum.sort_by(& &1.priority)
    else
      # Use specified buckets
      get_enabled_buckets()
      |> Enum.filter(&(&1.uuid in priority_buckets))
    end
  end

  # The buckets to read `file_path` from: `{located, fallback}`. With no
  # buckets named, the enabled ones its location rows name come first, in
  # the order its file's storage profile serves from (V205,
  # `Locations.ranked/2`), and every other enabled bucket is the fallback,
  # by priority. `purpose` is `:serve` (to a client: a backup copy is never
  # served, and not probed either) or `:read` (bytes to process, or whether
  # the object exists: a backup may be used, last). Named buckets are used
  # as they are, with no fallback.
  #
  # `file_uuid` (serving) is the file whose copy is wanted: its own profile
  # ranks the buckets, and a bucket it marks `backup` is not probed either.
  @doc false
  def read_order(file_path, priority_buckets, purpose, file_uuid \\ nil)

  def read_order(file_path, [], purpose, file_uuid) do
    case Locations.ranked(file_path, file_uuid) do
      # Checked and found in no bucket: not asked about again on every
      # request (the backfill remembered the miss).
      [] ->
        if Locations.known_missing?(file_path),
          do: {[], []},
          else: {[], serve_fallback(select_buckets_for_retrieval([]), purpose, file_uuid)}

      ranked ->
        enabled = select_buckets_for_retrieval([])
        by_uuid = enabled |> Map.new(&{to_string(&1.uuid), &1}) |> with_owned_buckets(ranked)
        named = MapSet.new(ranked, & &1.bucket_uuid)

        located =
          ranked
          |> Enum.reject(&(purpose == :serve and &1.role == "backup"))
          |> Enum.flat_map(&List.wrap(Map.get(by_uuid, &1.bucket_uuid)))

        fallback = Enum.reject(enabled, &MapSet.member?(named, to_string(&1.uuid)))
        {located, serve_fallback(fallback, purpose, file_uuid)}
    end
  end

  def read_order(_file_path, priority_buckets, _purpose, _file_uuid),
    do: {select_buckets_for_retrieval(priority_buckets), []}

  # A user's own bucket (V206) is not in the site's pool, so the located
  # buckets that are not there are looked up by uuid, and only an enabled,
  # user-owned one is added: a site bucket that is disabled or gone stays out,
  # exactly as before. This is the ONLY way a user's bucket is reached for a
  # read: the fallback that tries every other bucket is built from the site's
  # pool alone, so a miss never probes anyone's own storage.
  defp with_owned_buckets(by_uuid, ranked) do
    missing = for %{bucket_uuid: uuid} <- ranked, not Map.has_key?(by_uuid, uuid), do: uuid

    missing
    |> Storage.get_buckets()
    |> Enum.filter(&(&1.enabled and is_binary(&1.owner_uuid)))
    |> Enum.reduce(by_uuid, &Map.put(&2, to_string(&1.uuid), &1))
  end

  defp serve_fallback(buckets, :serve, file_uuid) when not is_nil(file_uuid) do
    backups = Locations.backup_buckets(file_uuid)
    Enum.reject(buckets, &(to_string(&1.uuid) in backups))
  end

  defp serve_fallback(buckets, _purpose, _file_uuid), do: buckets

  defp store_across_buckets(source_path, buckets, opts) do
    destination_path = destination_path(source_path, opts)
    successful_buckets = write_to(source_path, buckets, destination_path, opts)

    if successful_buckets != [] do
      file_info = %{
        destination_path: destination_path,
        stored_in: length(buckets),
        successful_storages: length(successful_buckets),
        bucket_ids: Enum.map(successful_buckets, & &1.uuid)
      }

      {:ok, file_info}
    else
      {:error, "Failed to store file in any bucket"}
    end
  end

  # Use path_prefix if provided, otherwise generate a path
  defp destination_path(source_path, opts) do
    case Keyword.get(opts, :path_prefix) do
      nil -> generate_destination_path(source_path, opts)
      path_prefix -> path_prefix
    end
  end

  # The buckets of `buckets` the object was written to. A bucket that raises
  # failed, like one that errors.
  defp write_to(source_path, buckets, destination_path, opts) do
    Enum.filter(buckets, fn bucket ->
      provider = get_provider_for_bucket(bucket)

      result =
        try do
          provider.store_file(bucket, source_path, destination_path, opts)
        rescue
          error -> {:error, Exception.message(error)}
        end

      ok? = result == :ok or match?({:ok, _}, result)
      unless ok?, do: report(bucket, "write", result)
      ok?
    end)
  end

  defp retrieve_with_failover(_file_path, [], _opts), do: {:error, "File not found in any bucket"}

  defp retrieve_with_failover(file_path, [bucket | remaining_buckets], opts) do
    provider = get_provider_for_bucket(bucket)

    destination_path =
      Keyword.get(opts, :destination_path, generate_temp_path() <> temp_extension(file_path))

    case safe_retrieve(provider, bucket, file_path, destination_path) do
      :ok ->
        {:ok, destination_path, bucket}

      {:error, reason} ->
        Logger.debug(
          "Storage: #{file_path} not read from bucket #{bucket.name}: #{inspect(reason)}"
        )

        retrieve_with_failover(file_path, remaining_buckets, opts)
    end
  end

  # A bucket that raises while reading fails over like one that errors.
  defp safe_retrieve(provider, bucket, file_path, destination_path) do
    case provider.retrieve_file(bucket, file_path, destination_path) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        report(bucket, "read", error)
        error
    end
  rescue
    error ->
      report(bucket, "read", error)
      {:error, Exception.message(error)}
  end

  # What a bucket got wrong goes to its log (`Storage.BucketLog`): in the
  # background, never in the way of the request. A miss is not a failure.
  defp report(bucket, kind, {:error, reason}), do: BucketLog.record_failure(bucket, kind, reason)
  defp report(bucket, kind, reason), do: BucketLog.record_failure(bucket, kind, reason)

  defp get_provider_for_bucket(bucket) do
    {:ok, provider_module} = ProviderRegistry.get_provider(bucket.provider)
    provider_module
  end

  defp generate_destination_path(source_path, opts) do
    original_name = Path.basename(source_path)
    extension = Path.extname(original_name)
    base_name = Path.rootname(original_name)

    timestamp = UtilsDate.utc_now() |> DateTime.to_iso8601()
    random_suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    prefix = Keyword.get(opts, :path_prefix, "")
    subdir = Keyword.get(opts, :subdir, timestamp)

    Path.join([prefix, subdir, "#{base_name}_#{random_suffix}#{extension}"])
  end

  defp generate_temp_path do
    temp_dir = System.tmp_dir!()
    random_name = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(temp_dir, "phoenix_kit_#{random_name}")
  end

  @doc false
  # The extension a processing temp copy of `file_path` should carry.
  #
  # ImageMagick identifies some formats (ICO among them) by extension alone,
  # so an extensionless copy fails with "no decode delegate". But the stored
  # extension is the uploader's filename, and an extension also *selects*
  # the coders that have no magic bytes to sniff — MVG, MSL, TXT — which an
  # extensionless copy never reaches. So it is kept only when it names a
  # media type (image, video, audio, PDF); `.mvg` uploaded as `image/png`
  # gets no extension and ImageMagick still reads it by content alone.
  @spec temp_extension(String.t()) :: String.t()
  def temp_extension(file_path) do
    case MIME.from_path(file_path) do
      "image/" <> _ -> Path.extname(file_path)
      "video/" <> _ -> Path.extname(file_path)
      "audio/" <> _ -> Path.extname(file_path)
      "application/pdf" -> Path.extname(file_path)
      _ -> ""
    end
  end

  @doc """
  Drops the cached list of enabled buckets, so the next read sees the
  database. Called whenever a bucket is created, updated or deleted. The
  cache only spares a query per file request; it expires on its own after
  five minutes, which is how long a bucket edit used to take to apply.
  """
  def invalidate_bucket_cache do
    :persistent_term.erase(:phoenix_kit_buckets_cache)
    :ok
  end

  defp get_enabled_buckets do
    # Cache bucket list to avoid querying on every file request
    cache_key = :phoenix_kit_buckets_cache
    current_time = System.monotonic_time(:millisecond)

    case :persistent_term.get(cache_key, nil) do
      {timestamp, buckets} when current_time - timestamp < @buckets_cache_ttl ->
        # Cache hit - return cached buckets
        buckets

      _ ->
        # Cache miss or expired - fetch fresh buckets
        buckets = Storage.list_enabled_buckets()
        :persistent_term.put(cache_key, {current_time, buckets})
        buckets
    end
  end

  @doc """
  Returns the local filesystem path for a file if stored locally.

  This function checks enabled buckets with "local" provider and returns the
  direct path to the file if it exists. This allows serving files directly
  without copying to a temp file first.

  ## Returns

  - `{:ok, path}` - File exists at the local path
  - `{:error, :not_local}` - No local bucket contains the file
  """
  def get_local_file_path(file_path, opts \\ []),
    do: local_path(file_path, read_order(file_path, [], :serve, Keyword.get(opts, :file_uuid)))

  defp local_path(file_path, {located, fallback}) do
    Enum.find_value(located, &local_hit(&1, file_path, false)) ||
      Enum.find_value(fallback, {:error, :not_local}, &local_hit(&1, file_path, true))
  end

  # `{:ok, path}` when `bucket` is local and holds `file_path`; a hit found
  # by probing (`record?`) is recorded as a location.
  defp local_hit(%{provider: "local"} = bucket, file_path, record?) do
    full_path = Path.join(Local.root(bucket), file_path)

    if File.exists?(full_path) do
      if record?, do: Locations.record(file_path, bucket.uuid)
      {:ok, full_path}
    end
  end

  defp local_hit(_bucket, _file_path, _record?), do: nil

  @doc """
  Returns file access info based on bucket access_type.

  Determines how a file should be served based on its storage location:
  - Local files are always served directly
  - Remote files depend on bucket's access_type setting

  ## Returns

  - `{:local, path}` - File is local, serve directly from filesystem
  - `{:redirect, url}` - Redirect to public URL (for public buckets)
  - `{:signed_redirect, url}` - Redirect to a short-lived signed URL (a
    public bucket, with `:download` given)
  - `{:proxy, file_name}` - Download and proxy through server (for private buckets)
  - `{:error, :not_found}` - File not found in any bucket

  ## Options

  - `:download` - response headers (`:disposition`, `:content_type`) for a
    file that must download rather than render. A public bucket's plain
    object URL answers with the object's stored headers, so for such a file
    a public bucket hands out a signed URL that overrides them
    (`c:PhoenixKit.Modules.Storage.Provider.signed_download_url/3`), or is
    proxied when its provider cannot sign one.
  """
  def get_file_access(file_name, opts \\ []) do
    download = Keyword.get(opts, :download)
    {located, fallback} = read_order(file_name, [], :serve, Keyword.get(opts, :file_uuid))

    # The recorded copies in the profile's serve order (G3: a remote copy
    # may come before a local one); then, for a key with no rows yet,
    # today's rule: a local copy first.
    Enum.find_value(located, &serve_from(&1, file_name, download, false)) ||
      fallback_access(file_name, fallback, download)
  end

  defp fallback_access(file_name, fallback, download) do
    {local, remote} = Enum.split_with(fallback, &(&1.provider == "local"))

    Enum.find_value(local, &serve_from(&1, file_name, download, true)) ||
      Enum.find_value(remote, {:error, :not_found}, &serve_from(&1, file_name, download, true))
  end

  defp serve_from(%{provider: "local"} = bucket, file_name, _download, record?) do
    with {:ok, path} <- local_hit(bucket, file_name, record?), do: {:local, path}
  end

  defp serve_from(bucket, file_name, download, record?),
    do: check_bucket_for_file(bucket, file_name, download, record?)

  defp check_bucket_for_file(bucket, file_name, download, record?) do
    provider = get_provider_for_bucket(bucket)

    if bucket_holds?(bucket, file_name) do
      if record?, do: Locations.record(file_name, bucket.uuid)
      bucket_access(bucket, file_name, provider, download)
    end
  end

  defp public_bucket?(%{access_type: type}) when type in ["private", "signed"], do: false
  defp public_bucket?(_bucket), do: true

  # How long a `"signed"` bucket's URL for one request lives.
  @signed_url_seconds 300

  @doc false
  # How a remote bucket that holds `file_name` serves it. Public and
  # `@doc false` only so the decision is testable without a live bucket.
  def bucket_access(%{access_type: "private"}, file_name, _provider, _download) do
    {:proxy, file_name}
  end

  # A `"signed"` bucket is served by a short-lived presigned URL made for
  # this request, never by its plain object URL; proxied when the provider
  # cannot sign.
  def bucket_access(%{access_type: "signed"} = bucket, file_name, provider, download) do
    opts = Keyword.put(download || [], :expires_in, @signed_url_seconds)

    with true <- Code.ensure_loaded?(provider),
         true <- function_exported?(provider, :signed_download_url, 3),
         {:ok, url} <- provider.signed_download_url(bucket, file_name, opts) do
      {:signed_redirect, url}
    else
      _ -> {:proxy, file_name}
    end
  end

  # "public" or nil (default), for a file that must download.
  def bucket_access(bucket, file_name, provider, download) when is_list(download) do
    with true <- Code.ensure_loaded?(provider),
         true <- function_exported?(provider, :signed_download_url, 3),
         {:ok, url} <- provider.signed_download_url(bucket, file_name, download) do
      {:signed_redirect, url}
    else
      _ -> {:proxy, file_name}
    end
  end

  # A public bucket whose provider has no public URL for the object (an R2
  # bucket with no public domain) is proxied: the object is there, it just
  # cannot be linked to.
  def bucket_access(bucket, file_name, provider, nil) do
    case provider.public_url(bucket, file_name) do
      nil -> {:proxy, file_name}
      url -> {:redirect, url}
    end
  end
end
