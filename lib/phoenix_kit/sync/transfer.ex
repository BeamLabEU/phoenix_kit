defmodule PhoenixKit.Sync.Transfer do
  @moduledoc """
  Schema for DB Sync data transfers.

  Tracks all data transfers between PhoenixKit instances, including both
  uploads (sending data) and downloads (receiving data).

  ## Direction

  - `"send"` - This site sent data to another site
  - `"receive"` - This site received data from another site

  ## Status Flow

  ```
  pending → pending_approval → approved → in_progress → completed
                            ↘
                            denied
                            ↘
                            expired (approval timed out)

  pending → in_progress → completed
                       ↘
                       failed
                       ↘
                       cancelled
  ```

  ## Record Tracking

  The transfer tracks various record counts:
  - `records_requested` - Total records requested
  - `records_transferred` - Records actually transferred
  - `records_created` - New records inserted
  - `records_updated` - Existing records updated
  - `records_skipped` - Records skipped due to conflicts
  - `records_failed` - Records that failed to import

  ## Usage Examples

      # Create a transfer record
      {:ok, transfer} = Transfers.create_transfer(%{
        direction: "receive",
        connection_id: conn.id,
        table_name: "users",
        records_requested: 100,
        conflict_strategy: "skip"
      })

      # Update transfer progress
      {:ok, transfer} = Transfers.update_progress(transfer, %{
        records_transferred: 50,
        records_created: 45,
        records_skipped: 5
      })

      # Complete a transfer
      {:ok, transfer} = Transfers.complete_transfer(transfer)
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Sync.Connection
  alias PhoenixKit.Users.Auth.User

  @type t :: %__MODULE__{}

  @primary_key {:id, :id, autogenerate: true}

  @valid_directions ~w(send receive)
  @valid_statuses ~w(pending pending_approval approved denied in_progress completed failed cancelled expired)
  @valid_conflict_strategies ~w(skip overwrite merge append)

  schema "phoenix_kit_sync_transfers" do
    field :uuid, Ecto.UUID
    field :direction, :string
    field :session_code, :string
    field :remote_site_url, :string
    field :table_name, :string
    field :records_requested, :integer, default: 0
    field :records_transferred, :integer, default: 0
    field :records_created, :integer, default: 0
    field :records_updated, :integer, default: 0
    field :records_skipped, :integer, default: 0
    field :records_failed, :integer, default: 0
    field :bytes_transferred, :integer, default: 0
    field :conflict_strategy, :string

    # Status and approval
    field :status, :string, default: "pending"
    field :requires_approval, :boolean, default: false
    field :approved_at, :utc_datetime_usec
    field :denied_at, :utc_datetime_usec
    field :denial_reason, :string
    field :approval_expires_at, :utc_datetime_usec

    # Request context
    field :requester_ip, :string
    field :requester_user_agent, :string

    field :error_message, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :connection, Connection
    belongs_to :approved_by_user, User, foreign_key: :approved_by
    belongs_to :denied_by_user, User, foreign_key: :denied_by
    belongs_to :initiated_by_user, User, foreign_key: :initiated_by

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Creates a changeset for transfer creation.
  """
  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [
      :direction,
      :connection_id,
      :session_code,
      :remote_site_url,
      :table_name,
      :records_requested,
      :conflict_strategy,
      :status,
      :requires_approval,
      :approval_expires_at,
      :requester_ip,
      :requester_user_agent,
      :initiated_by,
      :metadata
    ])
    |> validate_required([:direction, :table_name])
    |> validate_inclusion(:direction, @valid_directions)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_conflict_strategy()
    |> foreign_key_constraint(:connection_id)
    |> foreign_key_constraint(:initiated_by)
    |> maybe_generate_uuid()
  end

  defp maybe_generate_uuid(changeset) do
    case get_field(changeset, :uuid) do
      nil -> put_change(changeset, :uuid, UUIDv7.generate())
      _ -> changeset
    end
  end

  @doc """
  Changeset for starting a transfer.
  """
  def start_changeset(transfer) do
    transfer
    |> change(%{
      status: "in_progress",
      started_at: DateTime.utc_now()
    })
  end

  @doc """
  Changeset for updating transfer progress.
  """
  def progress_changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [
      :records_transferred,
      :records_created,
      :records_updated,
      :records_skipped,
      :records_failed,
      :bytes_transferred
    ])
    |> validate_number(:records_transferred, greater_than_or_equal_to: 0)
    |> validate_number(:records_created, greater_than_or_equal_to: 0)
    |> validate_number(:records_updated, greater_than_or_equal_to: 0)
    |> validate_number(:records_skipped, greater_than_or_equal_to: 0)
    |> validate_number(:records_failed, greater_than_or_equal_to: 0)
    |> validate_number(:bytes_transferred, greater_than_or_equal_to: 0)
  end

  @doc """
  Changeset for completing a transfer successfully.
  """
  def complete_changeset(transfer, attrs \\ %{}) do
    transfer
    |> cast(attrs, [
      :records_transferred,
      :records_created,
      :records_updated,
      :records_skipped,
      :records_failed,
      :bytes_transferred
    ])
    |> change(%{
      status: "completed",
      completed_at: DateTime.utc_now()
    })
  end

  @doc """
  Changeset for marking a transfer as failed.
  """
  def fail_changeset(transfer, error_message) do
    transfer
    |> change(%{
      status: "failed",
      error_message: error_message,
      completed_at: DateTime.utc_now()
    })
  end

  @doc """
  Changeset for cancelling a transfer.
  """
  def cancel_changeset(transfer) do
    transfer
    |> change(%{
      status: "cancelled",
      completed_at: DateTime.utc_now()
    })
  end

  @doc """
  Changeset for requesting approval.
  """
  def request_approval_changeset(transfer, expires_in_hours \\ 24) do
    expires_at = DateTime.utc_now() |> DateTime.add(expires_in_hours * 3600, :second)

    transfer
    |> change(%{
      status: "pending_approval",
      requires_approval: true,
      approval_expires_at: expires_at
    })
  end

  @doc """
  Changeset for approving a transfer.
  """
  def approve_changeset(transfer, admin_user_id) do
    transfer
    |> change(%{
      status: "approved",
      approved_at: DateTime.utc_now(),
      approved_by: admin_user_id
    })
  end

  @doc """
  Changeset for denying a transfer.
  """
  def deny_changeset(transfer, admin_user_id, reason \\ nil) do
    transfer
    |> change(%{
      status: "denied",
      denied_at: DateTime.utc_now(),
      denied_by: admin_user_id,
      denial_reason: reason
    })
  end

  @doc """
  Changeset for marking a transfer approval as expired.
  """
  def expire_changeset(transfer) do
    transfer
    |> change(%{status: "expired"})
  end

  # Validate conflict strategy if provided
  defp validate_conflict_strategy(changeset) do
    case get_field(changeset, :conflict_strategy) do
      nil -> changeset
      _ -> validate_inclusion(changeset, :conflict_strategy, @valid_conflict_strategies)
    end
  end

  @doc """
  Checks if a transfer is pending approval.
  """
  def pending_approval?(%__MODULE__{status: "pending_approval"}), do: true
  def pending_approval?(_), do: false

  @doc """
  Checks if a transfer's approval has expired.
  """
  def approval_expired?(%__MODULE__{approval_expires_at: nil}), do: false

  def approval_expired?(%__MODULE__{approval_expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Checks if a transfer can be started.
  """
  def can_start?(%__MODULE__{status: "pending", requires_approval: false}), do: true
  def can_start?(%__MODULE__{status: "approved"}), do: true
  def can_start?(_), do: false

  @doc """
  Checks if a transfer is in a terminal state.
  """
  def terminal?(%__MODULE__{status: status})
      when status in ["completed", "failed", "cancelled", "denied", "expired"],
      do: true

  def terminal?(_), do: false

  @doc """
  Checks if a transfer is currently active.
  """
  def active?(%__MODULE__{status: "in_progress"}), do: true
  def active?(_), do: false

  @doc """
  Calculates the success rate of a transfer.
  Returns a float between 0.0 and 1.0.
  """
  def success_rate(%__MODULE__{records_transferred: 0}), do: 0.0

  def success_rate(%__MODULE__{
        records_created: created,
        records_updated: updated,
        records_transferred: transferred
      }) do
    (created + updated) / transferred
  end

  @doc """
  Calculates the transfer duration in seconds.
  Returns nil if transfer hasn't completed.
  """
  def duration_seconds(%__MODULE__{started_at: nil}), do: nil
  def duration_seconds(%__MODULE__{completed_at: nil}), do: nil

  def duration_seconds(%__MODULE__{started_at: started_at, completed_at: completed_at}) do
    DateTime.diff(completed_at, started_at, :second)
  end
end
