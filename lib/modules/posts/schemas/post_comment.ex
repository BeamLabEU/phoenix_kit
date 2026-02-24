defmodule PhoenixKit.Modules.Posts.PostComment do
  @moduledoc """
  Legacy schema for post comments.

  Retained for backward compatibility with the `phoenix_kit_post_comments` table.
  New comments should use `PhoenixKit.Modules.Comments.Comment` instead.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          post_uuid: UUIDv7.t(),
          user_id: integer() | nil,
          user_uuid: UUIDv7.t() | nil,
          parent_uuid: UUIDv7.t() | nil,
          content: String.t(),
          status: String.t(),
          depth: integer(),
          like_count: integer(),
          dislike_count: integer(),
          post: PhoenixKit.Modules.Posts.Post.t() | Ecto.Association.NotLoaded.t(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          parent: t() | Ecto.Association.NotLoaded.t() | nil,
          children: [t()] | Ecto.Association.NotLoaded.t(),
          likes: [PhoenixKit.Modules.Posts.CommentLike.t()] | Ecto.Association.NotLoaded.t(),
          dislikes:
            [PhoenixKit.Modules.Posts.CommentDislike.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_post_comments" do
    field :content, :string
    field :status, :string, default: "published"
    field :depth, :integer, default: 0
    field :like_count, :integer, default: 0
    field :dislike_count, :integer, default: 0

    belongs_to :post, PhoenixKit.Modules.Posts.Post,
      foreign_key: :post_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    field :user_id, :integer

    belongs_to :parent, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid,
      type: UUIDv7

    has_many :children, __MODULE__, foreign_key: :parent_uuid
    has_many :likes, PhoenixKit.Modules.Posts.CommentLike, foreign_key: :comment_uuid
    has_many :dislikes, PhoenixKit.Modules.Posts.CommentDislike, foreign_key: :comment_uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a comment.

  ## Required Fields

  - `post_id` - Reference to post
  - `user_id` - Reference to commenter
  - `content` - Comment text

  ## Validation Rules

  - Content must not be empty
  - Status must be valid (published/hidden/deleted/pending)
  - Depth automatically calculated from parent
  """
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:post_uuid, :user_id, :user_uuid, :parent_uuid, :content, :status, :depth])
    |> validate_required([:post_uuid, :user_uuid, :content])
    |> validate_inclusion(:status, ["published", "hidden", "deleted", "pending"])
    |> validate_length(:content, min: 1, max: 10_000)
    |> foreign_key_constraint(:post_uuid)
    |> foreign_key_constraint(:user_uuid)
    |> foreign_key_constraint(:parent_uuid)
  end

  @doc """
  Check if comment is a reply (has parent).
  """
  def reply?(%__MODULE__{parent_uuid: nil}), do: false
  def reply?(%__MODULE__{}), do: true

  @doc """
  Check if comment is top-level (no parent).
  """
  def top_level?(%__MODULE__{parent_uuid: nil}), do: true
  def top_level?(%__MODULE__{}), do: false

  @doc """
  Check if comment is published.
  """
  def published?(%__MODULE__{status: "published"}), do: true
  def published?(_), do: false

  @doc """
  Check if comment is deleted.
  """
  def deleted?(%__MODULE__{status: "deleted"}), do: true
  def deleted?(_), do: false
end
