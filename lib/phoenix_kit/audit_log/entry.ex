defmodule PhoenixKit.AuditLog.Entry do
  @moduledoc """
  Schema for audit log entries.

  Tracks administrative actions performed in PhoenixKit, providing a complete
  audit trail of sensitive operations.

  ## Fields
    * `target_user_id` - The ID of the user affected by the action
    * `admin_user_id` - The ID of the admin who performed the action
    * `action` - The type of action performed (e.g., "admin_password_reset")
    * `ip_address` - The IP address from which the action was performed
    * `user_agent` - The user agent string of the client
    * `metadata` - Additional metadata about the action (JSONB)
    * `inserted_at` - Timestamp when the log entry was created
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          target_user_id: integer(),
          admin_user_id: integer(),
          action: String.t(),
          ip_address: String.t() | nil,
          user_agent: String.t() | nil,
          metadata: map() | nil,
          inserted_at: DateTime.t() | nil
        }

  @valid_actions [
    "admin_password_reset",
    "user_created",
    "user_updated",
    "user_deleted",
    "user_confirmed",
    "user_locked",
    "user_unlocked",
    "role_assigned",
    "role_revoked"
  ]

  schema "phoenix_kit_audit_logs" do
    field :uuid, Ecto.UUID
    field :target_user_id, :integer
    field :admin_user_id, :integer
    field :action, :string
    field :ip_address, :string
    field :user_agent, :string
    field :metadata, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Creates a changeset for audit log entry.

  ## Required Fields
    * `:target_user_id` - ID of the affected user
    * `:admin_user_id` - ID of the admin performing the action
    * `:action` - Type of action performed

  ## Optional Fields
    * `:ip_address` - IP address of the admin
    * `:user_agent` - User agent string
    * `:metadata` - Additional metadata (JSONB)
  """
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:target_user_id, :admin_user_id, :action, :ip_address, :user_agent, :metadata])
    |> validate_required([:target_user_id, :admin_user_id, :action])
    |> validate_inclusion(:action, @valid_actions)
    |> validate_user_ids()
  end

  # Validate that user IDs are positive integers
  defp validate_user_ids(changeset) do
    changeset
    |> validate_number(:target_user_id, greater_than: 0)
    |> validate_number(:admin_user_id, greater_than: 0)
  end

  @doc """
  Returns the list of valid action types.
  """
  def valid_actions, do: @valid_actions
end
