defmodule PhoenixKit.Modules.Posts.PostLike do
  @moduledoc """
  Schema for post likes.

  Tracks which users have liked which posts. Enforces one like per user per post.

  ## Fields

  - `post_id` - Reference to the post
  - `user_id` - Reference to the user who liked

  ## Examples

      # User likes a post
      %PostLike{
        post_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        user_id: 42
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          post_uuid: UUIDv7.t(),
          user_uuid: UUIDv7.t() | nil,
          post: PhoenixKit.Modules.Posts.Post.t() | Ecto.Association.NotLoaded.t(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_post_likes" do
    belongs_to :post, PhoenixKit.Modules.Posts.Post,
      foreign_key: :post_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a post like.

  ## Required Fields

  - `post_id` - Reference to post
  - `user_id` - Reference to user

  ## Validation Rules

  - Unique constraint on (post_id, user_id) - one like per user per post
  """
  def changeset(like, attrs) do
    like
    |> cast(attrs, [:post_uuid, :user_uuid])
    |> validate_required([:post_uuid, :user_uuid])
    |> foreign_key_constraint(:post_uuid)
    |> foreign_key_constraint(:user_uuid)
    |> unique_constraint([:post_uuid, :user_id],
      name: :phoenix_kit_post_likes_post_id_user_id_index,
      message: "you have already liked this post"
    )
  end
end
