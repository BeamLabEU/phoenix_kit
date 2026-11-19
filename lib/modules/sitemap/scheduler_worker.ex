defmodule PhoenixKit.Modules.Sitemap.SchedulerWorker do
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
      PhoenixKit.Modules.Sitemap.SchedulerWorker.schedule()

      # Manual trigger
      PhoenixKit.Modules.Sitemap.SchedulerWorker.regenerate_now()

      # Cancel scheduled jobs
      PhoenixKit.Modules.Sitemap.SchedulerWorker.cancel_scheduled()

  ## Oban Queue

  Jobs are placed in the `:sitemap` queue with max 3 attempts.
  """

  use Oban.Worker, queue: :sitemap, max_attempts: 3

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKit.Modules.Sitemap.FileStorage
  alias PhoenixKit.Modules.Sitemap.Generator
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate

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

    result =
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

    # The chain must survive a skipped or failed run: a scheduled job that
    # returned without rescheduling (base URL briefly empty, one transient
    # generation error) used to stop regeneration until the next boot's
    # `ensure_scheduled/0`. Scheduling still enabled → keep the chain alive.
    if args["scheduled"] and schedule_enabled?() and Sitemap.enabled?() do
      schedule_next()
    end

    result
  end

  defp valid_base_url? do
    base_url = Sitemap.get_base_url()
    base_url != ""
  end

  defp do_perform_regeneration(args) do
    base_url = Sitemap.get_base_url()

    result =
      case args["source"] do
        nil ->
          # Full regeneration
          regenerate_sitemap(base_url)

        source_name ->
          # Per-module regeneration: regenerate one source, rebuild index
          Logger.info("SitemapSchedulerWorker: Regenerating module '#{source_name}'")
          regenerate_sitemap(base_url)
      end

    case result do
      :ok ->
        Logger.info("SitemapSchedulerWorker: Regeneration completed successfully")
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
      PhoenixKit.Modules.Sitemap.SchedulerWorker.schedule()

      # Schedule with custom delay
      PhoenixKit.Modules.Sitemap.SchedulerWorker.schedule(delay_hours: 1)
  """
  @spec schedule(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()} | :disabled
  def schedule(opts \\ []) do
    if schedule_enabled?() do
      delay_hours = Keyword.get(opts, :delay_hours) || get_interval_hours()
      scheduled_at = DateTime.add(UtilsDate.utc_now(), delay_hours * 3600, :second)

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
  Ensures a scheduled job exists when scheduling is enabled.

  Called on application startup to recover the scheduling chain if it was
  broken by a server restart, Oban pruning, or job failure.
  """
  @spec ensure_scheduled() ::
          {:ok, Oban.Job.t()} | {:error, term()} | :disabled | :already_scheduled
  def ensure_scheduled do
    if schedule_enabled?() and count_pending_jobs() == 0 do
      Logger.info("SitemapSchedulerWorker: No pending jobs found on startup, scheduling")
      schedule()
    else
      if schedule_enabled?(), do: :already_scheduled, else: :disabled
    end
  end

  @doc """
  Boot-time entry point for `ensure_scheduled/0`, started by the module's
  `children/0`.

  The installer places `PhoenixKit.Supervisor` — which starts module children
  — BEFORE Oban in the host's supervision tree, so when this runs the Oban
  instance is usually not registered yet. On a host with scheduled
  regeneration enabled, `ensure_scheduled/0` then raised
  `No Oban instance named Oban is running` on boot and the recovery never
  happened.

  With scheduled regeneration disabled this returns `:disabled` at once,
  without touching Oban. Otherwise it waits until the instance is registered,
  then ensures the chain; if Oban never comes up within `:timeout`, it logs a
  warning and returns `:oban_unavailable` instead of crashing.

  Options: `:timeout` and `:interval` in milliseconds (defaults 60 s and
  250 ms). For tests only: `:oban` — the name the wait looks for (the check
  itself always uses the default `Oban` instance) — and `:enabled?`, which
  stands in for the `sitemap_schedule_enabled` setting.
  """
  @spec ensure_scheduled_on_boot(keyword()) ::
          {:ok, Oban.Job.t()}
          | {:error, term()}
          | :disabled
          | :already_scheduled
          | :oban_unavailable
  def ensure_scheduled_on_boot(opts \\ []) do
    oban = Keyword.get(opts, :oban, Oban)
    timeout = Keyword.get(opts, :timeout, :timer.seconds(60))
    interval = Keyword.get(opts, :interval, 250)

    cond do
      not Keyword.get_lazy(opts, :enabled?, &schedule_enabled?/0) ->
        :disabled

      await_oban(oban, timeout, interval) ->
        ensure_scheduled()

      true ->
        Logger.warning(
          "SitemapSchedulerWorker: Oban instance #{inspect(oban)} is not running, " <>
            "the boot-time scheduling check was skipped"
        )

        :oban_unavailable
    end
  end

  @doc false
  # Polls until the named Oban instance is registered. Public for tests.
  @spec await_oban(Oban.name(), non_neg_integer(), pos_integer()) :: boolean()
  def await_oban(oban, timeout, interval) do
    do_await_oban(oban, System.monotonic_time(:millisecond) + timeout, interval)
  end

  defp do_await_oban(oban, deadline, interval) do
    cond do
      Oban.whereis(oban) != nil ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(interval)
        do_await_oban(oban, deadline, interval)
    end
  end

  # Future: Per-module event-driven regeneration pattern:
  # When a specific source's content changes (e.g., new product, new post),
  # call regenerate_module_now/1 to regenerate only that source's sitemap
  # and rebuild the index, instead of regenerating everything.

  @doc """
  Triggers immediate regeneration for a specific source module.

  Regenerates only the specified source's sitemap file and rebuilds the index.
  """
  @spec regenerate_module_now(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def regenerate_module_now(source_name) when is_binary(source_name) do
    Logger.info("SitemapSchedulerWorker: Manual module regeneration triggered for #{source_name}")

    %{scheduled: false, manual: true, source: source_name}
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
      PhoenixKit.Modules.Sitemap.SchedulerWorker.ensure_cache_warm()
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
      |> oban_repo_delete_all()

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
      |> oban_repo_one()

    %{
      enabled: schedule_enabled?(),
      interval_hours: get_interval_hours(),
      next_run: if(next_job, do: next_job.scheduled_at, else: nil),
      pending_jobs: count_pending_jobs()
    }
  end

  # Private functions

  defp regenerate_sitemap(base_url) do
    opts = [base_url: base_url, xsl_style: "table", xsl_enabled: true]

    case Generator.generate_all(opts) do
      {:ok, %{total_urls: url_count, modules: modules}} ->
        # Stats updates are best-effort - broadcast must happen even if stats fail
        try do
          Sitemap.update_generation_stats(%{url_count: url_count})
          Sitemap.update_module_stats(modules)
        rescue
          error ->
            Logger.warning("SitemapSchedulerWorker: Stats update failed: #{inspect(error)}")
        end

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
      {:sitemap_generated, %{url_count: url_count, timestamp: UtilsDate.utc_now()}}
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

  # Through Oban, not the repo: `Oban.Job` carries no `@schema_prefix`, so a
  # raw `Repo.insert` lands in `public.oban_jobs` on a prefixed install — a
  # table no Oban instance polls. Oban.insert also fires the insert
  # notification so the job is picked up without waiting for the poller.
  defp insert_job(changeset) do
    case Oban.insert(changeset) do
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
    |> oban_repo_aggregate(:count)
  end

  # Oban.Repo threads the instance's `prefix` into every query, so these hit
  # the same `oban_jobs` table the running Oban instance polls.
  defp oban_repo_one(query), do: Oban.Repo.one(Oban.config(), query)
  defp oban_repo_delete_all(query), do: Oban.Repo.delete_all(Oban.config(), query)
  defp oban_repo_aggregate(query, agg), do: Oban.Repo.aggregate(Oban.config(), query, agg)
end
