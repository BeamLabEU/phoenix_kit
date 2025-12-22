defmodule PhoenixKit.Modules.Connections.Block do
  @moduledoc """
  Schema for user blocking relationships.

  Represents a one-way block where one user blocks another.
  Blocking prevents all interaction between users.

  ## Fields

  - `blocker_id` - User who initiated the block
  - `blocked_id` - User who is blocked
  - `reason` - Optional reason for the block (visible to admins)
  - `inserted_at` - When the block was created

  ## Examples

      # User A blocks User B
      %Block{
        id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        blocker_id: 1,
        blocked_id: 2,
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

  @primary_key {:id, UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{
          id: UUIDv7.t() | nil,
          blocker_id: integer(),
          blocked_id: integer(),
          reason: String.t() | nil,
          blocker: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          blocked: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_user_blocks" do
    belongs_to :blocker, PhoenixKit.Users.Auth.User, type: :integer
    belongs_to :blocked, PhoenixKit.Users.Auth.User, type: :integer

    field :reason, :string
    field :inserted_at, :naive_datetime
  end

  @doc """
  Changeset for creating a block.

  ## Required Fields

  - `blocker_id` - The user who is blocking
  - `blocked_id` - The user being blocked

  ## Optional Fields

  - `reason` - Why the user was blocked

  ## Validation Rules

  - Both user IDs are required
  - Cannot block yourself
  - Unique constraint on (blocker_id, blocked_id) pair
  """
  def changeset(block, attrs) do
    block
    |> cast(attrs, [:blocker_id, :blocked_id, :reason])
    |> validate_required([:blocker_id, :blocked_id])
    |> validate_length(:reason, max: 500)
    |> validate_not_self_block()
    |> put_inserted_at()
    |> foreign_key_constraint(:blocker_id)
    |> foreign_key_constraint(:blocked_id)
    |> unique_constraint([:blocker_id, :blocked_id],
      name: :phoenix_kit_user_blocks_unique_idx,
      message: "user is already blocked"
    )
  end

  defp validate_not_self_block(changeset) do
    blocker_id = get_field(changeset, :blocker_id)
    blocked_id = get_field(changeset, :blocked_id)

    if blocker_id && blocked_id && blocker_id == blocked_id do
      add_error(changeset, :blocked_id, "cannot block yourself")
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
        NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      )
    end
  end
end
