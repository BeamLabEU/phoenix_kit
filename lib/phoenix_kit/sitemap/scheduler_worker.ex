defmodule PhoenixKit.Sitemap.SchedulerWorker do
  @moduledoc """
  Oban worker for scheduled sitemap regeneration.

  This worker is responsible for:
  - Periodic sitemap regeneration based on configured interval
  - Automatic re-scheduling after each run
  - Checking if scheduling is enabled before execution

  ## Configuration

  Scheduling is controlled via Settings:
  - `sitemap_schedule_enabled` - Enable/disable automatic regeneration
  - `sitemap_schedule_interval_hours` - Interval between regenerations (default: 24)

  ## Usage

      # Schedule initial job (called when schedule is enabled)
      PhoenixKit.Sitemap.SchedulerWorker.schedule()

      # Manual trigger
      PhoenixKit.Sitemap.SchedulerWorker.regenerate_now()

      # Cancel scheduled jobs
      PhoenixKit.Sitemap.SchedulerWorker.cancel_scheduled()

  ## Oban Queue

  Jobs are placed in the `:sitemap` queue with max 3 attempts.
  """

  use Oban.Worker, queue: :sitemap, max_attempts: 3

  import Ecto.Query

  require Logger

  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings
  alias PhoenixKit.Sitemap
  alias PhoenixKit.Sitemap.FileStorage
  alias PhoenixKit.Sitemap.Generator

  @doc """
  Performs sitemap regeneration.

  This callback is invoked by Oban when the scheduled job runs.
  It checks if scheduling is still enabled before regenerating.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    is_manual = args["manual"] == true

    if is_manual do
      Logger.info("SitemapSchedulerWorker: Starting manual regeneration")
    else
      Logger.info("SitemapSchedulerWorker: Starting scheduled regeneration")
    end

    cond do
      # Sitemap module must be enabled for any regeneration
      not Sitemap.enabled?() ->
        Logger.info("SitemapSchedulerWorker: Sitemap module disabled, skipping regeneration")
        :ok

      # Schedule check only applies to scheduled jobs, not manual ones
      not is_manual and not schedule_enabled?() ->
        Logger.info("SitemapSchedulerWorker: Scheduling disabled, skipping regeneration")
        :ok

      not valid_base_url?() ->
        Logger.warning("SitemapSchedulerWorker: Base URL not configured, skipping regeneration")
        :ok

      true ->
        do_perform_regeneration(args)
    end
  end

  defp valid_base_url? do
    base_url = Sitemap.get_base_url()
    base_url != ""
  end

  defp do_perform_regeneration(args) do
    base_url = Sitemap.get_base_url()

    case regenerate_sitemap(base_url) do
      :ok ->
        Logger.info("SitemapSchedulerWorker: Regeneration completed successfully")
        if args["scheduled"], do: schedule_next()
        :ok

      {:error, reason} ->
        Logger.error("SitemapSchedulerWorker: Regeneration failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @doc """
  Schedules the next sitemap regeneration.

  The job is scheduled based on `sitemap_schedule_interval_hours` setting.
  If scheduling is disabled, no job is created.

  ## Options

  - `:delay_hours` - Override the configured interval (optional)

  ## Examples

      # Schedule with configured interval
      PhoenixKit.Sitemap.SchedulerWorker.schedule()

      # Schedule with custom delay
      PhoenixKit.Sitemap.SchedulerWorker.schedule(delay_hours: 1)
  """
  @spec schedule(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()} | :disabled
  def schedule(opts \\ []) do
    if schedule_enabled?() do
      delay_hours = Keyword.get(opts, :delay_hours) || get_interval_hours()
      scheduled_at = DateTime.add(DateTime.utc_now(), delay_hours * 3600, :second)

      %{scheduled: true}
      |> new(scheduled_at: scheduled_at)
      |> insert_job()
    else
      Logger.info("SitemapSchedulerWorker: Scheduling disabled, job not created")
      :disabled
    end
  end

  @doc """
  Schedules the next regeneration after current job completes.
  """
  @spec schedule_next() :: {:ok, Oban.Job.t()} | {:error, term()} | :disabled
  def schedule_next do
    schedule()
  end

  @doc """
  Triggers immediate sitemap regeneration.

  This creates a job that runs immediately, bypassing the schedule.
  """
  @spec regenerate_now() :: {:ok, Oban.Job.t()} | {:error, term()}
  def regenerate_now do
    Logger.info("SitemapSchedulerWorker: Manual regeneration triggered")

    %{scheduled: false, manual: true}
    |> new()
    |> insert_job()
  end

  @doc """
  Ensures sitemap file exists on application startup.

  With file-only architecture, this is optional - sitemap will be generated
  on first request if file doesn't exist. Use this for explicit pre-warming.

  ## Returns

  - `{:ok, job}` - Regeneration job scheduled (file doesn't exist)
  - `:file_exists` - Sitemap file already exists
  - `:disabled` - Sitemap module is disabled

  ## Examples

      # In Application.start/2 or supervisor child
      PhoenixKit.Sitemap.SchedulerWorker.ensure_cache_warm()
  """
  @spec ensure_cache_warm() ::
          {:ok, Oban.Job.t()} | :file_exists | :disabled | {:error, term()}
  def ensure_cache_warm do
    cond do
      not Sitemap.enabled?() ->
        Logger.debug("SitemapSchedulerWorker: Sitemap disabled, skipping warm-up")
        :disabled

      FileStorage.exists?() ->
        Logger.debug("SitemapSchedulerWorker: Sitemap file already exists")
        :file_exists

      true ->
        Logger.info("SitemapSchedulerWorker: No sitemap file, triggering generation")
        regenerate_now()
    end
  end

  @doc """
  Cancels all scheduled sitemap jobs.

  This is called when scheduling is disabled.
  """
  @spec cancel_scheduled() :: {:ok, non_neg_integer()}
  def cancel_scheduled do
    # Cancel all pending/scheduled jobs for this worker
    worker_name = inspect(__MODULE__)

    {count, _} =
      Oban.Job
      |> where([j], j.worker == ^worker_name)
      |> where([j], j.state in ["available", "scheduled"])
      |> get_repo().delete_all()

    Logger.info("SitemapSchedulerWorker: Cancelled #{count} scheduled jobs")
    {:ok, count}
  end

  @doc """
  Returns the current scheduling status and next run time.
  """
  @spec status() :: map()
  def status do
    worker_name = inspect(__MODULE__)

    next_job =
      Oban.Job
      |> where([j], j.worker == ^worker_name)
      |> where([j], j.state in ["available", "scheduled"])
      |> order_by([j], asc: j.scheduled_at)
      |> limit(1)
      |> get_repo().one()

    %{
      enabled: schedule_enabled?(),
      interval_hours: get_interval_hours(),
      next_run: if(next_job, do: next_job.scheduled_at, else: nil),
      pending_jobs: count_pending_jobs()
    }
  end

  # Private functions

  defp regenerate_sitemap(base_url) do
    # Collect entries first to get URL count
    entries = Generator.collect_all_entries(base_url: base_url)
    url_count = length(entries)

    # Generate XML sitemap and save to file
    # File-only architecture: single file at priv/static/sitemap.xml
    case Generator.generate_xml(base_url: base_url, cache: true, xsl_style: "table") do
      {:ok, _xml} ->
        # Update generation stats with actual URL count
        Sitemap.update_generation_stats(%{url_count: url_count})

        # Broadcast completion for real-time UI updates
        broadcast_sitemap_generated(url_count)
        :ok

      {:ok, _xml, _parts} ->
        # Sitemap index was generated
        Sitemap.update_generation_stats(%{url_count: url_count})
        broadcast_sitemap_generated(url_count)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Broadcast sitemap generation completion for real-time UI updates
  defp broadcast_sitemap_generated(url_count) do
    PubSubManager.broadcast(
      "sitemap:updates",
      {:sitemap_generated, %{url_count: url_count, timestamp: DateTime.utc_now()}}
    )
  rescue
    # PubSub may not be available in all environments
    _ -> :ok
  end

  defp schedule_enabled? do
    Settings.get_boolean_setting("sitemap_schedule_enabled", false)
  end

  defp get_interval_hours do
    case Settings.get_setting("sitemap_schedule_interval_hours", "24") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {hours, _} when hours > 0 -> hours
          _ -> 24
        end

      value when is_integer(value) and value > 0 ->
        value

      _ ->
        24
    end
  end

  defp insert_job(changeset) do
    case get_repo().insert(changeset) do
      {:ok, job} ->
        Logger.info("SitemapSchedulerWorker: Job scheduled for #{job.scheduled_at}")
        {:ok, job}

      {:error, reason} ->
        Logger.error("SitemapSchedulerWorker: Failed to schedule job: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp count_pending_jobs do
    worker_name = inspect(__MODULE__)

    Oban.Job
    |> where([j], j.worker == ^worker_name)
    |> where([j], j.state in ["available", "scheduled"])
    |> get_repo().aggregate(:count)
  end

  defp get_repo do
    PhoenixKit.RepoHelper.repo()
  end
end
