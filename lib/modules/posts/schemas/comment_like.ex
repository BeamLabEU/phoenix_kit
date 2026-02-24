defmodule PhoenixKit.Modules.Posts.CommentLike do
  @moduledoc """
  Legacy schema for comment likes.

  New comment likes should use `PhoenixKit.Modules.Comments.CommentLike` instead.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          comment_uuid: UUIDv7.t(),
          user_id: integer() | nil,
          user_uuid: UUIDv7.t() | nil,
          comment: PhoenixKit.Modules.Posts.PostComment.t() | Ecto.Association.NotLoaded.t(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_comment_likes" do
    belongs_to :comment, PhoenixKit.Modules.Posts.PostComment,
      foreign_key: :comment_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    field :user_id, :integer

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a comment like.

  ## Required Fields

  - `comment_id` - Reference to comment
  - `user_id` - Reference to user

  ## Validation Rules

  - Unique constraint on (comment_id, user_id) - one like per user per comment
  """
  def changeset(like, attrs) do
    like
    |> cast(attrs, [:comment_uuid, :user_id, :user_uuid])
    |> validate_required([:comment_uuid, :user_uuid])
    |> foreign_key_constraint(:comment_uuid)
    |> foreign_key_constraint(:user_uuid)
    |> unique_constraint([:comment_uuid, :user_id],
      name: :phoenix_kit_comment_likes_comment_uuid_user_id_index,
      message: "you have already liked this comment"
    )
  end
end
