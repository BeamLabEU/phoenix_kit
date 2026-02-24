defmodule PhoenixKit.Modules.Comments.Comment do
  @moduledoc """
  Schema for polymorphic comments with unlimited threading depth.

  Supports nested comment threads (Reddit-style) with self-referencing parent/child
  relationships. Can be attached to any resource type via `resource_type` + `resource_id`.

  ## Comment Status

  - `published` - Comment is visible
  - `hidden` - Comment is hidden by moderator
  - `deleted` - Comment deleted (soft delete)
  - `pending` - Awaiting moderation approval

  ## Fields

  - `resource_type` - Type of resource (e.g., "post", "entity", "ticket")
  - `resource_id` - UUID of the resource
  - `user_id` - Reference to the commenter
  - `parent_id` - Reference to parent comment (nil for top-level)
  - `content` - Comment text
  - `status` - published/hidden/deleted/pending
  - `depth` - Nesting level (0=top, 1=reply, 2=reply-to-reply, etc.)
  - `like_count` - Denormalized like counter
  - `dislike_count` - Denormalized dislike counter
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          resource_type: String.t(),
          resource_uuid: Ecto.UUID.t(),
          user_id: integer() | nil,
          user_uuid: UUIDv7.t() | nil,
          parent_uuid: UUIDv7.t() | nil,
          content: String.t(),
          status: String.t(),
          depth: integer(),
          like_count: integer(),
          dislike_count: integer(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t() | nil,
          parent: t() | Ecto.Association.NotLoaded.t() | nil,
          children: [t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_comments" do
    field :resource_type, :string
    field :resource_uuid, Ecto.UUID
    field :content, :string
    field :status, :string, default: "published"
    field :depth, :integer, default: 0
    field :like_count, :integer, default: 0
    field :dislike_count, :integer, default: 0

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

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a comment.

  ## Required Fields

  - `resource_type` - Type of resource being commented on
  - `resource_id` - ID of the resource
  - `user_id` - Reference to commenter
  - `content` - Comment text
  """
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [
      :resource_type,
      :resource_uuid,
      :user_id,
      :user_uuid,
      :parent_uuid,
      :content,
      :status,
      :depth
    ])
    |> validate_required([:resource_type, :resource_uuid, :user_uuid, :content])
    |> validate_inclusion(:status, ["published", "hidden", "deleted", "pending"])
    |> validate_length(:content, min: 1, max: 10_000)
    |> validate_length(:resource_type, max: 50)
    |> foreign_key_constraint(:user_uuid)
    |> foreign_key_constraint(:parent_uuid)
  end

  @doc "Check if comment is a reply (has parent)."
  def reply?(%__MODULE__{parent_uuid: nil}), do: false
  def reply?(%__MODULE__{}), do: true

  @doc "Check if comment is top-level (no parent)."
  def top_level?(%__MODULE__{parent_uuid: nil}), do: true
  def top_level?(%__MODULE__{}), do: false

  @doc "Check if comment is published."
  def published?(%__MODULE__{status: "published"}), do: true
  def published?(_), do: false

  @doc "Check if comment is deleted."
  def deleted?(%__MODULE__{status: "deleted"}), do: true
  def deleted?(_), do: false
end
