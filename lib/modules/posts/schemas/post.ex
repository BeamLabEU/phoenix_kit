defmodule PhoenixKit.Modules.Posts.Post do
  @moduledoc """
  Schema for user posts with media attachments.

  Represents a social post with type-specific layouts, privacy controls,
  and scheduled publishing support.

  ## Post Types

  - **post** - Standard full post with full content and media gallery
  - **snippet** - Short form post with truncated display
  - **repost** - Share of external content with source attribution

  ## Status Flow

  - `draft` - Post is being edited (not visible to others)
  - `public` - Post is published and visible to all
  - `unlisted` - Post is accessible via direct link but not in feeds
  - `scheduled` - Post will be auto-published at scheduled_at time

  ## Fields

  - `user_id` - Owner of the post
  - `title` - Post title (max length via settings)
  - `sub_title` - Subtitle/tagline (max length via settings)
  - `content` - Post content (max length via settings)
  - `type` - post/snippet/repost (affects display layout)
  - `status` - draft/public/unlisted/scheduled
  - `scheduled_at` - When to auto-publish (nullable)
  - `published_at` - When made public (nullable)
  - `repost_url` - Source URL for reposts (nullable)
  - `slug` - SEO-friendly URL slug
  - `like_count` - Denormalized counter (updated via context)
  - `comment_count` - Denormalized counter (updated via context)
  - `view_count` - Page views counter (updated via context)
  - `metadata` - Type-specific flexible data (JSONB)

  ## Examples

      # Standard post
      %Post{
        id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        user_id: 1,
        title: "My First Post",
        sub_title: "An introduction to my journey",
        content: "This is the full content...",
        type: "post",
        status: "public",
        slug: "my-first-post",
        like_count: 42,
        comment_count: 15,
        view_count: 523,
        published_at: ~U[2025-01-01 12:00:00Z]
      }

      # Scheduled post
      %Post{
        title: "Future Announcement",
        content: "...",
        type: "post",
        status: "scheduled",
        scheduled_at: ~U[2025-12-31 09:00:00Z],
        published_at: nil
      }

      # Repost
      %Post{
        title: "Great Article",
        content: "Check this out!",
        type: "repost",
        status: "public",
        repost_url: "https://example.com/article",
        metadata: %{"original_author" => "Jane Doe"}
      }
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          user_uuid: UUIDv7.t() | nil,
          title: String.t(),
          sub_title: String.t() | nil,
          content: String.t(),
          type: String.t(),
          status: String.t(),
          scheduled_at: DateTime.t() | nil,
          published_at: DateTime.t() | nil,
          repost_url: String.t() | nil,
          slug: String.t(),
          like_count: integer(),
          dislike_count: integer(),
          comment_count: integer(),
          view_count: integer(),
          metadata: map(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          media: [PhoenixKit.Modules.Posts.PostMedia.t()] | Ecto.Association.NotLoaded.t(),
          likes: [PhoenixKit.Modules.Posts.PostLike.t()] | Ecto.Association.NotLoaded.t(),
          dislikes: [PhoenixKit.Modules.Posts.PostDislike.t()] | Ecto.Association.NotLoaded.t(),
          comments: [PhoenixKit.Modules.Posts.PostComment.t()] | Ecto.Association.NotLoaded.t(),
          mentions: [PhoenixKit.Modules.Posts.PostMention.t()] | Ecto.Association.NotLoaded.t(),
          tags: [PhoenixKit.Modules.Posts.PostTag.t()] | Ecto.Association.NotLoaded.t(),
          groups: [PhoenixKit.Modules.Posts.PostGroup.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_posts" do
    field :title, :string
    field :sub_title, :string
    field :content, :string
    field :type, :string, default: "post"
    field :status, :string, default: "draft"
    field :scheduled_at, :utc_datetime
    field :published_at, :utc_datetime
    field :repost_url, :string
    field :slug, :string
    field :like_count, :integer, default: 0
    field :dislike_count, :integer, default: 0
    field :comment_count, :integer, default: 0
    field :view_count, :integer, default: 0
    field :metadata, :map, default: %{}

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    has_many :media, PhoenixKit.Modules.Posts.PostMedia, foreign_key: :post_uuid
    has_many :likes, PhoenixKit.Modules.Posts.PostLike, foreign_key: :post_uuid
    has_many :dislikes, PhoenixKit.Modules.Posts.PostDislike, foreign_key: :post_uuid
    has_many :comments, PhoenixKit.Modules.Posts.PostComment, foreign_key: :post_uuid
    has_many :mentions, PhoenixKit.Modules.Posts.PostMention, foreign_key: :post_uuid

    many_to_many :tags, PhoenixKit.Modules.Posts.PostTag,
      join_through: PhoenixKit.Modules.Posts.PostTagAssignment,
      join_keys: [post_uuid: :uuid, tag_uuid: :uuid]

    many_to_many :groups, PhoenixKit.Modules.Posts.PostGroup,
      join_through: PhoenixKit.Modules.Posts.PostGroupAssignment,
      join_keys: [post_uuid: :uuid, group_uuid: :uuid]

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a post.

  ## Required Fields

  - `user_id` - Owner of the post
  - `title` - Post title
  - `content` - Post content
  - `type` - Must be: "post", "snippet", or "repost"
  - `status` - Must be: "draft", "public", "unlisted", or "scheduled"

  ## Validation Rules

  - Title and content lengths validated against settings
  - Type must be valid (post/snippet/repost)
  - Status must be valid (draft/public/unlisted/scheduled)
  - Slug auto-generated from title if not provided
  - Scheduled posts must have scheduled_at
  - Reposts should have repost_url
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [
      :user_uuid,
      :title,
      :sub_title,
      :content,
      :type,
      :status,
      :scheduled_at,
      :published_at,
      :repost_url,
      :slug,
      :metadata
    ])
    |> validate_required([:user_uuid, :title, :type, :status])
    |> validate_inclusion(:type, ["post", "snippet", "repost"])
    |> validate_inclusion(:status, ["draft", "public", "unlisted", "scheduled"])
    |> validate_length(:title, max: 255)
    |> validate_length(:sub_title, max: 500)
    |> validate_scheduled_at()
    |> maybe_generate_slug()
    |> foreign_key_constraint(:user_uuid)
  end

  @doc """
  Check if post is published (public or unlisted).
  """
  def published?(%__MODULE__{status: status}) when status in ["public", "unlisted"], do: true
  def published?(_), do: false

  @doc """
  Check if post is scheduled for future publishing.
  """
  def scheduled?(%__MODULE__{status: "scheduled"}), do: true
  def scheduled?(_), do: false

  @doc """
  Check if post can receive comments (public or unlisted).
  """
  def can_comment?(%__MODULE__{status: status}) when status in ["public", "unlisted"], do: true
  def can_comment?(_), do: false

  @doc """
  Check if post is a draft.
  """
  def draft?(%__MODULE__{status: "draft"}), do: true
  def draft?(_), do: false

  @doc """
  Check if post is a repost type.
  """
  def repost?(%__MODULE__{type: "repost"}), do: true
  def repost?(_), do: false

  # Private Functions

  defp validate_scheduled_at(changeset) do
    status = get_field(changeset, :status)
    scheduled_at = get_field(changeset, :scheduled_at)
    status_changed? = get_change(changeset, :status) != nil
    scheduled_at_changed? = get_change(changeset, :scheduled_at) != nil

    case {status, scheduled_at} do
      {"scheduled", nil} ->
        add_error(changeset, :scheduled_at, "must be set when status is scheduled")

      {"scheduled", datetime} when not is_nil(datetime) ->
        # Only validate scheduled_at is in the future if:
        # 1. scheduled_at is being changed, OR
        # 2. status is being changed TO "scheduled"
        # This allows editing other fields without re-validating an existing schedule
        if (scheduled_at_changed? or status_changed?) and
             DateTime.compare(datetime, UtilsDate.utc_now()) == :lt do
          add_error(changeset, :scheduled_at, "must be in the future")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp maybe_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        title = get_field(changeset, :title)

        if title do
          slug = slugify(title)
          put_change(changeset, :slug, slug)
        else
          changeset
        end

      _slug ->
        changeset
    end
  end

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
  end
end
