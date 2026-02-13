defmodule PhoenixKit.Modules.Posts.PostDislike do
  @moduledoc """
  Schema for post dislikes.

  Tracks which users have disliked which posts. Enforces one dislike per user per post.

  ## Fields

  - `post_id` - Reference to the post
  - `user_id` - Reference to the user who disliked

  ## Examples

      # User dislikes a post
      %PostDislike{
        post_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        user_id: 42
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{
          id: UUIDv7.t() | nil,
          post_id: UUIDv7.t(),
          user_id: integer(),
          post: PhoenixKit.Modules.Posts.Post.t() | Ecto.Association.NotLoaded.t(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_post_dislikes" do
    belongs_to :post, PhoenixKit.Modules.Posts.Post, type: UUIDv7
    belongs_to :user, PhoenixKit.Users.Auth.User, type: :integer
    field :user_uuid, UUIDv7

    timestamps(type: :naive_datetime)
  end

  @doc """
  Changeset for creating a post dislike.

  ## Required Fields

  - `post_id` - Reference to post
  - `user_id` - Reference to user

  ## Validation Rules

  - Unique constraint on (post_id, user_id) - one dislike per user per post
  """
  def changeset(dislike, attrs) do
    dislike
    |> cast(attrs, [:post_id, :user_id, :user_uuid])
    |> validate_required([:post_id, :user_id])
    |> foreign_key_constraint(:post_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:post_id, :user_id],
      name: :phoenix_kit_post_dislikes_post_id_user_id_index,
      message: "you have already disliked this post"
    )
  end
end
