defmodule PhoenixKit.Modules.Publishing.ListingCache do
  @moduledoc """
  Caches publishing group listing metadata to avoid expensive filesystem scans on every request.

  Instead of scanning 50+ files per request, the listing page reads a single
  `.listing_cache.json` file containing all post metadata.

  ## How It Works

  1. When a post is created/updated/published, `regenerate/1` is called
  2. This scans all posts and writes metadata to `.listing_cache.json`
  3. `render_blog_listing` reads from cache instead of scanning filesystem
  4. Cache includes: title, slug, date, status, languages, versions (no content)

  ## Cache File Location

      priv/publishing/{group-slug}/.listing_cache.json

  (With legacy fallback to `priv/blogging/{group-slug}/.listing_cache.json`)

  ## Performance

  - Before: ~500ms (50+ file operations)
  - After: ~20ms (1 file read + JSON parse)

  ## Cache Invalidation

  Cache is regenerated when:
  - Post is created
  - Post is updated (metadata or content)
  - Post status changes (draft/published/archived)
  - Translation is added
  - Version is created

  ## In-Memory Caching with :persistent_term

  For sub-millisecond performance, parsed cache data is stored in `:persistent_term`.

  - First read after restart: loads from file, parses JSON, stores in :persistent_term (~2ms)
  - Subsequent reads: direct memory access (~0.1μs, no variance)
  - On regenerate: updates both file and :persistent_term
  - On invalidate: clears :persistent_term entry

  The JSON file provides persistence across restarts. :persistent_term provides
  zero-copy, sub-microsecond reads during runtime.
  """

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Settings

  require Logger

  # Suppress dialyzer false positive for guard clause in read_from_file_and_cache
  @dialyzer {:nowarn_function, read_from_file_and_cache: 3}

  @cache_filename ".listing_cache.json"
  @persistent_term_prefix :phoenix_kit_blog_listing_cache
  @persistent_term_loaded_at_prefix :phoenix_kit_blog_listing_cache_loaded_at
  @persistent_term_file_generated_at_prefix :phoenix_kit_blog_listing_cache_file_generated_at

  # ETS table for regeneration locks (provides atomic test-and-set via insert_new)
  @lock_table :phoenix_kit_listing_cache_locks

  # New settings keys (write to these)
  @file_cache_key "publishing_file_cache_enabled"
  @memory_cache_key "publishing_memory_cache_enabled"

  # Legacy settings keys (read from these as fallback)
  @legacy_file_cache_key "blogging_file_cache_enabled"
  @legacy_memory_cache_key "blogging_memory_cache_enabled"

  @doc """
  Reads the cached listing for a publishing group.

  Returns `{:ok, posts}` if cache exists and is valid.
  Returns `{:error, :cache_miss}` if cache doesn't exist, is corrupt, or caching is disabled.

  Respects the `publishing_file_cache_enabled` and `publishing_memory_cache_enabled` settings
  (with fallback to legacy `blogging_*` keys).
  """
  @spec read(String.t()) :: {:ok, [map()]} | {:error, :cache_miss}
  def read(blog_slug) do
    memory_enabled = memory_cache_enabled?()
    file_enabled = file_cache_enabled?()
    term_key = persistent_term_key(blog_slug)

    cond do
      # Both caches disabled
      not memory_enabled and not file_enabled ->
        {:error, :cache_miss}

      # Memory enabled and found in persistent_term
      memory_enabled and memory_cache_hit?(term_key) ->
        safe_persistent_term_get(term_key)

      # Memory enabled but not found, try file
      memory_enabled and file_enabled ->
        read_from_file_and_cache(blog_slug, term_key, true)

      # Memory enabled, file disabled, not in memory
      memory_enabled ->
        {:error, :cache_miss}

      # Memory disabled, file enabled
      file_enabled ->
        read_from_file_only(blog_slug)

      # Fallback
      true ->
        {:error, :cache_miss}
    end
  end

  defp memory_cache_hit?(term_key) do
    case safe_persistent_term_get(term_key) do
      {:ok, _} -> true
      :not_found -> false
    end
  end

  # Safely get from :persistent_term (returns :not_found instead of raising)
  defp safe_persistent_term_get(key) do
    {:ok, :persistent_term.get(key)}
  rescue
    ArgumentError -> :not_found
  end

  # Read from JSON file and optionally store in :persistent_term
  defp read_from_file_and_cache(blog_slug, term_key, store_in_memory) do
    cache_path = cache_path(blog_slug)

    with {:ok, content} <- read_cache_file(cache_path),
         {:ok, normalized_posts, generated_at} <- parse_cache_content(content, blog_slug) do
      if store_in_memory do
        store_posts_in_memory(blog_slug, term_key, normalized_posts, generated_at)
      end

      {:ok, normalized_posts}
    end
  end

  defp read_cache_file(cache_path) do
    case File.read(cache_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :cache_miss}
      {:error, _reason} -> {:error, :cache_miss}
    end
  end

  defp parse_cache_content(content, blog_slug) do
    case Jason.decode(content) do
      {:ok, %{"posts" => posts} = data} ->
        normalized_posts = Enum.map(posts, &normalize_post/1)
        generated_at = Map.get(data, "generated_at")
        {:ok, normalized_posts, generated_at}

      {:ok, _} ->
        Logger.warning("[ListingCache] Invalid cache format for #{blog_slug}")
        {:error, :cache_miss}

      {:error, reason} ->
        Logger.warning(
          "[ListingCache] Failed to parse cache for #{blog_slug}: #{inspect(reason)}"
        )

        {:error, :cache_miss}
    end
  end

  defp store_posts_in_memory(blog_slug, term_key, normalized_posts, generated_at) do
    safe_persistent_term_put(term_key, normalized_posts)

    safe_persistent_term_put(
      loaded_at_key(blog_slug),
      DateTime.utc_now() |> DateTime.to_iso8601()
    )

    if generated_at do
      safe_persistent_term_put(file_generated_at_key(blog_slug), generated_at)
    end

    Logger.debug(
      "[ListingCache] Loaded #{blog_slug} from file into :persistent_term (#{length(normalized_posts)} posts)"
    )

    PublishingPubSub.broadcast_cache_changed(blog_slug)
  end

  # Read from JSON file only (no :persistent_term storage)
  defp read_from_file_only(blog_slug) do
    cache_path = cache_path(blog_slug)

    with {:ok, content} <- read_cache_file(cache_path),
         {:ok, normalized_posts, _generated_at} <- parse_cache_content(content, blog_slug) do
      {:ok, normalized_posts}
    end
  end

  @doc """
  Regenerates the listing cache for a blog.

  Scans all posts using the standard `list_posts` function and writes
  the metadata to `.listing_cache.json`.

  This should be called after any post operation that changes the listing:
  - create_post
  - update_post
  - add_language_to_post
  - create_new_version

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec regenerate(String.t()) :: :ok | {:error, any()}
  def regenerate(blog_slug) do
    file_enabled = file_cache_enabled?()
    memory_enabled = memory_cache_enabled?()

    # If both caches are disabled, nothing to do
    if not file_enabled and not memory_enabled do
      :ok
    else
      do_regenerate(blog_slug, file_enabled, memory_enabled)
    end
  rescue
    error ->
      Logger.error(
        "[ListingCache] Failed to regenerate cache for #{blog_slug}: #{inspect(error)}"
      )

      {:error, {:regenerate_failed, error}}
  end

  defp do_regenerate(blog_slug, file_enabled, memory_enabled) do
    start_time = System.monotonic_time(:millisecond)

    # Fetch all posts using the existing storage layer
    posts =
      case Publishing.get_group_mode(blog_slug) do
        "slug" -> Storage.list_posts_slug_mode(blog_slug, nil)
        _ -> Storage.list_posts(blog_slug, nil)
      end

    # Convert to cacheable format (strip content, keep metadata)
    serialized_posts = Enum.map(posts, &safe_serialize_post/1)
    normalized_posts = Enum.map(serialized_posts, &normalize_post/1)

    # Generate timestamp once for consistency
    generated_at = DateTime.utc_now() |> DateTime.to_iso8601()

    # Write to file cache if enabled
    file_result =
      if file_enabled do
        cache_data = %{
          "generated_at" => generated_at,
          "post_count" => length(posts),
          "posts" => serialized_posts
        }

        write_cache_file(cache_path(blog_slug), cache_data)
      else
        :ok
      end

    # Update :persistent_term if enabled
    if memory_enabled do
      safe_persistent_term_put(persistent_term_key(blog_slug), normalized_posts)
      safe_persistent_term_put(loaded_at_key(blog_slug), generated_at)
      safe_persistent_term_put(file_generated_at_key(blog_slug), generated_at)
    end

    elapsed = System.monotonic_time(:millisecond) - start_time

    case file_result do
      :ok ->
        Logger.debug(
          "[ListingCache] Regenerated cache for #{blog_slug} (#{length(posts)} posts) in #{elapsed}ms"
        )

        # Broadcast cache change so admin UI updates live
        PublishingPubSub.broadcast_cache_changed(blog_slug)

        :ok

      {:error, reason} = error ->
        Logger.error("[ListingCache] Failed to write cache for #{blog_slug}: #{inspect(reason)}")

        error
    end
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

      case ListingCache.regenerate_if_not_in_progress(blog_slug) do
        :ok -> # Cache is ready, read from it
        :already_in_progress -> # Fall back to filesystem scan
        {:error, _} -> # Fall back to filesystem scan
      end
  """
  @spec regenerate_if_not_in_progress(String.t()) :: :ok | :already_in_progress | {:error, any()}
  def regenerate_if_not_in_progress(blog_slug) do
    ensure_lock_table_exists()
    now = System.monotonic_time(:millisecond)

    # Try to atomically acquire the lock using ETS insert_new
    # Returns true if inserted (lock acquired), false if key already exists
    case :ets.insert_new(@lock_table, {blog_slug, now}) do
      true ->
        # We acquired the lock - perform regeneration
        do_regenerate_with_lock(blog_slug)

      false ->
        # Lock exists - check if it's stale
        handle_existing_lock(blog_slug, now)
    end
  end

  # Handle case where lock already exists - check staleness
  defp handle_existing_lock(blog_slug, now) do
    case :ets.lookup(@lock_table, blog_slug) do
      [{^blog_slug, lock_timestamp}] ->
        lock_age = now - lock_timestamp

        if lock_age < @lock_timeout_ms do
          # Lock is valid and recent - another process is regenerating
          Logger.debug(
            "[ListingCache] Regeneration already in progress for #{blog_slug} (#{lock_age}ms ago), skipping"
          )

          :already_in_progress
        else
          # Lock is stale - previous process likely died
          # Try to take over by deleting and re-acquiring atomically
          take_over_stale_lock(blog_slug, lock_timestamp, lock_age, now)
        end

      [] ->
        # Lock was released between insert_new and lookup - try again
        regenerate_if_not_in_progress(blog_slug)
    end
  end

  # Attempt to take over a stale lock using compare-and-delete
  defp take_over_stale_lock(blog_slug, old_timestamp, lock_age, now) do
    # Use match_delete for atomic compare-and-delete
    # Only deletes if the timestamp matches (no one else took over)
    case :ets.select_delete(@lock_table, [{{blog_slug, old_timestamp}, [], [true]}]) do
      1 ->
        # Successfully deleted stale lock - now try to acquire
        Logger.warning(
          "[ListingCache] Found stale lock for #{blog_slug} (#{lock_age}ms old), taking over regeneration"
        )

        case :ets.insert_new(@lock_table, {blog_slug, now}) do
          true ->
            do_regenerate_with_lock(blog_slug)

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
  defp do_regenerate_with_lock(blog_slug) do
    result = regenerate(blog_slug)

    case result do
      :ok -> :ok
      {:error, _} = error -> error
    end
  after
    # Always release the lock when done (success or failure)
    :ets.delete(@lock_table, blog_slug)
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

  # Safely serialize a post (returns empty map on failure instead of crashing)
  defp safe_serialize_post(post) do
    serialize_post(post)
  rescue
    error ->
      Logger.warning("[ListingCache] Failed to serialize post: #{inspect(error)}")
      %{"slug" => "error", "metadata" => %{"title" => "Error loading post"}}
  end

  @doc """
  Regenerates only the file cache without loading into memory.

  This scans all posts and writes to `.listing_cache.json` but does not
  update :persistent_term. Use `load_into_memory/1` separately if needed.
  """
  @spec regenerate_file_only(String.t()) :: :ok | {:error, any()}
  def regenerate_file_only(blog_slug) do
    start_time = System.monotonic_time(:millisecond)

    # Fetch all posts using the existing storage layer
    posts =
      case Publishing.get_group_mode(blog_slug) do
        "slug" -> Storage.list_posts_slug_mode(blog_slug, nil)
        _ -> Storage.list_posts(blog_slug, nil)
      end

    # Convert to cacheable format (use safe version to handle malformed posts)
    serialized_posts = Enum.map(posts, &safe_serialize_post/1)

    cache_data = %{
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "post_count" => length(posts),
      "posts" => serialized_posts
    }

    result = write_cache_file(cache_path(blog_slug), cache_data)
    elapsed = System.monotonic_time(:millisecond) - start_time

    case result do
      :ok ->
        Logger.debug(
          "[ListingCache] Regenerated file cache for #{blog_slug} (#{length(posts)} posts) in #{elapsed}ms"
        )

        :ok

      {:error, reason} = error ->
        Logger.error("[ListingCache] Failed to write cache for #{blog_slug}: #{inspect(reason)}")

        error
    end
  rescue
    error ->
      Logger.error(
        "[ListingCache] Failed to regenerate file cache for #{blog_slug}: #{inspect(error)}"
      )

      {:error, {:regenerate_failed, error}}
  end

  @doc """
  Loads the cache from file into :persistent_term without regenerating the file.

  Returns `:ok` if successful, `{:error, :no_file}` if file doesn't exist,
  or `{:error, reason}` for other failures.
  """
  @spec load_into_memory(String.t()) :: :ok | {:error, any()}
  def load_into_memory(blog_slug) do
    cache_path = cache_path(blog_slug)

    case File.read(cache_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"posts" => posts, "generated_at" => generated_at}} ->
            normalized_posts = Enum.map(posts, &normalize_post/1)
            safe_persistent_term_put(persistent_term_key(blog_slug), normalized_posts)

            safe_persistent_term_put(
              loaded_at_key(blog_slug),
              DateTime.utc_now() |> DateTime.to_iso8601()
            )

            # Store the file's generated_at so we know what version of data is in memory
            safe_persistent_term_put(file_generated_at_key(blog_slug), generated_at)

            Logger.debug(
              "[ListingCache] Loaded #{blog_slug} from file into :persistent_term (#{length(normalized_posts)} posts)"
            )

            # Broadcast cache change so admin UI updates live
            PublishingPubSub.broadcast_cache_changed(blog_slug)

            :ok

          {:ok, %{"posts" => posts}} ->
            # Fallback for files without generated_at
            normalized_posts = Enum.map(posts, &normalize_post/1)
            safe_persistent_term_put(persistent_term_key(blog_slug), normalized_posts)

            safe_persistent_term_put(
              loaded_at_key(blog_slug),
              DateTime.utc_now() |> DateTime.to_iso8601()
            )

            # Broadcast cache change so admin UI updates live
            PublishingPubSub.broadcast_cache_changed(blog_slug)

            :ok

          {:ok, _} ->
            {:error, :invalid_format}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :enoent} ->
        {:error, :no_file}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Invalidates (deletes) the cache for a blog.

  Clears both the :persistent_term entry and the JSON file.
  The next read will return `:cache_miss`, triggering a fallback to
  the filesystem scan.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(blog_slug) do
    # Clear :persistent_term entries
    term_key = persistent_term_key(blog_slug)

    try do
      :persistent_term.erase(term_key)
    rescue
      ArgumentError -> :ok
    end

    try do
      :persistent_term.erase(loaded_at_key(blog_slug))
    rescue
      ArgumentError -> :ok
    end

    try do
      :persistent_term.erase(file_generated_at_key(blog_slug))
    rescue
      ArgumentError -> :ok
    end

    # Then delete the file
    cache_path = cache_path(blog_slug)

    case File.rm(cache_path) do
      :ok ->
        Logger.debug("[ListingCache] Invalidated cache for #{blog_slug}")
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[ListingCache] Failed to delete cache for #{blog_slug}: #{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  Checks if a cache exists for a blog (in :persistent_term or file).
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(blog_slug) do
    case safe_persistent_term_get(persistent_term_key(blog_slug)) do
      {:ok, _} -> true
      :not_found -> cache_path(blog_slug) |> File.exists?()
    end
  end

  @doc """
  Finds a post by slug in the cache.

  This is useful for single post views where we need metadata (language_statuses,
  version_statuses, allow_version_access) without reading multiple files.

  Returns `{:ok, cached_post}` if found, `{:error, :not_found}` otherwise.
  """
  @spec find_post(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found | :cache_miss}
  def find_post(blog_slug, post_slug) do
    case read(blog_slug) do
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
  def find_post_by_path(blog_slug, date, time) do
    case read(blog_slug) do
      {:ok, posts} ->
        # Match posts where the path contains this date/time combination
        path_pattern = "#{date}/#{time}"

        case Enum.find(posts, fn p ->
               p.path && String.contains?(p.path, path_pattern)
             end) do
          nil -> {:error, :not_found}
          post -> {:ok, post}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Finds a post by URL slug for a specific language.

  This enables O(1) lookup from URL slug to internal identifier, supporting
  per-language URL slugs for SEO-friendly localized URLs.

  ## Parameters
  - `group_slug` - The publishing group
  - `language` - The language code to search in
  - `url_slug` - The URL slug to find

  ## Returns
  - `{:ok, cached_post}` - Found post (includes internal `slug` for file lookup)
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
  Returns the cache file path for a publishing group.
  """
  @spec cache_path(String.t()) :: String.t()
  def cache_path(group_slug) do
    Path.join(Storage.group_path(group_slug), @cache_filename)
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
  def loaded_at_key(blog_slug) do
    {@persistent_term_loaded_at_prefix, blog_slug}
  end

  @doc """
  Returns when the memory cache was loaded (ISO 8601 string), or nil if not loaded.
  """
  @spec memory_loaded_at(String.t()) :: String.t() | nil
  def memory_loaded_at(blog_slug) do
    case safe_persistent_term_get(loaded_at_key(blog_slug)) do
      {:ok, loaded_at} -> loaded_at
      :not_found -> nil
    end
  end

  @doc """
  Returns the :persistent_term key for tracking the file's generated_at when loaded into memory.
  """
  @spec file_generated_at_key(String.t()) :: tuple()
  def file_generated_at_key(blog_slug) do
    {@persistent_term_file_generated_at_prefix, blog_slug}
  end

  @doc """
  Returns the file's generated_at timestamp that was stored when the memory cache was loaded.
  This tells us what version of the file data is currently in memory.
  """
  @spec memory_file_generated_at(String.t()) :: String.t() | nil
  def memory_file_generated_at(blog_slug) do
    case safe_persistent_term_get(file_generated_at_key(blog_slug)) do
      {:ok, generated_at} -> generated_at
      :not_found -> nil
    end
  end

  @doc """
  Returns whether file caching is enabled.
  Uses cached settings to avoid database queries on every call.
  Checks new key first, falls back to legacy key.
  """
  @spec file_cache_enabled?() :: boolean()
  def file_cache_enabled? do
    case Settings.get_setting_cached(@file_cache_key, nil) do
      nil -> Settings.get_setting_cached(@legacy_file_cache_key, "true") == "true"
      value -> value == "true"
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
  def posts_needing_primary_language_migration(blog_slug) do
    case read(blog_slug) do
      {:ok, posts} ->
        global_primary = Storage.get_primary_language()

        Enum.filter(posts, fn post ->
          # Use atom key since normalized posts use atoms
          stored_primary = post[:primary_language]
          stored_primary == nil or stored_primary != global_primary
        end)

      {:error, _} ->
        # If cache doesn't exist, scan filesystem directly
        scan_posts_needing_migration(blog_slug)
    end
  end

  defp scan_posts_needing_migration(blog_slug) do
    global_primary = Storage.get_primary_language()

    # Try slug mode first, then timestamp mode (list_posts handles timestamp)
    posts = Storage.list_posts_slug_mode(blog_slug)

    posts =
      if posts == [] do
        Storage.list_posts(blog_slug)
      else
        posts
      end

    posts
    |> Enum.filter(fn post ->
      stored_primary = Map.get(post[:metadata] || %{}, :primary_language)
      stored_primary == nil or stored_primary != global_primary
    end)
    |> Enum.map(&serialize_post/1)
    |> Enum.map(&normalize_post/1)
  end

  @doc """
  Counts posts by primary_language status in a group.

  Returns `%{current: n, needs_migration: n, needs_backfill: n}` where:
  - `current` - posts with primary_language matching global setting
  - `needs_migration` - posts with different primary_language (were created under old setting)
  - `needs_backfill` - posts with no primary_language stored (legacy posts)
  """
  @spec count_primary_language_status(String.t()) :: map()
  def count_primary_language_status(blog_slug) do
    case read(blog_slug) do
      {:ok, posts} ->
        global_primary = Storage.get_primary_language()

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
        # If cache doesn't exist, scan filesystem directly
        scan_primary_language_status(blog_slug)
    end
  end

  defp scan_primary_language_status(blog_slug) do
    global_primary = Storage.get_primary_language()

    # Try slug mode first, then timestamp mode (list_posts handles timestamp)
    posts = Storage.list_posts_slug_mode(blog_slug)

    posts =
      if posts == [] do
        Storage.list_posts(blog_slug)
      else
        posts
      end

    Enum.reduce(posts, %{current: 0, needs_migration: 0, needs_backfill: 0}, fn post, acc ->
      stored_primary = Map.get(post[:metadata] || %{}, :primary_language)

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

  # ===========================================================================
  # Legacy Structure Migration Status
  # ===========================================================================

  @doc """
  Counts posts by version structure status for a group.

  Returns `%{versioned: n, legacy: n}` where:
  - `versioned` - posts with v1/, v2/, etc. structure
  - `legacy` - posts with flat file structure (need migration)
  """
  @spec count_legacy_structure_status(String.t()) :: map()
  def count_legacy_structure_status(blog_slug) do
    case read(blog_slug) do
      {:ok, posts} ->
        Enum.reduce(posts, %{versioned: 0, legacy: 0}, fn post, acc ->
          if post[:is_legacy_structure] do
            %{acc | legacy: acc.legacy + 1}
          else
            %{acc | versioned: acc.versioned + 1}
          end
        end)

      {:error, _} ->
        # If cache doesn't exist, scan filesystem directly
        scan_legacy_structure_status(blog_slug)
    end
  end

  @doc """
  Returns list of posts that need version structure migration.
  """
  @spec posts_needing_version_migration(String.t()) :: [map()]
  def posts_needing_version_migration(blog_slug) do
    case read(blog_slug) do
      {:ok, posts} ->
        Enum.filter(posts, & &1[:is_legacy_structure])

      {:error, _} ->
        # If cache doesn't exist, scan filesystem directly
        scan_posts_needing_version_migration(blog_slug)
    end
  end

  defp scan_legacy_structure_status(blog_slug) do
    posts = get_posts_for_scan(blog_slug)

    Enum.reduce(posts, %{versioned: 0, legacy: 0}, fn post, acc ->
      if Map.get(post, :is_legacy_structure, false) do
        %{acc | legacy: acc.legacy + 1}
      else
        %{acc | versioned: acc.versioned + 1}
      end
    end)
  end

  defp scan_posts_needing_version_migration(blog_slug) do
    posts = get_posts_for_scan(blog_slug)
    Enum.filter(posts, &Map.get(&1, :is_legacy_structure, false))
  end

  defp get_posts_for_scan(blog_slug) do
    # Try slug mode first, then timestamp mode
    posts = Storage.list_posts_slug_mode(blog_slug)

    if posts == [] do
      Storage.list_posts(blog_slug)
    else
      posts
    end
  end

  # Private functions

  defp write_cache_file(path, data) do
    # Ensure parent directory exists
    path |> Path.dirname() |> File.mkdir_p()

    # Write to temp file first, then rename (atomic write)
    # Use unique suffix to avoid race conditions when multiple processes regenerate simultaneously
    unique_id = :erlang.unique_integer([:positive])
    tmp_path = "#{path}.tmp.#{unique_id}"

    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        case File.write(tmp_path, json) do
          :ok ->
            result = File.rename(tmp_path, path)
            # Clean up temp file if rename failed
            if result != :ok, do: File.rm(tmp_path)
            result

          error ->
            error
        end

      {:error, reason} ->
        {:error, {:json_encode, reason}}
    end
  end

  defp serialize_post(post) do
    # Build both current and previous slugs for all languages
    {language_slugs, language_previous_slugs} = build_all_language_slugs(post)

    %{
      "group" => post[:group],
      "slug" => post[:slug],
      "url_slug" => post[:url_slug] || post[:slug],
      "date" => serialize_date(post[:date]),
      "time" => serialize_time(post[:time]),
      "path" => post[:path],
      "full_path" => post[:full_path],
      "mode" => to_string(post[:mode]),
      "language" => post[:language],
      "available_languages" => post[:available_languages] || [],
      "language_statuses" => post[:language_statuses] || %{},
      # Per-language URL slugs for SEO-friendly localized URLs
      "language_slugs" => language_slugs,
      # Per-language previous URL slugs for 301 redirects
      "language_previous_slugs" => language_previous_slugs,
      "version" => post[:version],
      "available_versions" => post[:available_versions] || [],
      "version_statuses" => serialize_version_statuses(post[:version_statuses]),
      "version_dates" => post[:version_dates] || %{},
      "is_legacy_structure" => post[:is_legacy_structure] || false,
      "metadata" => serialize_metadata(post[:metadata]),
      # Pre-compute excerpt for listing page (avoids needing full content)
      "excerpt" => extract_excerpt(post[:content], post[:metadata]),
      # Primary language for this post (controls versioning/status inheritance)
      # NOTE: Do NOT fall back to global setting - we need nil to detect posts needing backfill
      "primary_language" => Map.get(post[:metadata] || %{}, :primary_language)
    }
  end

  # Build both language_slugs and language_previous_slugs maps
  # Returns {language_slugs, language_previous_slugs}
  # language_slugs: language -> current url_slug
  # language_previous_slugs: language -> [previous_url_slugs]
  defp build_all_language_slugs(post) do
    current_lang = post[:language]
    current_url_slug = post[:url_slug] || post[:slug]
    current_previous = Map.get(post[:metadata] || %{}, :previous_url_slugs) || []
    available_langs = post[:available_languages] || []
    group_slug = post[:group] || post[:blog]
    post_slug = post[:slug]

    # Start with the current language's data
    base_slugs = %{current_lang => current_url_slug}
    base_previous = %{current_lang => current_previous}

    # For each available language, read its url_slug and previous_url_slugs
    {final_slugs, final_previous} =
      Enum.reduce(available_langs, {base_slugs, base_previous}, fn lang, {slugs_acc, prev_acc} ->
        if Map.has_key?(slugs_acc, lang) do
          {slugs_acc, prev_acc}
        else
          # Read both url_slug and previous_url_slugs from this language's file
          {url_slug, prev_slugs} = get_slugs_for_language(group_slug, post_slug, lang, post)
          {Map.put(slugs_acc, lang, url_slug), Map.put(prev_acc, lang, prev_slugs)}
        end
      end)

    {final_slugs, final_previous}
  end

  # Gets both url_slug and previous_url_slugs for a specific language
  defp get_slugs_for_language(group_slug, post_slug, lang, post) do
    case Storage.read_post_slug_mode(group_slug, post_slug, lang, nil) do
      {:ok, lang_post} ->
        url_slug = lang_post.url_slug
        previous = Map.get(lang_post.metadata, :previous_url_slugs) || []
        {url_slug, previous}

      {:error, _} ->
        # File doesn't exist or can't be read - use defaults
        {post_slug, []}
    end
  rescue
    _ -> {post[:slug] || post_slug, []}
  end

  # Extract excerpt: use description if available, otherwise extract from content
  defp extract_excerpt(_content, %{description: desc}) when is_binary(desc) and desc != "",
    do: desc

  defp extract_excerpt(content, _metadata) when is_binary(content) do
    # Get first paragraph or content before <!-- more --> tag
    excerpt_text =
      if String.contains?(content, "<!-- more -->") do
        content
        |> String.split("<!-- more -->")
        |> List.first()
        |> String.trim()
      else
        content
        |> String.split(~r/\n\n+/)
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> List.first()
        |> case do
          nil -> ""
          text -> String.trim(text)
        end
      end

    # Strip markdown formatting and limit length
    excerpt_text
    |> String.replace(~r/[#*_`\[\]()]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 300)
  end

  defp extract_excerpt(_, _), do: nil

  defp serialize_metadata(nil), do: %{}

  defp serialize_metadata(metadata) when is_map(metadata) do
    %{
      "title" => Map.get(metadata, :title),
      "description" => Map.get(metadata, :description),
      "slug" => Map.get(metadata, :slug),
      "status" => Map.get(metadata, :status),
      "published_at" => Map.get(metadata, :published_at),
      "featured_image_id" => Map.get(metadata, :featured_image_id),
      "version" => Map.get(metadata, :version),
      "allow_version_access" => Map.get(metadata, :allow_version_access),
      "status_manual" => Map.get(metadata, :status_manual),
      "url_slug" => Map.get(metadata, :url_slug),
      "previous_url_slugs" => Map.get(metadata, :previous_url_slugs)
    }
  end

  defp serialize_date(nil), do: nil
  defp serialize_date(%Date{} = date), do: Date.to_iso8601(date)
  defp serialize_date(date) when is_binary(date), do: date

  defp serialize_time(nil), do: nil
  defp serialize_time(%Time{} = time), do: Time.to_string(time)
  defp serialize_time(time) when is_binary(time), do: time

  defp serialize_version_statuses(nil), do: %{}

  defp serialize_version_statuses(statuses) when is_map(statuses) do
    # Convert integer keys to strings for JSON
    Map.new(statuses, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_post(post) when is_map(post) do
    slug = post["slug"]

    %{
      # Support both "group" (new) and "blog" (old cache) keys
      group: post["group"] || post["blog"],
      slug: slug,
      url_slug: post["url_slug"] || slug,
      date: parse_date(post["date"]),
      time: parse_time(post["time"]),
      path: post["path"],
      full_path: post["full_path"],
      mode: parse_mode(post["mode"]),
      language: post["language"],
      available_languages: post["available_languages"] || [],
      language_statuses: post["language_statuses"] || %{},
      # Per-language URL slugs for SEO-friendly localized URLs
      language_slugs: post["language_slugs"] || %{},
      # Per-language previous URL slugs for 301 redirects
      language_previous_slugs: post["language_previous_slugs"] || %{},
      version: post["version"],
      available_versions: post["available_versions"] || [],
      version_statuses: parse_version_statuses(post["version_statuses"]),
      version_dates: post["version_dates"] || %{},
      is_legacy_structure: post["is_legacy_structure"] || false,
      metadata: normalize_metadata(post["metadata"]),
      # Primary language for this post (controls versioning/status inheritance)
      primary_language: post["primary_language"],
      # Use pre-computed excerpt as content for template compatibility
      # The template's extract_excerpt() will just return this text
      content: post["excerpt"]
    }
  end

  defp normalize_metadata(nil), do: %{}

  defp normalize_metadata(metadata) when is_map(metadata) do
    %{
      title: metadata["title"],
      description: metadata["description"],
      slug: metadata["slug"],
      status: metadata["status"],
      published_at: metadata["published_at"],
      featured_image_id: metadata["featured_image_id"],
      version: metadata["version"],
      allow_version_access: metadata["allow_version_access"],
      status_manual: metadata["status_manual"],
      url_slug: metadata["url_slug"],
      previous_url_slugs: metadata["previous_url_slugs"]
    }
  end

  defp parse_date(nil), do: nil

  defp parse_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_time(nil), do: nil

  defp parse_time(time_str) when is_binary(time_str) do
    case Time.from_iso8601(time_str) do
      {:ok, time} ->
        time

      # Try parsing without seconds (HH:MM format)
      _ ->
        case Time.from_iso8601(time_str <> ":00") do
          {:ok, time} -> time
          _ -> nil
        end
    end
  end

  defp parse_mode("slug"), do: :slug
  defp parse_mode("timestamp"), do: :timestamp
  defp parse_mode(_), do: :timestamp

  defp parse_version_statuses(nil), do: %{}

  defp parse_version_statuses(statuses) when is_map(statuses) do
    # Convert string keys back to integers
    Map.new(statuses, fn {k, v} ->
      key =
        case Integer.parse(k) do
          {int, ""} -> int
          _ -> k
        end

      {key, v}
    end)
  end
end
