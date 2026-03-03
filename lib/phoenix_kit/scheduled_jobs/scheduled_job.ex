defmodule PhoenixKit.ScheduledJobs.ScheduledJob do
  @moduledoc """
  Schema for scheduled jobs.

  Represents a job scheduled to run at a specific time. Jobs are polymorphic and can
  reference any type of resource (posts, emails, notifications, etc.).

  ## Fields

  - `job_type` - Type identifier (e.g., "publish_post", "send_email")
  - `handler_module` - Module that implements `PhoenixKit.ScheduledJobs.Handler`
  - `resource_type` - Type of resource (e.g., "post", "email")
  - `resource_uuid` - UUID of the target resource
  - `scheduled_at` - When the job should execute
  - `executed_at` - When the job actually executed (nil if pending)
  - `status` - Current status: "pending", "executed", "failed", "cancelled"
  - `attempts` - Number of execution attempts
  - `max_attempts` - Maximum retry attempts (default: 3)
  - `last_error` - Error message from last failed attempt
  - `args` - Additional arguments passed to the handler
  - `priority` - Execution priority (higher = more urgent)
  - `created_by_uuid` - Optional user who created the job
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Utils.Date, as: UtilsDate

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(pending executed failed cancelled)

  schema "phoenix_kit_scheduled_jobs" do
    field :job_type, :string
    field :handler_module, :string
    field :resource_type, :string
    field :resource_uuid, UUIDv7
    field :scheduled_at, :utc_datetime
    field :executed_at, :utc_datetime
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :last_error, :string
    field :args, :map, default: %{}
    field :priority, :integer, default: 0
    field :created_by_uuid, UUIDv7

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new scheduled job.
  """
  def create_changeset(scheduled_job \\ %__MODULE__{}, attrs) do
    scheduled_job
    |> cast(attrs, [
      :job_type,
      :handler_module,
      :resource_type,
      :resource_uuid,
      :scheduled_at,
      :args,
      :priority,
      :max_attempts,
      :created_by_uuid
    ])
    |> validate_required([
      :job_type,
      :handler_module,
      :resource_type,
      :resource_uuid,
      :scheduled_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than: 0)
    |> validate_scheduled_at_future()
  end

  @doc """
  Changeset for marking a job as executed.
  """
  def execute_changeset(scheduled_job) do
    scheduled_job
    |> change(%{
      status: "executed",
      executed_at: UtilsDate.utc_now()
    })
  end

  @doc """
  Changeset for marking a job as failed.
  """
  def fail_changeset(scheduled_job, error) do
    error_message =
      case error do
        msg when is_binary(msg) -> msg
        {:error, reason} -> inspect(reason)
        other -> inspect(other)
      end

    new_attempts = scheduled_job.attempts + 1
    new_status = if new_attempts >= scheduled_job.max_attempts, do: "failed", else: "pending"

    scheduled_job
    |> change(%{
      status: new_status,
      attempts: new_attempts,
      last_error: error_message
    })
  end

  @doc """
  Changeset for cancelling a job.
  """
  def cancel_changeset(scheduled_job) do
    scheduled_job
    |> change(%{status: "cancelled"})
  end

  @doc """
  Changeset for rescheduling a job.
  """
  def reschedule_changeset(scheduled_job, new_scheduled_at) do
    scheduled_job
    |> change(%{
      scheduled_at: new_scheduled_at,
      status: "pending",
      attempts: 0,
      last_error: nil,
      executed_at: nil
    })
    |> validate_scheduled_at_future()
  end

  # Private helpers

  defp validate_scheduled_at_future(changeset) do
    validate_change(changeset, :scheduled_at, fn :scheduled_at, scheduled_at ->
      # Allow scheduling in the past for immediate execution
      # The cron job will pick it up on the next run
      if DateTime.compare(scheduled_at, UtilsDate.utc_now()) == :lt do
        # Warning but allow - job will execute on next cron run
        []
      else
        []
      end
    end)
  end
end
