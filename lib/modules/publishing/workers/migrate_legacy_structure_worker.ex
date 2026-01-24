defmodule PhoenixKit.Modules.Publishing.Workers.MigrateLegacyStructureWorker do
  @moduledoc """
  Oban worker for migrating legacy structure posts to versioned structure.

  This worker migrates posts from flat file structure (files in post root) to
  versioned structure (files in v1/ subdirectory). It processes posts in batches
  and broadcasts progress updates via PubSub.

  ## Usage

      # Enqueue a migration job
      MigrateLegacyStructureWorker.enqueue("docs")

      # Or with options
      MigrateLegacyStructureWorker.enqueue("docs", user_id: 123)

  ## Job Arguments

  - `group_slug` - The publishing group slug
  - `user_id` - User ID for audit trail (optional)

  ## PubSub Events

  The worker broadcasts the following events to `posts_topic(group_slug)`:

  - `{:legacy_structure_migration_started, group_slug, total_count}` - Migration started
  - `{:legacy_structure_migration_progress, group_slug, current, total}` - Progress update
  - `{:legacy_structure_migration_completed, group_slug, success_count, error_count}` - Completed

  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Storage

  # Batch size for progress updates (broadcast every N posts)
  @progress_batch_size 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    group_slug = Map.fetch!(args, "group_slug")
    _user_id = Map.get(args, "user_id")

    Logger.info("[MigrateLegacyStructureWorker] Starting migration for #{group_slug}")

    # Get posts needing migration
    posts = ListingCache.posts_needing_version_migration(group_slug)
    total = length(posts)

    if total == 0 do
      Logger.info("[MigrateLegacyStructureWorker] No posts need migration for #{group_slug}")
      :ok
    else
      # Broadcast start
      PublishingPubSub.broadcast_legacy_structure_migration_started(group_slug, total)

      # Process posts with progress updates
      {success_count, error_count} =
        posts
        |> Enum.with_index(1)
        |> Enum.reduce({0, 0}, fn {post, index}, {successes, errors} ->
          # Need to read the full post to get all fields for migration
          result = migrate_single_post(group_slug, post)

          # Broadcast progress every batch
          if rem(index, @progress_batch_size) == 0 or index == total do
            PublishingPubSub.broadcast_legacy_structure_migration_progress(
              group_slug,
              index,
              total
            )
          end

          case result do
            {:ok, _} -> {successes + 1, errors}
            {:error, _} -> {successes, errors + 1}
          end
        end)

      # Regenerate cache
      ListingCache.regenerate(group_slug)

      # Broadcast completion
      PublishingPubSub.broadcast_legacy_structure_migration_completed(
        group_slug,
        success_count,
        error_count
      )

      Logger.info(
        "[MigrateLegacyStructureWorker] Completed: #{success_count} succeeded, #{error_count} failed"
      )

      if error_count > 0 and success_count == 0 do
        {:error, "All migrations failed"}
      else
        :ok
      end
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  # Migrate a single post from cached data
  defp migrate_single_post(group_slug, cached_post) do
    # Read the full post from disk to get all required fields
    post_identifier = get_post_identifier(cached_post)
    language = cached_post[:language] || List.first(cached_post[:available_languages] || ["en"])

    case read_full_post(group_slug, cached_post, post_identifier, language) do
      {:ok, full_post} ->
        Storage.migrate_post_to_versioned(full_post, language)

      {:error, reason} ->
        Logger.warning(
          "[MigrateLegacyStructureWorker] Failed to read post #{post_identifier}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp read_full_post(group_slug, cached_post, post_identifier, language) do
    case cached_post[:mode] do
      :timestamp ->
        Storage.read_post(group_slug, cached_post[:path])

      "timestamp" ->
        Storage.read_post(group_slug, cached_post[:path])

      _ ->
        Storage.read_post_slug_mode(group_slug, post_identifier, language, nil)
    end
  end

  # Get post identifier from cached post
  # For slug mode: returns the slug
  # For timestamp mode: returns the date/time path
  defp get_post_identifier(post) do
    case post[:mode] do
      :timestamp -> derive_timestamp_post_dir(post[:path])
      "timestamp" -> derive_timestamp_post_dir(post[:path])
      _ -> post[:slug] || derive_slug_from_path(post[:path])
    end
  end

  # For timestamp mode, extract date/time from path like "group/date/time/file.phk"
  defp derive_timestamp_post_dir(nil), do: nil
  defp derive_timestamp_post_dir(""), do: nil

  defp derive_timestamp_post_dir(path) do
    parts = Path.split(path)

    case parts do
      # Legacy: group/date/time/lang.phk
      [_group, date, time, _lang_file] -> Path.join(date, time)
      _ -> nil
    end
  end

  # For slug mode, extract slug from path
  defp derive_slug_from_path(nil), do: nil
  defp derive_slug_from_path(""), do: nil

  defp derive_slug_from_path(path) do
    parts = Path.split(path)

    case parts do
      # Legacy: group/slug/lang.phk
      [_group, slug, _lang_file] -> slug
      _ -> nil
    end
  end

  @doc """
  Creates a new migration job.

  ## Options

  - `:user_id` - User ID for audit trail

  ## Examples

      MigrateLegacyStructureWorker.create_job("docs")
      MigrateLegacyStructureWorker.create_job("docs", user_id: 123)

  """
  def create_job(group_slug, opts \\ []) do
    args =
      %{"group_slug" => group_slug}
      |> maybe_put("user_id", Keyword.get(opts, :user_id))

    new(args)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Enqueues a migration job.

  See `create_job/2` for options.

  ## Examples

      {:ok, job} = MigrateLegacyStructureWorker.enqueue("docs")

  """
  def enqueue(group_slug, opts \\ []) do
    group_slug
    |> create_job(opts)
    |> Oban.insert()
  end
end
