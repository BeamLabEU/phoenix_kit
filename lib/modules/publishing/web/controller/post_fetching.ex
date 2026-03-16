defmodule PhoenixKit.Modules.Publishing.Web.Controller.PostFetching do
  @moduledoc """
  Post fetching functionality for the publishing controller.

  Handles fetching posts from cache and database, including:
  - Slug mode posts (versioned)
  - Timestamp mode posts
  - Language fallback logic
  """

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.ListingCache

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
    identifier = "#{date}/#{time}"
    Publishing.read_post(group_slug, identifier, language)
  end

  # ============================================================================
  # Cache-Based Listing
  # ============================================================================

  @doc """
  Fetches posts using cache when available, falls back to direct DB read.

  Tries ListingCache (persistent_term) first for sub-microsecond reads.
  On cache miss, regenerates from the database.
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
              {:ok, posts} ->
                posts

              {:error, reason} ->
                Logger.warning(
                  "[PublishingController] Cache read failed after regeneration for #{group_slug}: #{inspect(reason)}"
                )

                Publishing.list_posts(group_slug, nil)
            end

          :already_in_progress ->
            elapsed_us = System.monotonic_time(:microsecond) - start_time
            elapsed_ms = Float.round(elapsed_us / 1000, 1)

            Logger.info(
              "[PublishingController] Cache regeneration in progress for #{group_slug}, using direct DB read (#{elapsed_ms}ms)"
            )

            # Another request is regenerating, fall back to direct DB read
            Publishing.list_posts(group_slug, nil)

          {:error, reason} ->
            Logger.error(
              "[PublishingController] Cache regeneration failed for #{group_slug}: #{inspect(reason)}"
            )

            # Regeneration failed, fall back to direct DB read
            Publishing.list_posts(group_slug, nil)
        end
    end
  end
end
