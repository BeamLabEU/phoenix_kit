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

  use Oban.Worker, queue: :scheduled_jobs, max_attempts: 1

  require Logger

  alias PhoenixKit.ScheduledJobs

  @impl Oban.Worker
  def perform(%Oban.Job{args: _args}) do
    pending_jobs = ScheduledJobs.get_pending_jobs()
    pending_count = length(pending_jobs)

    if pending_count > 0 do
      Logger.info("ProcessScheduledJobsWorker: Found #{pending_count} pending job(s) to process")

      Enum.each(pending_jobs, fn job ->
        Logger.debug(
          "ProcessScheduledJobsWorker: Job #{job.id} - type=#{job.job_type}, resource=#{job.resource_type}/#{job.resource_uuid}, scheduled_at=#{job.scheduled_at}"
        )
      end)
    end

    {:ok, stats} = ScheduledJobs.process_pending_jobs()

    if stats.executed > 0 or stats.failed > 0 do
      Logger.info(
        "ProcessScheduledJobsWorker: Completed processing - #{stats.executed} executed, #{stats.failed} failed"
      )
    end

    catchup_scheduled_posts()
    catchup_scheduled_broadcasts()

    # Cleanup: Delete old completed jobs to prevent table bloat
    ScheduledJobs.delete_old_jobs()

    :ok
  end

  # Catch-up: Publish any posts that are "scheduled" with past scheduled_at
  # This handles orphaned posts without scheduled jobs (e.g., server was down, job failed)
  defp catchup_scheduled_posts do
    if Code.ensure_loaded?(PhoenixKitPosts) and
         function_exported?(PhoenixKitPosts, :process_scheduled_posts, 0) do
      {:ok, catchup_count} = apply(PhoenixKitPosts, :process_scheduled_posts, [])

      if catchup_count > 0 do
        Logger.info("ProcessScheduledJobsWorker: Published #{catchup_count} catch-up post(s)")
      end
    end
  end

  # Catch-up: Send any broadcasts that are "scheduled" with past scheduled_at
  defp catchup_scheduled_broadcasts do
    newsletters_mod = PhoenixKit.ModuleRegistry.get_by_key("newsletters")

    if newsletters_mod && Code.ensure_loaded?(newsletters_mod) &&
         function_exported?(newsletters_mod, :enabled?, 0) &&
         function_exported?(newsletters_mod, :process_scheduled_broadcasts, 0) &&
         newsletters_mod.enabled?() do
      {:ok, newsletters_count} = newsletters_mod.process_scheduled_broadcasts()

      if newsletters_count > 0 do
        Logger.info(
          "ProcessScheduledJobsWorker: Sent #{newsletters_count} scheduled broadcast(s)"
        )
      end
    end
  end
end
