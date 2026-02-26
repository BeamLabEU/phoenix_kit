defmodule PhoenixKit.Modules.Connections.Block do
  @moduledoc """
  Schema for user blocking relationships.

  Represents a one-way block where one user blocks another.
  Blocking prevents all interaction between users.

  ## Fields

  - `blocker_uuid` - UUID of the user who initiated the block
  - `blocked_uuid` - UUID of the user who is blocked
  - `reason` - Optional reason for the block (visible to admins)
  - `inserted_at` - When the block was created

  ## Examples

      # User A blocks User B
      %Block{
        uuid: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        blocker_uuid: "019abc12-3456-7890-abcd-ef1234567890",
        blocked_uuid: "019abc12-9876-5432-abcd-ef1234567890",
        reason: "Spam",
        inserted_at: ~N[2025-01-15 10:30:00]
      }

  ## Business Rules

  - Cannot block yourself
  - Blocking removes any existing follows between the users
  - Blocking removes any existing connections between the users
  - Blocked users cannot follow, connect, or view the blocker's profile
  - Blocking is one-way (A blocks B doesn't mean B blocks A)
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Utils.Date, as: UtilsDate

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          blocker_uuid: UUIDv7.t(),
          blocked_uuid: UUIDv7.t(),
          reason: String.t() | nil,
          blocker: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          blocked: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil
        }

  schema "phoenix_kit_user_blocks" do
    belongs_to :blocker, PhoenixKit.Users.Auth.User,
      foreign_key: :blocker_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :blocked, PhoenixKit.Users.Auth.User,
      foreign_key: :blocked_uuid,
      references: :uuid,
      type: UUIDv7

    field :reason, :string
    field :inserted_at, :utc_datetime
  end

  @doc """
  Changeset for creating a block.

  ## Required Fields

  - `blocker_uuid` - UUID of the user who is blocking
  - `blocked_uuid` - UUID of the user being blocked

  ## Optional Fields

  - `reason` - Why the user was blocked
  - `blocker_id` - Integer ID (deprecated, dual-write)
  - `blocked_id` - Integer ID (deprecated, dual-write)

  ## Validation Rules

  - Both user UUIDs are required
  - Cannot block yourself
  - Unique constraint on (blocker_uuid, blocked_uuid) pair
  """
  def changeset(block, attrs) do
    block
    |> cast(attrs, [:blocker_uuid, :blocked_uuid, :reason])
    |> validate_required([:blocker_uuid, :blocked_uuid])
    |> validate_length(:reason, max: 500)
    |> validate_not_self_block()
    |> put_inserted_at()
    |> foreign_key_constraint(:blocker_uuid)
    |> foreign_key_constraint(:blocked_uuid)
    |> unique_constraint([:blocker_uuid, :blocked_uuid],
      name: :phoenix_kit_user_blocks_unique_idx,
      message: "user is already blocked"
    )
  end

  defp validate_not_self_block(changeset) do
    blocker_uuid = get_field(changeset, :blocker_uuid)
    blocked_uuid = get_field(changeset, :blocked_uuid)

    if blocker_uuid && blocked_uuid && blocker_uuid == blocked_uuid do
      add_error(changeset, :blocked_uuid, "cannot block yourself")
    else
      changeset
    end
  end

  defp put_inserted_at(changeset) do
    if get_field(changeset, :inserted_at) do
      changeset
    else
      put_change(
        changeset,
        :inserted_at,
        UtilsDate.utc_now()
      )
    end
  end
end
