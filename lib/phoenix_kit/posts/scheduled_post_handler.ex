defmodule PhoenixKit.Posts.ScheduledPostHandler do
  @moduledoc """
  Handler for scheduled post publishing.

  This handler is called by the scheduled jobs system to publish posts
  that have reached their scheduled publish time.

  ## Usage

  Schedule a post for publishing:

      ScheduledJobs.schedule_job(
        PhoenixKit.Posts.ScheduledPostHandler,
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

  alias PhoenixKit.Posts

  @impl true
  def job_type, do: "publish_post"

  @impl true
  def resource_type, do: "post"

  @impl true
  def execute(post_id, _args) do
    case Posts.get_post(post_id) do
      nil ->
        {:error, :not_found}

      post ->
        case Posts.publish_post(post) do
          {:ok, _published_post} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
