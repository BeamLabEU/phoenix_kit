defmodule PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker do
  @moduledoc """
  Oban worker that processes pending scheduled jobs.

  This worker runs every minute via Oban's cron plugin and processes all
  scheduled jobs that are due for execution. It replaces the single-purpose
  `PublishScheduledPostsJob` with a universal job processor.

  ## Configuration

  Add to your Oban cron configuration:

      config :your_app, Oban,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}
           ]}
        ]

  ## Behavior

  1. Runs every minute
  2. Queries all pending jobs where `scheduled_at <= now`
  3. Orders by priority (DESC) then scheduled_at (ASC)
  4. For each job, loads the handler module and calls `execute/2`
  5. Marks jobs as executed or failed based on result
  6. Logs summary of processed jobs

  ## Error Handling

  - Jobs that fail are marked with incremented attempt count
  - After max_attempts, job status changes to "failed"
  - Exceptions are caught, logged, and treated as failures
  - Worker itself always returns :ok to prevent Oban retries
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias PhoenixKit.ScheduledJobs

  @impl Oban.Worker
  def perform(%Oban.Job{args: _args}) do
    {:ok, stats} = ScheduledJobs.process_pending_jobs()

    if stats.executed > 0 or stats.failed > 0 do
      Logger.info(
        "ProcessScheduledJobsWorker: Completed processing - #{stats.executed} executed, #{stats.failed} failed"
      )
    end

    :ok
  end
end
