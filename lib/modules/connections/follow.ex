defmodule PhoenixKit.Modules.Connections.Follow do
  @moduledoc """
  Schema for one-way follow relationships.

  Represents a unidirectional relationship where one user follows another.
  No consent is required from the followed user.

  ## Fields

  - `follower_uuid` - UUID of the user who is doing the following
  - `followed_uuid` - UUID of the user being followed
  - `inserted_at` - When the follow was created

  ## Examples

      # User A follows User B
      %Follow{
        uuid: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        follower_uuid: "019abc12-3456-7890-abcd-ef1234567890",
        followed_uuid: "019abc12-9876-5432-abcd-ef1234567890",
        inserted_at: ~N[2025-01-15 10:30:00]
      }

  ## Business Rules

  - Cannot follow yourself
  - Cannot follow if blocked (either direction)
  - Duplicate follows are prevented by unique constraint
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Utils.Date, as: UtilsDate

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          follower_uuid: UUIDv7.t(),
          followed_uuid: UUIDv7.t(),
          follower: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          followed: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil
        }

  schema "phoenix_kit_user_follows" do
    belongs_to :follower, PhoenixKit.Users.Auth.User,
      foreign_key: :follower_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :followed, PhoenixKit.Users.Auth.User,
      foreign_key: :followed_uuid,
      references: :uuid,
      type: UUIDv7

    field :inserted_at, :utc_datetime
  end

  @doc """
  Changeset for creating a follow relationship.

  ## Required Fields

  - `follower_uuid` - UUID of the user who is following
  - `followed_uuid` - UUID of the user being followed

  ## Validation Rules

  - Both user UUIDs are required
  - Cannot follow yourself (follower_uuid != followed_uuid)
  - Unique constraint on (follower_uuid, followed_uuid) pair
  """
  def changeset(follow, attrs) do
    follow
    |> cast(attrs, [:follower_uuid, :followed_uuid])
    |> validate_required([:follower_uuid, :followed_uuid])
    |> validate_not_self_follow()
    |> put_inserted_at()
    |> foreign_key_constraint(:follower_uuid)
    |> foreign_key_constraint(:followed_uuid)
    |> unique_constraint([:follower_uuid, :followed_uuid],
      name: :phoenix_kit_user_follows_unique_idx,
      message: "already following this user"
    )
  end

  defp validate_not_self_follow(changeset) do
    follower_uuid = get_field(changeset, :follower_uuid)
    followed_uuid = get_field(changeset, :followed_uuid)

    if follower_uuid && followed_uuid && follower_uuid == followed_uuid do
      add_error(changeset, :followed_uuid, "cannot follow yourself")
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
