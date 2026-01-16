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

  - `requester_id` - User who initiated the connection request
  - `recipient_id` - User who received the request
  - `status` - Current status of the connection
  - `requested_at` - When the request was sent
  - `responded_at` - When the recipient responded (nil if pending)

  ## Examples

      # Pending connection request
      %Connection{
        id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        requester_id: 1,
        recipient_id: 2,
        status: "pending",
        requested_at: ~N[2025-01-15 10:30:00],
        responded_at: nil
      }

      # Accepted connection
      %Connection{
        id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        requester_id: 1,
        recipient_id: 2,
        status: "accepted",
        requested_at: ~N[2025-01-15 10:30:00],
        responded_at: ~N[2025-01-15 11:00:00]
      }

  ## Business Rules

  - Cannot connect with yourself
  - Cannot connect if blocked (either direction)
  - If A requests B while B has pending request to A → auto-accept both
  - Only one active connection per user pair
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}

  @statuses ["pending", "accepted", "rejected"]

  @type status :: String.t()

  @type t :: %__MODULE__{
          id: UUIDv7.t() | nil,
          requester_id: integer(),
          recipient_id: integer(),
          status: status(),
          requested_at: NaiveDateTime.t(),
          responded_at: NaiveDateTime.t() | nil,
          requester: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          recipient: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_user_connections" do
    belongs_to :requester, PhoenixKit.Users.Auth.User, type: :integer
    belongs_to :recipient, PhoenixKit.Users.Auth.User, type: :integer

    field :status, :string, default: "pending"
    field :requested_at, :naive_datetime
    field :responded_at, :naive_datetime

    timestamps(type: :naive_datetime)
  end

  @doc """
  Returns the list of valid statuses.
  """
  def statuses, do: @statuses

  @doc """
  Changeset for creating a new connection request.

  ## Required Fields

  - `requester_id` - The user sending the request
  - `recipient_id` - The user receiving the request

  ## Validation Rules

  - Both user IDs are required
  - Cannot request connection with yourself
  - Status must be valid
  """
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:requester_id, :recipient_id, :status, :requested_at, :responded_at])
    |> validate_required([:requester_id, :recipient_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_not_self_connection()
    |> put_requested_at()
    |> foreign_key_constraint(:requester_id)
    |> foreign_key_constraint(:recipient_id)
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
    requester_id = get_field(changeset, :requester_id)
    recipient_id = get_field(changeset, :recipient_id)

    if requester_id && recipient_id && requester_id == recipient_id do
      add_error(changeset, :recipient_id, "cannot connect with yourself")
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
        NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      )
    end
  end

  defp put_responded_at(changeset) do
    status = get_change(changeset, :status)

    if status in ["accepted", "rejected"] && !get_field(changeset, :responded_at) do
      put_change(
        changeset,
        :responded_at,
        NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
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
