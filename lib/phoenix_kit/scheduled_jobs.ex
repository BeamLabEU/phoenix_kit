defmodule PhoenixKit.ScheduledJobs do
  @moduledoc """
  Context module for managing scheduled jobs.

  Provides functions to create, cancel, and process scheduled jobs. The system uses
  a behaviour-based handler pattern for extensibility - any module implementing
  `PhoenixKit.ScheduledJobs.Handler` can be used to handle scheduled tasks.

  ## Usage

      # Schedule a job using a handler module
      {:ok, job} = ScheduledJobs.schedule_job(
        MyApp.Posts.ScheduledPostHandler,
        post.uuid,
        ~U[2025-01-15 10:00:00Z],
        %{notify: true}
      )

      # Cancel a scheduled job
      {:ok, job} = ScheduledJobs.cancel_job(job)

      # Process all pending jobs (called by cron worker)
      {:ok, %{executed: 5, failed: 1}} = ScheduledJobs.process_pending_jobs()

  ## Handler Pattern

  Handlers must implement the `PhoenixKit.ScheduledJobs.Handler` behaviour:

      defmodule MyHandler do
        @behaviour PhoenixKit.ScheduledJobs.Handler

        def job_type, do: "my_job"
        def resource_type, do: "my_resource"
        def execute(resource_uuid, args), do: :ok
      end
  """

  import Ecto.Query
  require Logger

  alias PhoenixKit.Config
  alias PhoenixKit.ScheduledJobs.ScheduledJob
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # Get the configured repo
  defp repo, do: Config.get_repo()

  ## Public API

  @doc """
  Schedules a new job.

  ## Parameters

  - `handler_module` - Module implementing `PhoenixKit.ScheduledJobs.Handler`
  - `resource_uuid` - UUID of the target resource
  - `scheduled_at` - DateTime when the job should execute
  - `args` - Optional map of additional arguments (default: %{})
  - `opts` - Optional keyword list with:
    - `:priority` - Job priority (default: 0)
    - `:max_attempts` - Max retry attempts (default: 3)
    - `:created_by_uuid` - UUID of user creating the job

  ## Returns

  - `{:ok, %ScheduledJob{}}` - Job created successfully
  - `{:error, changeset}` - Validation failed

  ## Examples

      iex> schedule_job(PostHandler, post.uuid, ~U[2025-01-15 10:00:00Z])
      {:ok, %ScheduledJob{}}

      iex> schedule_job(EmailHandler, email.uuid, scheduled_at, %{template: "welcome"}, priority: 10)
      {:ok, %ScheduledJob{}}
  """
  def schedule_job(handler_module, resource_uuid, scheduled_at, args \\ %{}, opts \\ []) do
    attrs = %{
      job_type: handler_module.job_type(),
      handler_module: to_string(handler_module),
      resource_type: handler_module.resource_type(),
      resource_uuid: resource_uuid,
      scheduled_at: scheduled_at,
      args: args,
      priority: Keyword.get(opts, :priority, 0),
      max_attempts: Keyword.get(opts, :max_attempts, 3),
      created_by_uuid: Keyword.get(opts, :created_by_uuid)
    }

    %ScheduledJob{}
    |> ScheduledJob.create_changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Cancels a scheduled job.

  Only pending jobs can be cancelled. Returns error if job is already executed or cancelled.

  ## Examples

      iex> cancel_job(job)
      {:ok, %ScheduledJob{status: "cancelled"}}

      iex> cancel_job(already_executed_job)
      {:error, :already_executed}
  """
  def cancel_job(%ScheduledJob{status: "pending"} = job) do
    job
    |> ScheduledJob.cancel_changeset()
    |> repo().update()
  end

  def cancel_job(%ScheduledJob{status: "executed"}), do: {:error, :already_executed}
  def cancel_job(%ScheduledJob{status: "cancelled"}), do: {:error, :already_cancelled}
  def cancel_job(%ScheduledJob{status: "failed"}), do: {:error, :already_failed}

  @doc """
  Cancels all pending jobs for a specific resource.

  Useful when deleting a resource or when rescheduling.

  ## Examples

      iex> cancel_jobs_for_resource("post", post.uuid)
      {3, nil}
  """
  def cancel_jobs_for_resource(resource_type, resource_uuid) do
    from(j in ScheduledJob,
      where: j.resource_type == ^resource_type,
      where: j.resource_uuid == ^resource_uuid,
      where: j.status == "pending"
    )
    |> repo().update_all(set: [status: "cancelled", updated_at: UtilsDate.utc_now()])
  end

  @doc """
  Reschedules a job to a new time.

  Resets attempts and clears any previous errors.

  ## Examples

      iex> reschedule_job(job, ~U[2025-01-20 10:00:00Z])
      {:ok, %ScheduledJob{}}
  """
  def reschedule_job(%ScheduledJob{} = job, new_scheduled_at) do
    job
    |> ScheduledJob.reschedule_changeset(new_scheduled_at)
    |> repo().update()
  end

  @doc """
  Processes all pending jobs that are due for execution.

  Called by the cron worker every minute. Jobs are processed in priority order
  (highest first), then by scheduled_at (oldest first).

  ## Returns

  - `{:ok, %{executed: count, failed: count}}` - Processing summary

  ## Examples

      iex> process_pending_jobs()
      {:ok, %{executed: 5, failed: 1}}
  """
  def process_pending_jobs do
    now = UtilsDate.utc_now()

    pending_jobs = get_pending_jobs(now)

    results =
      Enum.map(pending_jobs, fn job ->
        execute_job(job)
      end)

    executed = Enum.count(results, &match?(:ok, &1))
    failed = Enum.count(results, &match?({:error, _}, &1))

    if executed > 0 or failed > 0 do
      Logger.info(
        "ScheduledJobs: Processed #{executed + failed} jobs (#{executed} executed, #{failed} failed)"
      )
    end

    {:ok, %{executed: executed, failed: failed}}
  end

  @doc """
  Gets all pending jobs that are due for execution.

  ## Parameters

  - `as_of` - DateTime to check against (default: now)

  ## Examples

      iex> get_pending_jobs()
      [%ScheduledJob{}, ...]
  """
  def get_pending_jobs(as_of \\ UtilsDate.utc_now()) do
    from(j in ScheduledJob,
      where: j.status == "pending",
      where: j.scheduled_at <= ^as_of,
      order_by: [desc: j.priority, asc: j.scheduled_at]
    )
    |> repo().all(log: false)
  end

  @doc """
  Gets a scheduled job by ID.
  """
  def get_job(id) do
    repo().get(ScheduledJob, id)
  end

  @doc """
  Gets all scheduled jobs for a resource.

  ## Examples

      iex> get_jobs_for_resource("post", post.uuid)
      [%ScheduledJob{}, ...]
  """
  def get_jobs_for_resource(resource_type, resource_uuid) do
    from(j in ScheduledJob,
      where: j.resource_type == ^resource_type,
      where: j.resource_uuid == ^resource_uuid,
      order_by: [desc: j.inserted_at]
    )
    |> repo().all()
  end

  @doc """
  Gets the pending job for a resource (if any).

  ## Examples

      iex> get_pending_job_for_resource("post", post.uuid)
      %ScheduledJob{status: "pending"}
  """
  def get_pending_job_for_resource(resource_type, resource_uuid) do
    from(j in ScheduledJob,
      where: j.resource_type == ^resource_type,
      where: j.resource_uuid == ^resource_uuid,
      where: j.status == "pending",
      limit: 1
    )
    |> repo().one()
  end

  ## Private Functions

  defp execute_job(%ScheduledJob{} = job) do
    Logger.info(
      "ScheduledJobs: Executing job #{job.uuid} (#{job.job_type}) for #{job.resource_type}/#{job.resource_uuid}"
    )

    handler_module = String.to_existing_atom(job.handler_module)
    Logger.debug("ScheduledJobs: Using handler module #{handler_module}")

    case handler_module.execute(job.resource_uuid, job.args) do
      :ok ->
        Logger.info("ScheduledJobs: Job #{job.uuid} executed successfully")
        mark_executed(job)
        :ok

      {:ok, _result} ->
        Logger.info("ScheduledJobs: Job #{job.uuid} executed successfully")
        mark_executed(job)
        :ok

      {:error, reason} = error ->
        Logger.warning("ScheduledJobs: Job #{job.uuid} failed with reason: #{inspect(reason)}")
        mark_failed(job, reason)
        error
    end
  rescue
    e ->
      error_message = Exception.message(e)
      mark_failed(job, error_message)

      Logger.error(
        "ScheduledJobs: Job #{job.uuid} (#{job.job_type}) failed with exception: #{error_message}"
      )

      {:error, e}
  end

  defp mark_executed(%ScheduledJob{} = job) do
    job
    |> ScheduledJob.execute_changeset()
    |> repo().update()
  end

  defp mark_failed(%ScheduledJob{} = job, error) do
    job
    |> ScheduledJob.fail_changeset(error)
    |> repo().update()
  end
end
