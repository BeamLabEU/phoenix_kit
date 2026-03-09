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
      MigratePrimaryLanguageWorker.enqueue("docs", "en", user_uuid: "019145a1-0000-7000-8000-000000000001")

  ## Job Arguments

  - `group_slug` - The publishing group slug
  - `primary_language` - The new primary language to set
  - `user_uuid` - User UUID for audit trail (optional)

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
          post_uuid = post[:uuid]

          result =
            if post_uuid do
              Publishing.update_post_primary_language(group_slug, post_uuid, primary_language)
            else
              {:error, :no_uuid}
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

  @doc """
  Creates a new migration job.

  ## Options

  - `:user_uuid` - User UUID for audit trail

  ## Examples

      MigratePrimaryLanguageWorker.create_job("docs", "en")
      MigratePrimaryLanguageWorker.create_job("docs", "en", user_uuid: "019145a1-0000-7000-8000-000000000001")

  """
  def create_job(group_slug, primary_language, opts \\ []) do
    args =
      %{
        "group_slug" => group_slug,
        "primary_language" => primary_language
      }
      |> maybe_put("user_uuid", Keyword.get(opts, :user_uuid))

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
