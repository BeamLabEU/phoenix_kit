defmodule PhoenixKit.Modules.Publishing.Web.Controller.PostFetching do
  @moduledoc """
  Post fetching functionality for the publishing controller.

  Handles fetching posts from cache and filesystem, including:
  - Slug mode posts (versioned)
  - Timestamp mode posts (versioned and legacy)
  - Language fallback logic
  """

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Metadata
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language

  # ============================================================================
  # Main Fetch Functions
  # ============================================================================

  @doc """
  Fetches a slug-mode post - iterates from highest version down, returns first published.
  Falls back to primary language or first available if requested language isn't found.
  """
  def fetch_post(group_slug, {:slug, post_slug}, language) do
    if Publishing.db_storage?() do
      # In DB mode, read directly from database (no filesystem)
      Publishing.read_post(group_slug, post_slug, language)
    else
      case Storage.list_versions(group_slug, post_slug) do
        [] ->
          {:error, :post_not_found}

        versions ->
          find_published_slug_post(group_slug, post_slug, versions, language)
      end
    end
  end

  def fetch_post(group_slug, {:timestamp, date, time}, language) do
    # Try cache first for fast lookup (sub-microsecond from :persistent_term)
    case fetch_timestamp_post_from_cache(group_slug, date, time, language) do
      {:ok, _post} = result ->
        result

      {:error, _} ->
        # Cache miss - fall back to filesystem scan
        post_dir = Path.join([Storage.group_path(group_slug), date, time])

        case Storage.detect_post_structure(post_dir) do
          :versioned ->
            fetch_versioned_timestamp_post(group_slug, date, time, language, post_dir)

          :legacy ->
            fetch_legacy_timestamp_post(group_slug, date, time, language, post_dir)

          :empty ->
            {:error, :post_not_found}
        end
    end
  end

  # ============================================================================
  # Slug Mode Post Fetching
  # ============================================================================

  defp find_published_slug_post(group_slug, post_slug, versions, language) do
    # Use post's stored primary language for fallback, not global
    primary_language = Storage.get_post_primary_language(group_slug, post_slug)
    post_dir = Path.join([Storage.group_path(group_slug), post_slug])

    published_result =
      versions
      |> Enum.sort(:desc)
      |> Enum.find_value(
        &find_published_version(&1, group_slug, post_slug, post_dir, language, primary_language)
      )

    published_result || {:error, :post_not_found}
  end

  defp find_published_version(
         version,
         group_slug,
         post_slug,
         post_dir,
         language,
         primary_language
       ) do
    version_dir = Path.join(post_dir, "v#{version}")
    available_languages = detect_available_languages_in_dir(version_dir)
    resolved_language = Language.resolve_language_for_post(language, available_languages)

    languages_to_try =
      [resolved_language, primary_language | available_languages]
      |> Enum.uniq()
      |> Enum.filter(&(&1 in available_languages))

    Enum.find_value(
      languages_to_try,
      &try_read_published_post(group_slug, post_slug, &1, version)
    )
  end

  defp try_read_published_post(group_slug, post_slug, lang, version) do
    case Publishing.read_post(group_slug, post_slug, lang, version) do
      {:ok, post} when post.metadata.status == "published" -> {:ok, post}
      _ -> nil
    end
  end

  # ============================================================================
  # Timestamp Mode Post Fetching (Cache)
  # ============================================================================

  @doc """
  Fast path: Use cache to get metadata, only read content file.
  """
  def fetch_timestamp_post_from_cache(group_slug, date, time, language) do
    # In DB mode, skip cache and read directly from DB
    if Publishing.db_storage?() do
      identifier = "#{date}/#{time}"
      Publishing.read_post(group_slug, identifier, language)
    else
      fetch_timestamp_post_from_listing_cache(group_slug, date, time, language)
    end
  end

  defp fetch_timestamp_post_from_listing_cache(group_slug, date, time, language) do
    case ListingCache.find_post_by_path(group_slug, date, time) do
      {:ok, cached_post} ->
        # Cache has all metadata, we just need to read the content
        # Find the right language file to read
        resolved_language =
          Language.resolve_language_for_post(language, cached_post.available_languages)

        if resolved_language do
          # Build path to the content file
          # The cached post has the live version's path
          content_path = build_content_path_from_cache(cached_post, resolved_language)

          case read_content_only(content_path) do
            {:ok, content} ->
              # Merge cached metadata with fresh content
              {:ok, merge_cache_with_content(cached_post, content, resolved_language)}

            {:error, _} ->
              {:error, :content_not_found}
          end
        else
          {:error, :language_not_found}
        end

      {:error, _} ->
        {:error, :cache_miss}
    end
  end

  # Build the content file path from cached post data
  defp build_content_path_from_cache(cached_post, language) do
    # The cached post's full_path points to the live version
    # Replace the language portion
    cached_post.full_path
    |> Path.dirname()
    |> Path.join("#{language}.phk")
  end

  # Read just the content from a file (skip expensive metadata operations)
  defp read_content_only(path) do
    with {:ok, file_content} <- File.read(path),
         {:ok, _metadata, body} <- Metadata.parse_with_content(file_content) do
      {:ok, body}
    end
  end

  # Merge cached metadata with fresh content
  defp merge_cache_with_content(cached_post, content, language) do
    %{
      group: cached_post.group,
      slug: cached_post.slug,
      date: cached_post.date,
      time: cached_post.time,
      path: cached_post.path,
      full_path: build_content_path_from_cache(cached_post, language),
      metadata: cached_post.metadata,
      content: content,
      language: language,
      available_languages: cached_post.available_languages,
      language_statuses: cached_post.language_statuses,
      mode: cached_post.mode,
      version: cached_post.version,
      available_versions: cached_post.available_versions,
      version_statuses: cached_post.version_statuses,
      is_legacy_structure: cached_post.is_legacy_structure
    }
  end

  # ============================================================================
  # Timestamp Mode Post Fetching (Filesystem)
  # ============================================================================

  @doc """
  Fetch a versioned timestamp post (files in v1/, v2/, etc.).
  Iterates from highest version down, returns first published version found.
  Falls back to primary language or first available if requested language isn't found.
  """
  def fetch_versioned_timestamp_post(group_slug, date, time, language, post_dir) do
    versions = list_timestamp_versions(post_dir) |> Enum.sort(:desc)
    # Use post's stored primary language for fallback
    post_identifier = Path.join(date, time)
    primary_language = Storage.get_post_primary_language(group_slug, post_identifier)

    # Find first published version, starting from highest
    published_result =
      Enum.find_value(versions, fn version ->
        version_dir = Path.join(post_dir, "v#{version}")
        available_languages = detect_available_languages_in_dir(version_dir)

        # Build priority list of languages to try:
        # 1. Resolved version of requested language
        # 2. Primary language
        # 3. First available language
        resolved_language = Language.resolve_language_for_post(language, available_languages)

        languages_to_try =
          [resolved_language, primary_language | available_languages]
          |> Enum.uniq()
          |> Enum.filter(&(&1 in available_languages))

        Enum.find_value(languages_to_try, fn lang ->
          path = "#{group_slug}/#{date}/#{time}/v#{version}/#{lang}.phk"

          case Publishing.read_post(group_slug, path) do
            {:ok, post} when post.metadata.status == "published" -> {:ok, post}
            _ -> nil
          end
        end)
      end)

    published_result || {:error, :post_not_found}
  end

  @doc """
  Fetch a legacy timestamp post (files directly in post directory).
  Falls back to primary language or first available if requested language isn't found.
  """
  def fetch_legacy_timestamp_post(group_slug, date, time, language, post_dir) do
    available_languages = detect_available_languages_in_dir(post_dir)
    # Use post's stored primary language for fallback
    post_identifier = Path.join(date, time)
    primary_language = Storage.get_post_primary_language(group_slug, post_identifier)
    resolved_language = Language.resolve_language_for_post(language, available_languages)

    # Build priority list of languages to try
    languages_to_try =
      [resolved_language, primary_language | available_languages]
      |> Enum.uniq()
      |> Enum.filter(&(&1 in available_languages))

    Enum.find_value(languages_to_try, fn lang ->
      # Build legacy path: group/date/time/language.phk
      path = "#{group_slug}/#{date}/#{time}/#{lang}.phk"

      case Publishing.read_post(group_slug, path) do
        {:ok, post} -> {:ok, post}
        _ -> nil
      end
    end) || {:error, :post_not_found}
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  @doc """
  List version numbers for a timestamp post directory.
  """
  def list_timestamp_versions(post_dir) do
    case File.ls(post_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(~r/^v\d+$/, &1))
        |> Enum.map(&(String.replace_prefix(&1, "v", "") |> String.to_integer()))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc """
  Detect available language files in a directory.
  """
  def detect_available_languages_in_dir(dir_path) do
    case File.ls(dir_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".phk"))
        |> Enum.map(&String.replace_suffix(&1, ".phk", ""))

      {:error, _} ->
        []
    end
  end

  @doc """
  Detect available languages in a timestamp post directory.
  Handles both versioned (files in v1/, v2/) and legacy (files in root) structures.
  """
  def detect_available_languages_in_timestamp_dir(post_dir) do
    case Storage.detect_post_structure(post_dir) do
      :versioned ->
        # Get languages from the latest version directory
        versions = list_timestamp_versions(post_dir)

        case Enum.max(versions, fn -> nil end) do
          nil ->
            []

          latest_version ->
            version_dir = Path.join(post_dir, "v#{latest_version}")
            detect_available_languages_in_dir(version_dir)
        end

      :legacy ->
        detect_available_languages_in_dir(post_dir)

      :empty ->
        []
    end
  end

  # ============================================================================
  # Cache-Based Listing
  # ============================================================================

  @doc """
  Fetches posts using cache when available, falls back to direct read.

  In both filesystem and DB modes, tries ListingCache (persistent_term) first
  for sub-microsecond reads. On cache miss, regenerates from the appropriate
  source (filesystem scan or DB query).
  """
  def fetch_posts_with_cache(group_slug) do
    fetch_posts_with_listing_cache(group_slug)
  end

  defp fetch_posts_with_listing_cache(group_slug) do
    start_time = System.monotonic_time(:microsecond)

    case ListingCache.read(group_slug) do
      {:ok, posts} ->
        elapsed_us = System.monotonic_time(:microsecond) - start_time

        Logger.debug(
          "[PublishingController] Cache HIT for #{group_slug} (#{elapsed_us}μs, #{length(posts)} posts)"
        )

        posts

      {:error, :cache_miss} ->
        Logger.warning(
          "[PublishingController] Cache MISS for #{group_slug} - regenerating cache synchronously"
        )

        # Cache miss - regenerate cache synchronously to prevent race condition
        # where subsequent requests (e.g., clicking a post) also hit cache miss.
        # Uses lock to prevent thundering herd if multiple requests hit simultaneously.
        case ListingCache.regenerate_if_not_in_progress(group_slug) do
          :ok ->
            elapsed_us = System.monotonic_time(:microsecond) - start_time
            elapsed_ms = Float.round(elapsed_us / 1000, 1)

            Logger.info(
              "[PublishingController] Cache regenerated for #{group_slug} (#{elapsed_ms}ms)"
            )

            # Read from freshly populated cache
            case ListingCache.read(group_slug) do
              {:ok, posts} -> posts
              {:error, _} -> Publishing.list_posts(group_slug, nil)
            end

          :already_in_progress ->
            elapsed_us = System.monotonic_time(:microsecond) - start_time
            elapsed_ms = Float.round(elapsed_us / 1000, 1)

            Logger.info(
              "[PublishingController] Cache regeneration in progress for #{group_slug}, using filesystem (#{elapsed_ms}ms)"
            )

            # Another request is regenerating, fall back to filesystem
            Publishing.list_posts(group_slug, nil)

          {:error, reason} ->
            Logger.error(
              "[PublishingController] Cache regeneration failed for #{group_slug}: #{inspect(reason)}"
            )

            # Regeneration failed, fall back to filesystem
            Publishing.list_posts(group_slug, nil)
        end
    end
  end
end
