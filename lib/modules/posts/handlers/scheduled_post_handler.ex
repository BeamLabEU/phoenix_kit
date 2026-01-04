defmodule PhoenixKit.Modules.Posts.ScheduledPostHandler do
  @moduledoc """
  Handler for scheduled post publishing.

  This handler is called by the scheduled jobs system to publish posts
  that have reached their scheduled publish time.

  ## Usage

  Schedule a post for publishing:

      ScheduledJobs.schedule_job(
        PhoenixKit.Modules.Posts.ScheduledPostHandler,
        post.id,
        ~U[2025-01-15 10:00:00Z]
      )

  ## Behavior

  When executed:
  1. Loads the post by ID
  2. Calls `Posts.publish_post/1` to change status to "public"
  3. Returns `:ok` on success, `{:error, reason}` on failure

  ## Error Cases

  - Post not found: Returns `{:error, :not_found}`
  - Post already published: Still calls publish_post (idempotent)
  - Database error: Returns `{:error, changeset}`
  """

  @behaviour PhoenixKit.ScheduledJobs.Handler

  require Logger

  alias PhoenixKit.Modules.Posts

  @impl true
  def job_type, do: "publish_post"

  @impl true
  def resource_type, do: "post"

  @impl true
  def execute(post_id, _args) do
    Logger.info("ScheduledPostHandler: Publishing post #{inspect(post_id)}")

    case Posts.get_post(post_id) do
      nil ->
        Logger.warning("ScheduledPostHandler: Post #{inspect(post_id)} not found")
        {:error, :not_found}

      post ->
        Logger.debug(
          "ScheduledPostHandler: Found post with status=#{post.status}, title=#{post.title}"
        )

        case Posts.publish_post(post) do
          {:ok, published_post} ->
            Logger.info(
              "ScheduledPostHandler: Successfully published post #{post_id}, new status=#{published_post.status}"
            )

            :ok

          {:error, reason} ->
            Logger.error(
              "ScheduledPostHandler: Failed to publish post #{post_id}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end
end
