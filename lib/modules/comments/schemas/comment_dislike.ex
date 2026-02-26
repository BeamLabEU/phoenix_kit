defmodule PhoenixKit.Modules.Comments.CommentDislike do
  @moduledoc """
  Schema for comment dislikes in the standalone Comments module.

  Tracks which users have disliked which comments. Enforces one dislike per user per comment.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          comment_uuid: UUIDv7.t(),
          user_uuid: UUIDv7.t() | nil,
          comment: PhoenixKit.Modules.Comments.Comment.t() | Ecto.Association.NotLoaded.t(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_comments_dislikes" do
    belongs_to :comment, PhoenixKit.Modules.Comments.Comment,
      foreign_key: :comment_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a comment dislike.

  Unique constraint on (comment_uuid, user_uuid) — one dislike per user per comment.
  """
  def changeset(dislike, attrs) do
    dislike
    |> cast(attrs, [:comment_uuid, :user_uuid])
    |> validate_required([:comment_uuid, :user_uuid])
    |> foreign_key_constraint(:comment_uuid)
    |> foreign_key_constraint(:user_uuid)
    |> unique_constraint([:comment_uuid, :user_uuid],
      name: :uq_comments_dislikes_comment_user,
      message: "you have already disliked this comment"
    )
  end
end
