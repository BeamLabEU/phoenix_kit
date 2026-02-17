defmodule PhoenixKit.Modules.Posts.CommentDislike do
  @moduledoc """
  Legacy schema for comment dislikes.

  New comment dislikes should use `PhoenixKit.Modules.Comments.CommentDislike` instead.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          comment_id: UUIDv7.t(),
          user_id: integer() | nil,
          user_uuid: UUIDv7.t() | nil,
          comment: PhoenixKit.Modules.Posts.PostComment.t() | Ecto.Association.NotLoaded.t(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_comment_dislikes" do
    belongs_to :comment, PhoenixKit.Modules.Posts.PostComment, references: :uuid, type: UUIDv7

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    field :user_id, :integer

    timestamps(type: :utc_datetime)
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
    |> cast(attrs, [:comment_id, :user_id, :user_uuid])
    |> validate_required([:comment_id, :user_uuid])
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:user_uuid)
    |> unique_constraint([:comment_id, :user_id],
      name: :phoenix_kit_comment_dislikes_comment_id_user_id_index,
      message: "you have already disliked this comment"
    )
  end
end
