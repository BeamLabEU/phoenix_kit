defmodule PhoenixKit.Modules.Publishing.Workers.MigratePrimaryLanguageWorker do
  @moduledoc """
  Oban worker for migrating posts to a new primary language setting.

  This worker updates the `primary_language` metadata field for all posts in a
  publishing group that need migration. It processes posts in batches and
  broadcasts progress updates via PubSub.

  ## Usage

      # Enqueue a migration job
      MigratePrimaryLanguageWorker.enqueue("docs", "en")

      # Or with options
      MigratePrimaryLanguageWorker.enqueue("docs", "en", user_id: 123)

  ## Job Arguments

  - `group_slug` - The publishing group slug
  - `primary_language` - The new primary language to set
  - `user_id` - User ID for audit trail (optional)

  ## PubSub Events

  The worker broadcasts the following events to `posts_topic(group_slug)`:

  - `{:primary_language_migration_started, total_count}` - Migration started
  - `{:primary_language_migration_progress, current, total}` - Progress update
  - `{:primary_language_migration_completed, success_count, error_count}` - Completed

  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub

  # Batch size for progress updates (broadcast every N posts)
  @progress_batch_size 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    group_slug = Map.fetch!(args, "group_slug")
    primary_language = Map.fetch!(args, "primary_language")
    _user_id = Map.get(args, "user_id")

    Logger.info(
      "[MigratePrimaryLanguageWorker] Starting migration for #{group_slug} to #{primary_language}"
    )

    # Get posts needing migration
    posts = ListingCache.posts_needing_primary_language_migration(group_slug)
    total = length(posts)

    if total == 0 do
      Logger.info("[MigratePrimaryLanguageWorker] No posts need migration for #{group_slug}")
      :ok
    else
      # Broadcast start
      PublishingPubSub.broadcast_primary_language_migration_started(group_slug, total)

      # Process posts with progress updates
      {success_count, error_count} =
        posts
        |> Enum.with_index(1)
        |> Enum.reduce({0, 0}, fn {post, index}, {successes, errors} ->
          post_slug = get_post_slug(post)

          result =
            if post_slug do
              Publishing.update_post_primary_language(group_slug, post_slug, primary_language)
            else
              {:error, :no_slug}
            end

          # Broadcast progress every batch
          if rem(index, @progress_batch_size) == 0 or index == total do
            PublishingPubSub.broadcast_primary_language_migration_progress(
              group_slug,
              index,
              total
            )
          end

          case result do
            :ok -> {successes + 1, errors}
            {:error, _} -> {successes, errors + 1}
          end
        end)

      # Regenerate cache
      ListingCache.regenerate(group_slug)

      # Broadcast completion
      PublishingPubSub.broadcast_primary_language_migration_completed(
        group_slug,
        success_count,
        error_count,
        primary_language
      )

      Logger.info(
        "[MigratePrimaryLanguageWorker] Completed: #{success_count} succeeded, #{error_count} failed"
      )

      if error_count > 0 and success_count == 0 do
        {:error, "All migrations failed"}
      else
        :ok
      end
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  # Get post directory path from cached post
  # For slug mode: returns the slug (e.g., "hello")
  # For timestamp mode: returns the date/time path (e.g., "2025-12-31/03:42")
  defp get_post_slug(post) do
    case post[:mode] do
      :timestamp -> derive_timestamp_post_dir(post[:path])
      "timestamp" -> derive_timestamp_post_dir(post[:path])
      _ -> post[:slug] || derive_slug_from_path(post[:path])
    end
  end

  # For timestamp mode, extract date/time from path like "group/date/time/version/file.phk"
  defp derive_timestamp_post_dir(nil), do: nil
  defp derive_timestamp_post_dir(""), do: nil

  defp derive_timestamp_post_dir(path) do
    parts = Path.split(path)

    case parts do
      # Versioned: group/date/time/v1/lang.phk
      [_group, date, time, "v" <> _, _lang_file] -> Path.join(date, time)
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
      # Versioned: group/slug/v1/lang.phk
      [_group, slug, "v" <> _, _lang_file] -> slug
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

      MigratePrimaryLanguageWorker.create_job("docs", "en")
      MigratePrimaryLanguageWorker.create_job("docs", "en", user_id: 123)

  """
  def create_job(group_slug, primary_language, opts \\ []) do
    args =
      %{
        "group_slug" => group_slug,
        "primary_language" => primary_language
      }
      |> maybe_put("user_id", Keyword.get(opts, :user_id))

    new(args)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Enqueues a migration job.

  See `create_job/3` for options.

  ## Examples

      {:ok, job} = MigratePrimaryLanguageWorker.enqueue("docs", "en")

  """
  def enqueue(group_slug, primary_language, opts \\ []) do
    group_slug
    |> create_job(primary_language, opts)
    |> Oban.insert()
  end
end
