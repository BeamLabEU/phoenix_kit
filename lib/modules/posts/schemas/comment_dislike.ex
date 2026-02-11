defmodule PhoenixKit.Modules.Posts.CommentDislike do
  @moduledoc """
  Legacy schema for comment dislikes.

  New comment dislikes should use `PhoenixKit.Modules.Comments.CommentDislike` instead.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{
          id: UUIDv7.t() | nil,
          comment_id: UUIDv7.t(),
          user_id: integer(),
          comment: PhoenixKit.Modules.Posts.PostComment.t() | Ecto.Association.NotLoaded.t(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_comment_dislikes" do
    belongs_to :comment, PhoenixKit.Modules.Posts.PostComment, type: UUIDv7
    belongs_to :user, PhoenixKit.Users.Auth.User, type: :integer

    timestamps(type: :naive_datetime)
  end

  @doc """
  Changeset for creating a comment dislike.

  ## Required Fields

  - `comment_id` - Reference to comment
  - `user_id` - Reference to user

  ## Validation Rules

  - Unique constraint on (comment_id, user_id) - one dislike per user per comment
  """
  def changeset(dislike, attrs) do
    dislike
    |> cast(attrs, [:comment_id, :user_id])
    |> validate_required([:comment_id, :user_id])
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:comment_id, :user_id],
      name: :phoenix_kit_comment_dislikes_comment_id_user_id_index,
      message: "you have already disliked this comment"
    )
  end
end
