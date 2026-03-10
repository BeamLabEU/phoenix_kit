defmodule PhoenixKit.Modules.Publishing.ListingCache do
  @moduledoc """
  Caches publishing group listing metadata in :persistent_term for sub-millisecond reads.

  Instead of querying the database on every request, the listing page reads from
  an in-memory cache populated from the database.

  ## How It Works

  1. When a post is created/updated/published, `regenerate/1` is called
  2. This queries the database and stores post metadata in :persistent_term
  3. `render_group_listing` reads from the in-memory cache
  4. Cache includes: title, slug, date, status, languages, versions (no content)

  ## Performance

  - Cache miss: ~20ms (DB query + store in :persistent_term)
  - Cache hit: ~0.1μs (direct memory access, no variance)

  ## Cache Invalidation

  Cache is regenerated when:
  - Post is created
  - Post is updated (metadata or content)
  - Post status changes (draft/published/archived)
  - Translation is added
  - Version is created

  ## In-Memory Caching with :persistent_term

  For sub-millisecond performance, parsed cache data is stored in `:persistent_term`.

  - First read after restart: queries DB, stores in :persistent_term (~20ms)
  - Subsequent reads: direct memory access (~0.1μs, no variance)
  - On regenerate: updates :persistent_term from DB
  - On invalidate: clears :persistent_term entry (next read triggers regeneration)
  """

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate

  require Logger

  @persistent_term_prefix :phoenix_kit_group_listing_cache
  @persistent_term_loaded_at_prefix :phoenix_kit_group_listing_cache_loaded_at
  @persistent_term_cache_generated_at_prefix :phoenix_kit_group_listing_cache_generated_at

  # ETS table for regeneration locks (provides atomic test-and-set via insert_new)
  @lock_table :phoenix_kit_listing_cache_locks

  # Settings keys for memory cache toggle
  @memory_cache_key "publishing_memory_cache_enabled"

  # Legacy settings key (read as fallback)
  @legacy_memory_cache_key "blogging_memory_cache_enabled"

  @doc """
  Reads the cached listing for a publishing group.

  Returns `{:ok, posts}` if cache exists and is valid.
  Returns `{:error, :cache_miss}` if cache doesn't exist or caching is disabled.

  Respects the `publishing_memory_cache_enabled` setting
  (with fallback to legacy `blogging_memory_cache_enabled` key).
  """
  @spec read(String.t()) :: {:ok, [map()]} | {:error, :cache_miss}
  def read(group_slug) do
    if memory_cache_enabled?() do
      term_key = persistent_term_key(group_slug)

      case safe_persistent_term_get(term_key) do
        {:ok, _} = hit ->
          hit

        :not_found ->
          # Cache miss — regenerate from database
          regenerate(group_slug)

          case safe_persistent_term_get(term_key) do
            {:ok, _} = hit -> hit
            :not_found -> {:error, :cache_miss}
          end
      end
    else
      {:error, :cache_miss}
    end
  end

  # Safely get from :persistent_term (returns :not_found instead of raising)
  defp safe_persistent_term_get(key) do
    {:ok, :persistent_term.get(key)}
  rescue
    ArgumentError -> :not_found
  end

  @doc """
  Regenerates the listing cache for a group.

  Queries the database for all posts and stores the metadata in :persistent_term.

  This should be called after any post operation that changes the listing:
  - create_post
  - update_post
  - add_language_to_post
  - create_new_version

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec regenerate(String.t()) :: :ok | {:error, any()}
  def regenerate(group_slug) do
    if memory_cache_enabled?() do
      do_regenerate(group_slug)
    else
      :ok
    end
  rescue
    error ->
      Logger.error(
        "[ListingCache] Failed to regenerate cache for #{group_slug}: #{inspect(error)}"
      )

      {:error, {:regenerate_failed, error}}
  end

  defp do_regenerate(group_slug) do
    start_time = System.monotonic_time(:millisecond)

    # Posts from to_listing_map are already atom-key maps with excerpts
    posts = DBStorage.list_posts_for_listing(group_slug)
    generated_at = UtilsDate.utc_now() |> DateTime.to_iso8601()

    safe_persistent_term_put(persistent_term_key(group_slug), posts)
    safe_persistent_term_put(loaded_at_key(group_slug), generated_at)
    safe_persistent_term_put(cache_generated_at_key(group_slug), generated_at)

    elapsed = System.monotonic_time(:millisecond) - start_time

    Logger.debug(
      "[ListingCache] Regenerated cache from DB for #{group_slug} (#{length(posts)} posts) in #{elapsed}ms"
    )

    PublishingPubSub.broadcast_cache_changed(group_slug)
    :ok
  rescue
    error ->
      Logger.error(
        "[ListingCache] Failed to regenerate cache for #{group_slug}: #{inspect(error)}"
      )

      {:error, {:regenerate_failed, error}}
  end

  # Lock timeout in milliseconds (30 seconds)
  # If a lock is older than this, it's considered stale (process likely died)
  @lock_timeout_ms 30_000

  @doc """
  Regenerates the cache if no other process is already regenerating it.

  This prevents the "thundering herd" problem where multiple concurrent requests
  all trigger cache regeneration simultaneously after a server restart.

  Uses ETS with `insert_new/2` for atomic lock acquisition - only one process
  can acquire the lock at a time. The lock includes a timestamp and will be
  considered stale after #{@lock_timeout_ms}ms to prevent permanent lockout
  if a process dies mid-regeneration.

  Returns:
  - `:ok` if regeneration was performed successfully
  - `:already_in_progress` if another process is currently regenerating
  - `{:error, reason}` if regeneration failed

  ## Usage

  On cache miss in read paths, use this instead of `regenerate/1`:

      case ListingCache.regenerate_if_not_in_progress(group_slug) do
        :ok -> # Cache is ready, read from it
        :already_in_progress -> # Another process is regenerating, try again later
        {:error, _} -> # Regeneration failed, query DB directly
      end
  """
  @spec regenerate_if_not_in_progress(String.t()) :: :ok | :already_in_progress | {:error, any()}
  def regenerate_if_not_in_progress(group_slug) do
    ensure_lock_table_exists()
    now = System.monotonic_time(:millisecond)

    # Try to atomically acquire the lock using ETS insert_new
    # Returns true if inserted (lock acquired), false if key already exists
    case :ets.insert_new(@lock_table, {group_slug, now}) do
      true ->
        # We acquired the lock - perform regeneration
        do_regenerate_with_lock(group_slug)

      false ->
        # Lock exists - check if it's stale
        handle_existing_lock(group_slug, now)
    end
  end

  # Handle case where lock already exists - check staleness
  defp handle_existing_lock(group_slug, now) do
    case :ets.lookup(@lock_table, group_slug) do
      [{^group_slug, lock_timestamp}] ->
        lock_age = now - lock_timestamp

        if lock_age < @lock_timeout_ms do
          # Lock is valid and recent - another process is regenerating
          Logger.debug(
            "[ListingCache] Regeneration already in progress for #{group_slug} (#{lock_age}ms ago), skipping"
          )

          :already_in_progress
        else
          # Lock is stale - previous process likely died
          # Try to take over by deleting and re-acquiring atomically
          take_over_stale_lock(group_slug, lock_timestamp, lock_age, now)
        end

      [] ->
        # Lock was released between insert_new and lookup - try again
        regenerate_if_not_in_progress(group_slug)
    end
  end

  # Attempt to take over a stale lock using compare-and-delete
  defp take_over_stale_lock(group_slug, old_timestamp, lock_age, now) do
    # Use match_delete for atomic compare-and-delete
    # Only deletes if the timestamp matches (no one else took over)
    case :ets.select_delete(@lock_table, [{{group_slug, old_timestamp}, [], [true]}]) do
      1 ->
        # Successfully deleted stale lock - now try to acquire
        Logger.warning(
          "[ListingCache] Found stale lock for #{group_slug} (#{lock_age}ms old), taking over regeneration"
        )

        case :ets.insert_new(@lock_table, {group_slug, now}) do
          true ->
            do_regenerate_with_lock(group_slug)

          false ->
            # Another process beat us to it
            :already_in_progress
        end

      0 ->
        # Lock was already taken over by another process or timestamp changed
        :already_in_progress
    end
  end

  # Perform regeneration while holding the lock
  defp do_regenerate_with_lock(group_slug) do
    result = regenerate(group_slug)

    case result do
      :ok -> :ok
      {:error, _} = error -> error
    end
  after
    # Always release the lock when done (success or failure)
    :ets.delete(@lock_table, group_slug)
  end

  # Ensure the ETS table for locks exists (lazy initialization)
  defp ensure_lock_table_exists do
    case :ets.whereis(@lock_table) do
      :undefined ->
        # Table doesn't exist - create it
        # Use :public so any process can read/write
        # Use :named_table so we can reference by atom
        # Use :set for key-value storage
        try do
          :ets.new(@lock_table, [:set, :public, :named_table])
        rescue
          ArgumentError ->
            # Table was created by another process between whereis and new
            :ok
        end

      _tid ->
        :ok
    end
  end

  # Safely put to :persistent_term (logs warning on failure instead of crashing)
  defp safe_persistent_term_put(key, value) do
    :persistent_term.put(key, value)
  rescue
    error ->
      Logger.warning("[ListingCache] Failed to write to :persistent_term: #{inspect(error)}")
      :error
  end

  @doc """
  Loads the cache from the database into :persistent_term.

  Returns `:ok` if successful or `{:error, reason}` on failure.
  """
  @spec load_into_memory(String.t()) :: :ok | {:error, any()}
  def load_into_memory(group_slug) do
    load_into_memory_from_db(group_slug)
  end

  defp load_into_memory_from_db(group_slug) do
    posts = DBStorage.list_posts_for_listing(group_slug)
    generated_at = UtilsDate.utc_now() |> DateTime.to_iso8601()

    safe_persistent_term_put(persistent_term_key(group_slug), posts)
    safe_persistent_term_put(loaded_at_key(group_slug), generated_at)
    safe_persistent_term_put(cache_generated_at_key(group_slug), generated_at)

    Logger.debug(
      "[ListingCache] Loaded #{group_slug} from DB into :persistent_term (#{length(posts)} posts)"
    )

    PublishingPubSub.broadcast_cache_changed(group_slug)
    :ok
  rescue
    error ->
      Logger.error("[ListingCache] Failed to load #{group_slug} from DB: #{inspect(error)}")

      {:error, {:load_failed, error}}
  end

  @doc """
  Invalidates (clears) the cache for a group.

  Clears the :persistent_term entries. The next read will trigger
  a regeneration from the database.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(group_slug) do
    # Clear :persistent_term entries
    term_key = persistent_term_key(group_slug)

    try do
      :persistent_term.erase(term_key)
    rescue
      ArgumentError -> :ok
    end

    try do
      :persistent_term.erase(loaded_at_key(group_slug))
    rescue
      ArgumentError -> :ok
    end

    try do
      :persistent_term.erase(cache_generated_at_key(group_slug))
    rescue
      ArgumentError -> :ok
    end

    Logger.debug("[ListingCache] Invalidated cache for #{group_slug}")
    :ok
  end

  @doc """
  Checks if a cache exists for a group in :persistent_term.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(group_slug) do
    case safe_persistent_term_get(persistent_term_key(group_slug)) do
      {:ok, _} -> true
      :not_found -> false
    end
  end

  @doc """
  Finds a post by slug in the cache.

  This is useful for single post views where we need metadata (language_statuses,
  version_statuses, allow_version_access) without a separate DB query.

  Returns `{:ok, cached_post}` if found, `{:error, :not_found}` otherwise.
  """
  @spec find_post(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found | :cache_miss}
  def find_post(group_slug, post_slug) do
    case read(group_slug) do
      {:ok, posts} ->
        case Enum.find(posts, fn p -> p.slug == post_slug end) do
          nil -> {:error, :not_found}
          post -> {:ok, post}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Finds a post by path pattern in the cache (for timestamp mode).

  Matches posts where the path contains the date/time pattern.
  Returns `{:ok, cached_post}` if found, `{:error, :not_found}` otherwise.
  """
  @spec find_post_by_path(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :cache_miss}
  def find_post_by_path(group_slug, date, time) do
    case read(group_slug) do
      {:ok, posts} ->
        # Match posts using discrete date and time fields (more robust than path string matching)
        # Parse the input date string to compare with the cached Date struct
        target_date = parse_date_for_lookup(date)
        # Normalize time format (handles both "HH:MM" and "HH:MM:SS")
        target_time = normalize_time_for_lookup(time)

        case Enum.find(posts, fn p ->
               dates_match?(p.date, target_date) && times_match?(p.time, target_time)
             end) do
          nil -> {:error, :not_found}
          post -> {:ok, post}
        end

      {:error, _} = error ->
        error
    end
  end

  # Parse date string for lookup comparison
  defp parse_date_for_lookup(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      _ -> date_str
    end
  end

  defp parse_date_for_lookup(date), do: date

  # Normalize time to "HH:MM" format for comparison
  defp normalize_time_for_lookup(time_str) when is_binary(time_str) do
    # Take just HH:MM portion
    String.slice(time_str, 0, 5)
  end

  defp normalize_time_for_lookup(time), do: time

  # Compare dates - handles both Date structs and strings
  defp dates_match?(nil, _), do: false
  defp dates_match?(_, nil), do: false

  defp dates_match?(%Date{} = cached, %Date{} = target) do
    Date.compare(cached, target) == :eq
  end

  defp dates_match?(%Date{} = cached, target_str) when is_binary(target_str) do
    Date.to_iso8601(cached) == target_str
  end

  defp dates_match?(_, _), do: false

  # Compare times - handles Time structs and "HH:MM" strings
  defp times_match?(nil, _), do: false
  defp times_match?(_, nil), do: false

  defp times_match?(%Time{} = cached, target_str) when is_binary(target_str) do
    # Format cached time as HH:MM and compare
    cached_str = cached |> Time.to_string() |> String.slice(0, 5)
    cached_str == target_str
  end

  defp times_match?(cached_str, target_str)
       when is_binary(cached_str) and is_binary(target_str) do
    String.slice(cached_str, 0, 5) == String.slice(target_str, 0, 5)
  end

  defp times_match?(_, _), do: false

  @doc """
  Finds a post by URL slug for a specific language.

  This enables O(1) lookup from URL slug to internal identifier, supporting
  per-language URL slugs for SEO-friendly localized URLs.

  ## Parameters
  - `group_slug` - The publishing group
  - `language` - The language code to search in
  - `url_slug` - The URL slug to find

  ## Returns
  - `{:ok, cached_post}` - Found post (includes internal `slug` for DB lookup)
  - `{:error, :not_found}` - No post with this URL slug for this language
  - `{:error, :cache_miss}` - Cache not available
  """
  @spec find_by_url_slug(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :cache_miss}
  def find_by_url_slug(group_slug, language, url_slug) do
    case read(group_slug) do
      {:ok, posts} -> find_post_by_url_slug(posts, language, url_slug)
      {:error, _} -> {:error, :cache_miss}
    end
  end

  defp find_post_by_url_slug(posts, language, url_slug) do
    # Search by language_slugs map first
    by_language_slug =
      Enum.find(posts, &(Map.get(&1.language_slugs || %{}, language) == url_slug))

    # Fallback: match by directory slug (backward compatibility)
    by_directory_slug = Enum.find(posts, &(&1.slug == url_slug))

    case by_language_slug || by_directory_slug do
      nil -> {:error, :not_found}
      post -> {:ok, post}
    end
  end

  @doc """
  Finds a post by a previous URL slug for 301 redirects.

  When a URL slug changes, the old slug is stored in `previous_url_slugs`.
  This function finds posts that previously used the given URL slug.

  ## Returns
  - `{:ok, cached_post}` - Found post that previously used this slug
  - `{:error, :not_found}` - No post with this previous slug
  - `{:error, :cache_miss}` - Cache not available
  """
  @spec find_by_previous_url_slug(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :cache_miss}
  def find_by_previous_url_slug(group_slug, language, url_slug) do
    case read(group_slug) do
      {:ok, posts} -> find_post_by_previous_slug(posts, language, url_slug)
      {:error, _} -> {:error, :cache_miss}
    end
  end

  defp find_post_by_previous_slug(posts, language, url_slug) do
    case Enum.find(posts, &post_has_previous_slug?(&1, language, url_slug)) do
      nil -> {:error, :not_found}
      post -> {:ok, post}
    end
  end

  defp post_has_previous_slug?(post, language, url_slug) do
    # Check the per-language previous slugs map first
    lang_previous_slugs = Map.get(post, :language_previous_slugs) || %{}
    previous_for_lang = Map.get(lang_previous_slugs, language) || []

    # Fallback: check metadata.previous_url_slugs for backward compatibility
    metadata_previous = Map.get(post.metadata || %{}, :previous_url_slugs) || []

    url_slug in previous_for_lang or url_slug in metadata_previous
  end

  @doc """
  Returns the :persistent_term key for a publishing group's cache.
  """
  @spec persistent_term_key(String.t()) :: tuple()
  def persistent_term_key(group_slug) do
    {@persistent_term_prefix, group_slug}
  end

  @doc """
  Returns the :persistent_term key for tracking when the memory cache was loaded.
  """
  @spec loaded_at_key(String.t()) :: tuple()
  def loaded_at_key(group_slug) do
    {@persistent_term_loaded_at_prefix, group_slug}
  end

  @doc """
  Returns when the memory cache was loaded (ISO 8601 string), or nil if not loaded.
  """
  @spec memory_loaded_at(String.t()) :: String.t() | nil
  def memory_loaded_at(group_slug) do
    case safe_persistent_term_get(loaded_at_key(group_slug)) do
      {:ok, loaded_at} -> loaded_at
      :not_found -> nil
    end
  end

  @doc """
  Returns the :persistent_term key for tracking when the cache was last generated.
  """
  @spec cache_generated_at_key(String.t()) :: tuple()
  def cache_generated_at_key(group_slug) do
    {@persistent_term_cache_generated_at_prefix, group_slug}
  end

  @doc """
  Returns the timestamp of when the cache was last generated from the database.
  """
  @spec cache_generated_at(String.t()) :: String.t() | nil
  def cache_generated_at(group_slug) do
    case safe_persistent_term_get(cache_generated_at_key(group_slug)) do
      {:ok, generated_at} -> generated_at
      :not_found -> nil
    end
  end

  @doc """
  Returns whether memory caching (:persistent_term) is enabled.
  Uses cached settings to avoid database queries on every call.
  Checks new key first, falls back to legacy key.
  """
  @spec memory_cache_enabled?() :: boolean()
  def memory_cache_enabled? do
    case Settings.get_setting_cached(@memory_cache_key, nil) do
      nil -> Settings.get_setting_cached(@legacy_memory_cache_key, "true") == "true"
      value -> value == "true"
    end
  end

  @doc """
  Returns a list of posts that need primary_language migration.

  This checks all posts in a group and returns those that either:
  1. Have no `primary_language` stored (need backfill)
  2. Have `primary_language` different from global setting (need migration decision)
  """
  @spec posts_needing_primary_language_migration(String.t()) :: [map()]
  def posts_needing_primary_language_migration(group_slug) do
    case read(group_slug) do
      {:ok, posts} ->
        global_primary = LanguageHelpers.get_primary_language()

        Enum.filter(posts, fn post ->
          # Use atom key since normalized posts use atoms
          stored_primary = post[:primary_language]
          stored_primary == nil or stored_primary != global_primary
        end)

      {:error, _} ->
        # If cache doesn't exist, query DB directly
        scan_posts_needing_migration(group_slug)
    end
  end

  defp scan_posts_needing_migration(group_slug) do
    global_primary = LanguageHelpers.get_primary_language()

    DBStorage.list_posts_for_listing(group_slug)
    |> Enum.filter(fn post ->
      stored_primary = post[:primary_language]
      stored_primary == nil or stored_primary != global_primary
    end)
  end

  @doc """
  Counts posts by primary_language status in a group.

  Returns `%{current: n, needs_migration: n, needs_backfill: n}` where:
  - `current` - posts with primary_language matching global setting
  - `needs_migration` - posts with different primary_language (were created under old setting)
  - `needs_backfill` - posts with no primary_language stored (legacy posts)
  """
  @spec count_primary_language_status(String.t()) :: map()
  def count_primary_language_status(group_slug) do
    case read(group_slug) do
      {:ok, posts} ->
        global_primary = LanguageHelpers.get_primary_language()

        Enum.reduce(posts, %{current: 0, needs_migration: 0, needs_backfill: 0}, fn post, acc ->
          # Use atom key since normalized posts use atoms
          stored_primary = post[:primary_language]

          cond do
            stored_primary == nil ->
              %{acc | needs_backfill: acc.needs_backfill + 1}

            stored_primary == global_primary ->
              %{acc | current: acc.current + 1}

            true ->
              %{acc | needs_migration: acc.needs_migration + 1}
          end
        end)

      {:error, _} ->
        # If cache doesn't exist, query DB directly
        scan_primary_language_status(group_slug)
    end
  end

  defp scan_primary_language_status(group_slug) do
    global_primary = LanguageHelpers.get_primary_language()

    DBStorage.list_posts_for_listing(group_slug)
    |> Enum.reduce(%{current: 0, needs_migration: 0, needs_backfill: 0}, fn post, acc ->
      stored_primary = post[:primary_language]

      cond do
        stored_primary == nil ->
          %{acc | needs_backfill: acc.needs_backfill + 1}

        stored_primary == global_primary ->
          %{acc | current: acc.current + 1}

        true ->
          %{acc | needs_migration: acc.needs_migration + 1}
      end
    end)
  end
end
