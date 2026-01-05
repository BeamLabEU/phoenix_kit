defmodule PhoenixKit.Modules.Posts.Workers.PublishScheduledPostsJob do
  @moduledoc """
  Oban cron job for publishing scheduled posts.

  This job runs every minute to check for posts that are scheduled
  to be published and updates their status from "scheduled" to "published".

  ## Configuration

  Add to your Oban cron configuration:

      config :phoenix_kit, Oban,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             {"* * * * *", PhoenixKit.Modules.Posts.Workers.PublishScheduledPostsJob}
           ]}
        ]

  ## Behavior

  - Runs every minute via Oban.Plugins.Cron
  - Processes all posts with status="scheduled" and publish_at <= now
  - Updates post status to "published"
  - Logs successful and failed publishing attempts
  - Retries up to 3 times on failure (Oban default)
  """
  use Oban.Worker, queue: :posts, max_attempts: 3

  require Logger

  alias PhoenixKit.Modules.Posts

  @doc """
  Process scheduled posts that are ready to be published.

  This is called automatically by Oban's cron plugin every minute.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: _args}) do
    {:ok, published_count} = Posts.process_scheduled_posts()

    if published_count > 0 do
      Logger.info("PublishScheduledPostsJob: Successfully published #{published_count} post(s)")
    end

    :ok
  end
end
