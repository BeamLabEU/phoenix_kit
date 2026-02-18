defmodule PhoenixKit.Modules.Connections.Connection do
  @moduledoc """
  Schema for two-way mutual connection relationships.

  Represents a bidirectional relationship that requires acceptance from both parties.
  Similar to LinkedIn connections or Facebook friend requests.

  ## Status Flow

  - `pending` - Request sent, awaiting response
  - `accepted` - Both parties have agreed to connect
  - `rejected` - Recipient declined the request

  ## Fields

  - `requester_uuid` - UUID of the user who initiated the connection request
  - `recipient_uuid` - UUID of the user who received the request
  - `requester_id` - Integer ID (deprecated, dual-write only)
  - `recipient_id` - Integer ID (deprecated, dual-write only)
  - `status` - Current status of the connection
  - `requested_at` - When the request was sent
  - `responded_at` - When the recipient responded (nil if pending)

  ## Examples

      # Pending connection request
      %Connection{
        uuid: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        requester_uuid: "019abc12-3456-7890-abcd-ef1234567890",
        recipient_uuid: "019abc12-9876-5432-abcd-ef1234567890",
        status: "pending",
        requested_at: ~N[2025-01-15 10:30:00],
        responded_at: nil
      }

      # Accepted connection
      %Connection{
        uuid: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        requester_uuid: "019abc12-3456-7890-abcd-ef1234567890",
        recipient_uuid: "019abc12-9876-5432-abcd-ef1234567890",
        status: "accepted",
        requested_at: ~N[2025-01-15 10:30:00],
        responded_at: ~N[2025-01-15 11:00:00]
      }

  ## Business Rules

  - Cannot connect with yourself
  - Cannot connect if blocked (either direction)
  - If A requests B while B has pending request to A -> auto-accept both
  - Only one active connection per user pair
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}

  @statuses ["pending", "accepted", "rejected"]

  @type status :: String.t()

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          requester_uuid: UUIDv7.t(),
          recipient_uuid: UUIDv7.t(),
          requester_id: integer() | nil,
          recipient_id: integer() | nil,
          status: status(),
          requested_at: DateTime.t(),
          responded_at: DateTime.t() | nil,
          requester: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          recipient: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_user_connections" do
    belongs_to :requester, PhoenixKit.Users.Auth.User,
      foreign_key: :requester_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :recipient, PhoenixKit.Users.Auth.User,
      foreign_key: :recipient_uuid,
      references: :uuid,
      type: UUIDv7

    field :requester_id, :integer
    field :recipient_id, :integer

    field :status, :string, default: "pending"
    field :requested_at, :utc_datetime
    field :responded_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the list of valid statuses.
  """
  def statuses, do: @statuses

  @doc """
  Changeset for creating a new connection request.

  ## Required Fields

  - `requester_uuid` - UUID of the user sending the request
  - `recipient_uuid` - UUID of the user receiving the request

  ## Optional Fields (dual-write)

  - `requester_id` - Integer ID (deprecated)
  - `recipient_id` - Integer ID (deprecated)

  ## Validation Rules

  - Both user UUIDs are required
  - Cannot request connection with yourself
  - Status must be valid
  """
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :requester_uuid,
      :recipient_uuid,
      :requester_id,
      :recipient_id,
      :status,
      :requested_at,
      :responded_at
    ])
    |> validate_required([:requester_uuid, :recipient_uuid])
    |> validate_inclusion(:status, @statuses)
    |> validate_not_self_connection()
    |> put_requested_at()
    |> foreign_key_constraint(:requester_uuid)
    |> foreign_key_constraint(:recipient_uuid)
  end

  @doc """
  Changeset for updating connection status (accept/reject).
  """
  def status_changeset(connection, attrs) do
    connection
    |> cast(attrs, [:status, :responded_at])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
    |> put_responded_at()
  end

  defp validate_not_self_connection(changeset) do
    requester_uuid = get_field(changeset, :requester_uuid)
    recipient_uuid = get_field(changeset, :recipient_uuid)

    if requester_uuid && recipient_uuid && requester_uuid == recipient_uuid do
      add_error(changeset, :recipient_uuid, "cannot connect with yourself")
    else
      changeset
    end
  end

  defp put_requested_at(changeset) do
    if get_field(changeset, :requested_at) do
      changeset
    else
      put_change(
        changeset,
        :requested_at,
        DateTime.utc_now()
      )
    end
  end

  defp put_responded_at(changeset) do
    status = get_change(changeset, :status)

    if status in ["accepted", "rejected"] && !get_field(changeset, :responded_at) do
      put_change(
        changeset,
        :responded_at,
        DateTime.utc_now()
      )
    else
      changeset
    end
  end

  @doc """
  Returns whether this connection is pending.
  """
  def pending?(%__MODULE__{status: "pending"}), do: true
  def pending?(_), do: false

  @doc """
  Returns whether this connection is accepted.
  """
  def accepted?(%__MODULE__{status: "accepted"}), do: true
  def accepted?(_), do: false

  @doc """
  Returns whether this connection is rejected.
  """
  def rejected?(%__MODULE__{status: "rejected"}), do: true
  def rejected?(_), do: false
end
