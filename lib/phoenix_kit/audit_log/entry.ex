defmodule PhoenixKit.AuditLog.Entry do
  @moduledoc """
  Schema for audit log entries.

  Tracks administrative actions performed in PhoenixKit, providing a complete
  audit trail of sensitive operations.

  ## Fields
    * `target_user_uuid` - The UUID of the user affected by the action
    * `admin_user_uuid` - The UUID of the admin who performed the action
    * `action` - The type of action performed (e.g., "admin_password_reset")
    * `ip_address` - The IP address from which the action was performed
    * `user_agent` - The user agent string of the client
    * `metadata` - Additional metadata about the action (JSONB)
    * `inserted_at` - Timestamp when the log entry was created
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          target_user_uuid: UUIDv7.t() | nil,
          admin_user_uuid: UUIDv7.t() | nil,
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

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_audit_logs" do
    field :target_user_uuid, UUIDv7
    field :admin_user_uuid, UUIDv7
    field :action, :string
    field :ip_address, :string
    field :user_agent, :string
    field :metadata, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Creates a changeset for audit log entry.

  ## Required Fields
    * `:target_user_uuid` - UUID of the affected user
    * `:admin_user_uuid` - UUID of the admin performing the action
    * `:action` - Type of action performed

  ## Optional Fields
    * `:ip_address` - IP address of the admin
    * `:user_agent` - User agent string
    * `:metadata` - Additional metadata (JSONB)
  """
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :target_user_uuid,
      :admin_user_uuid,
      :action,
      :ip_address,
      :user_agent,
      :metadata
    ])
    |> validate_required([:target_user_uuid, :admin_user_uuid, :action])
    |> validate_inclusion(:action, @valid_actions)
  end

  @doc """
  Returns the list of valid action types.
  """
  def valid_actions, do: @valid_actions
end
