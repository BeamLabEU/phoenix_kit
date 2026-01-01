defmodule PhoenixKitWeb.Live.Modules.Blogging.ListingCache do
  @moduledoc """
  Caches blog listing metadata to avoid expensive filesystem scans on every request.

  Instead of scanning 50+ files per request, the listing page reads a single
  `.listing_cache.json` file containing all post metadata.

  ## How It Works

  1. When a post is created/updated/published, `regenerate/1` is called
  2. This scans all posts and writes metadata to `.listing_cache.json`
  3. `render_blog_listing` reads from cache instead of scanning filesystem
  4. Cache includes: title, slug, date, status, languages, versions (no content)

  ## Cache File Location

      priv/blogging/{blog-slug}/.listing_cache.json

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

  alias PhoenixKit.Settings
  alias PhoenixKitWeb.Live.Modules.Blogging
  alias PhoenixKitWeb.Live.Modules.Blogging.PubSub, as: BloggingPubSub
  alias PhoenixKitWeb.Live.Modules.Blogging.Storage

  require Logger

  @cache_filename ".listing_cache.json"
  @persistent_term_prefix :phoenix_kit_blog_listing_cache
  @persistent_term_loaded_at_prefix :phoenix_kit_blog_listing_cache_loaded_at
  @persistent_term_file_generated_at_prefix :phoenix_kit_blog_listing_cache_file_generated_at
  @file_cache_key "blogging_file_cache_enabled"
  @memory_cache_key "blogging_memory_cache_enabled"

  @doc """
  Reads the cached listing for a blog.

  Returns `{:ok, posts}` if cache exists and is valid.
  Returns `{:error, :cache_miss}` if cache doesn't exist, is corrupt, or caching is disabled.

  Respects the `blogging_file_cache_enabled` and `blogging_memory_cache_enabled` settings.
  """
  @spec read(String.t()) :: {:ok, [map()]} | {:error, :cache_miss}
  def read(blog_slug) do
    memory_enabled = memory_cache_enabled?()
    file_enabled = file_cache_enabled?()

    # If both caches are disabled, return cache miss
    if not memory_enabled and not file_enabled do
      {:error, :cache_miss}
    else
      term_key = persistent_term_key(blog_slug)

      # First, try :persistent_term if enabled (sub-microsecond)
      if memory_enabled do
        case safe_persistent_term_get(term_key) do
          {:ok, posts} ->
            {:ok, posts}

          :not_found ->
            # Fall back to file if enabled
            if file_enabled do
              read_from_file_and_cache(blog_slug, term_key, memory_enabled)
            else
              {:error, :cache_miss}
            end
        end
      else
        # Memory cache disabled, only try file cache
        if file_enabled do
          read_from_file_only(blog_slug)
        else
          {:error, :cache_miss}
        end
      end
    end
  end

  # Safely get from :persistent_term (returns :not_found instead of raising)
  defp safe_persistent_term_get(key) do
    try do
      {:ok, :persistent_term.get(key)}
    rescue
      ArgumentError -> :not_found
    end
  end

  # Read from JSON file and optionally store in :persistent_term
  defp read_from_file_and_cache(blog_slug, term_key, store_in_memory) do
    cache_path = cache_path(blog_slug)

    case File.read(cache_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"posts" => posts} = data} ->
            # Convert string keys back to atoms for compatibility
            normalized_posts = Enum.map(posts, &normalize_post/1)
            generated_at = Map.get(data, "generated_at")

            # Store in :persistent_term if memory cache is enabled
            if store_in_memory do
              :persistent_term.put(term_key, normalized_posts)

              :persistent_term.put(
                loaded_at_key(blog_slug),
                DateTime.utc_now() |> DateTime.to_iso8601()
              )

              # Store the file's generated_at so we know what version of data is in memory
              if generated_at do
                :persistent_term.put(file_generated_at_key(blog_slug), generated_at)
              end

              Logger.debug(
                "[ListingCache] Loaded #{blog_slug} from file into :persistent_term (#{length(normalized_posts)} posts)"
              )

              # Broadcast cache change so admin UI updates live
              BloggingPubSub.broadcast_cache_changed(blog_slug)
            end

            {:ok, normalized_posts}

          {:ok, _} ->
            Logger.warning("[ListingCache] Invalid cache format for #{blog_slug}")
            {:error, :cache_miss}

          {:error, reason} ->
            Logger.warning(
              "[ListingCache] Failed to parse cache for #{blog_slug}: #{inspect(reason)}"
            )

            {:error, :cache_miss}
        end

      {:error, :enoent} ->
        # Don't log warning for missing cache - it's expected for new blogs
        {:error, :cache_miss}

      {:error, reason} ->
        Logger.warning("[ListingCache] Failed to read cache for #{blog_slug}: #{inspect(reason)}")
        {:error, :cache_miss}
    end
  end

  # Read from JSON file only (no :persistent_term storage)
  defp read_from_file_only(blog_slug) do
    cache_path = cache_path(blog_slug)

    case File.read(cache_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"posts" => posts}} ->
            normalized_posts = Enum.map(posts, &normalize_post/1)
            {:ok, normalized_posts}

          {:ok, _} ->
            Logger.warning("[ListingCache] Invalid cache format for #{blog_slug}")
            {:error, :cache_miss}

          {:error, reason} ->
            Logger.warning(
              "[ListingCache] Failed to parse cache for #{blog_slug}: #{inspect(reason)}"
            )

            {:error, :cache_miss}
        end

      {:error, :enoent} ->
        {:error, :cache_miss}

      {:error, reason} ->
        Logger.warning("[ListingCache] Failed to read cache for #{blog_slug}: #{inspect(reason)}")
        {:error, :cache_miss}
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
      start_time = System.monotonic_time(:millisecond)

      # Fetch all posts using the existing storage layer
      posts =
        case Blogging.get_blog_mode(blog_slug) do
          "slug" -> Storage.list_posts_slug_mode(blog_slug, nil)
          _ -> Storage.list_posts(blog_slug, nil)
        end

      # Convert to cacheable format (strip content, keep metadata)
      serialized_posts = Enum.map(posts, &serialize_post/1)
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
        :persistent_term.put(persistent_term_key(blog_slug), normalized_posts)
        :persistent_term.put(loaded_at_key(blog_slug), generated_at)
        :persistent_term.put(file_generated_at_key(blog_slug), generated_at)
      end

      elapsed = System.monotonic_time(:millisecond) - start_time

      case file_result do
        :ok ->
          Logger.debug(
            "[ListingCache] Regenerated cache for #{blog_slug} (#{length(posts)} posts) in #{elapsed}ms"
          )

          # Broadcast cache change so admin UI updates live
          BloggingPubSub.broadcast_cache_changed(blog_slug)

          :ok

        {:error, reason} = error ->
          Logger.error(
            "[ListingCache] Failed to write cache for #{blog_slug}: #{inspect(reason)}"
          )

          error
      end
    end
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
      case Blogging.get_blog_mode(blog_slug) do
        "slug" -> Storage.list_posts_slug_mode(blog_slug, nil)
        _ -> Storage.list_posts(blog_slug, nil)
      end

    # Convert to cacheable format
    serialized_posts = Enum.map(posts, &serialize_post/1)

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
            :persistent_term.put(persistent_term_key(blog_slug), normalized_posts)

            :persistent_term.put(
              loaded_at_key(blog_slug),
              DateTime.utc_now() |> DateTime.to_iso8601()
            )

            # Store the file's generated_at so we know what version of data is in memory
            :persistent_term.put(file_generated_at_key(blog_slug), generated_at)

            Logger.debug(
              "[ListingCache] Loaded #{blog_slug} from file into :persistent_term (#{length(normalized_posts)} posts)"
            )

            # Broadcast cache change so admin UI updates live
            BloggingPubSub.broadcast_cache_changed(blog_slug)

            :ok

          {:ok, %{"posts" => posts}} ->
            # Fallback for files without generated_at
            normalized_posts = Enum.map(posts, &normalize_post/1)
            :persistent_term.put(persistent_term_key(blog_slug), normalized_posts)

            :persistent_term.put(
              loaded_at_key(blog_slug),
              DateTime.utc_now() |> DateTime.to_iso8601()
            )

            # Broadcast cache change so admin UI updates live
            BloggingPubSub.broadcast_cache_changed(blog_slug)

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
  Returns the cache file path for a blog.
  """
  @spec cache_path(String.t()) :: String.t()
  def cache_path(blog_slug) do
    Path.join([Storage.root_path(), blog_slug, @cache_filename])
  end

  @doc """
  Returns the :persistent_term key for a blog's cache.
  """
  @spec persistent_term_key(String.t()) :: tuple()
  def persistent_term_key(blog_slug) do
    {@persistent_term_prefix, blog_slug}
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
  """
  @spec file_cache_enabled?() :: boolean()
  def file_cache_enabled? do
    Settings.get_setting(@file_cache_key, "true") == "true"
  end

  @doc """
  Returns whether memory caching (:persistent_term) is enabled.
  """
  @spec memory_cache_enabled?() :: boolean()
  def memory_cache_enabled? do
    Settings.get_setting(@memory_cache_key, "true") == "true"
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
    %{
      "blog" => post[:blog],
      "slug" => post[:slug],
      "date" => serialize_date(post[:date]),
      "time" => serialize_time(post[:time]),
      "path" => post[:path],
      "full_path" => post[:full_path],
      "mode" => to_string(post[:mode]),
      "language" => post[:language],
      "available_languages" => post[:available_languages] || [],
      "language_statuses" => post[:language_statuses] || %{},
      "version" => post[:version],
      "available_versions" => post[:available_versions] || [],
      "version_statuses" => serialize_version_statuses(post[:version_statuses]),
      "version_dates" => post[:version_dates] || %{},
      "is_legacy_structure" => post[:is_legacy_structure] || false,
      "metadata" => serialize_metadata(post[:metadata]),
      # Pre-compute excerpt for listing page (avoids needing full content)
      "excerpt" => extract_excerpt(post[:content], post[:metadata])
    }
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
      "is_live" => Map.get(metadata, :is_live),
      "version" => Map.get(metadata, :version),
      "allow_version_access" => Map.get(metadata, :allow_version_access)
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
    %{
      blog: post["blog"],
      slug: post["slug"],
      date: parse_date(post["date"]),
      time: parse_time(post["time"]),
      path: post["path"],
      full_path: post["full_path"],
      mode: parse_mode(post["mode"]),
      language: post["language"],
      available_languages: post["available_languages"] || [],
      language_statuses: post["language_statuses"] || %{},
      version: post["version"],
      available_versions: post["available_versions"] || [],
      version_statuses: parse_version_statuses(post["version_statuses"]),
      version_dates: post["version_dates"] || %{},
      is_legacy_structure: post["is_legacy_structure"] || false,
      metadata: normalize_metadata(post["metadata"]),
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
      is_live: metadata["is_live"],
      version: metadata["version"],
      allow_version_access: metadata["allow_version_access"]
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
