defmodule PhoenixKit.Modules.Comments.CommentLike do
  @moduledoc """
  Schema for comment likes in the standalone Comments module.

  Tracks which users have liked which comments. Enforces one like per user per comment.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{
          id: UUIDv7.t() | nil,
          comment_id: UUIDv7.t(),
          user_id: integer(),
          comment: PhoenixKit.Modules.Comments.Comment.t() | Ecto.Association.NotLoaded.t(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_comments_likes" do
    belongs_to :comment, PhoenixKit.Modules.Comments.Comment, type: UUIDv7
    belongs_to :user, PhoenixKit.Users.Auth.User, type: :integer

    timestamps(type: :naive_datetime)
  end

  @doc """
  Changeset for creating a comment like.

  Unique constraint on (comment_id, user_id) — one like per user per comment.
  """
  def changeset(like, attrs) do
    like
    |> cast(attrs, [:comment_id, :user_id])
    |> validate_required([:comment_id, :user_id])
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:comment_id, :user_id],
      name: :uq_comments_likes_comment_user,
      message: "you have already liked this comment"
    )
  end
end
