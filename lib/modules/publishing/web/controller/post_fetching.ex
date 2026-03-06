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
    Publishing.read_post(group_slug, post_slug, language)
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
  # Timestamp Mode Post Fetching
  # ============================================================================

  @doc """
  Reads a timestamp post from the database.
  """
  def fetch_timestamp_post_from_cache(group_slug, date, time, language) do
    identifier = "#{date}/#{time}"
    Publishing.read_post(group_slug, identifier, language)
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
