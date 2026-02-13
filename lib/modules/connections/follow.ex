defmodule PhoenixKit.Modules.Connections.Follow do
  @moduledoc """
  Schema for one-way follow relationships.

  Represents a unidirectional relationship where one user follows another.
  No consent is required from the followed user.

  ## Fields

  - `follower_id` - User who is doing the following
  - `followed_id` - User being followed
  - `inserted_at` - When the follow was created

  ## Examples

      # User A follows User B
      %Follow{
        id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        follower_id: 1,
        followed_id: 2,
        inserted_at: ~N[2025-01-15 10:30:00]
      }

  ## Business Rules

  - Cannot follow yourself
  - Cannot follow if blocked (either direction)
  - Duplicate follows are prevented by unique constraint
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{
          id: UUIDv7.t() | nil,
          follower_id: integer(),
          followed_id: integer(),
          follower: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          followed: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_user_follows" do
    belongs_to :follower, PhoenixKit.Users.Auth.User, type: :integer
    belongs_to :followed, PhoenixKit.Users.Auth.User, type: :integer
    field :follower_uuid, UUIDv7
    field :followed_uuid, UUIDv7

    field :inserted_at, :naive_datetime
  end

  @doc """
  Changeset for creating a follow relationship.

  ## Required Fields

  - `follower_id` - The user who is following
  - `followed_id` - The user being followed

  ## Validation Rules

  - Both user IDs are required
  - Cannot follow yourself (follower_id != followed_id)
  - Unique constraint on (follower_id, followed_id) pair
  """
  def changeset(follow, attrs) do
    follow
    |> cast(attrs, [:follower_id, :followed_id, :follower_uuid, :followed_uuid])
    |> validate_required([:follower_id, :followed_id])
    |> validate_not_self_follow()
    |> put_inserted_at()
    |> foreign_key_constraint(:follower_id)
    |> foreign_key_constraint(:followed_id)
    |> unique_constraint([:follower_id, :followed_id],
      name: :phoenix_kit_user_follows_unique_idx,
      message: "already following this user"
    )
  end

  defp validate_not_self_follow(changeset) do
    follower_id = get_field(changeset, :follower_id)
    followed_id = get_field(changeset, :followed_id)

    if follower_id && followed_id && follower_id == followed_id do
      add_error(changeset, :followed_id, "cannot follow yourself")
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
