defmodule PhoenixKit.Modules.Publishing.PublishingPost do
  @moduledoc """
  Schema for publishing posts within a group.

  Each post belongs to a group and has versions with per-language content.
  Supports both slug-mode and timestamp-mode URL structures.

  ## Status Flow

  - `draft` - Not visible to public
  - `published` - Live and visible
  - `archived` - Hidden but preserved
  - `scheduled` - Auto-publish at `scheduled_at`

  ## Data JSONB Keys

  - `allow_version_access` - Whether older versions are publicly accessible
  - `featured_image` - Featured image reference (file UUID or URL)
  - `tags` - List of tag strings
  - `seo` - SEO metadata map (og_title, og_description, og_image, etc.)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          group_uuid: UUIDv7.t(),
          slug: String.t(),
          status: String.t(),
          mode: String.t(),
          primary_language: String.t(),
          published_at: DateTime.t() | nil,
          scheduled_at: DateTime.t() | nil,
          post_date: Date.t() | nil,
          post_time: Time.t() | nil,
          created_by_uuid: UUIDv7.t() | nil,
          created_by_id: integer() | nil,
          updated_by_uuid: UUIDv7.t() | nil,
          updated_by_id: integer() | nil,
          data: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_publishing_posts" do
    field :slug, :string
    field :status, :string, default: "draft"
    field :mode, :string, default: "timestamp"
    field :primary_language, :string, default: "en"
    field :published_at, :utc_datetime
    field :scheduled_at, :utc_datetime
    field :post_date, :date
    field :post_time, :time
    field :data, :map, default: %{}

    belongs_to :group, PhoenixKit.Modules.Publishing.PublishingGroup,
      foreign_key: :group_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :created_by, PhoenixKit.Users.Auth.User,
      foreign_key: :created_by_uuid,
      references: :uuid,
      type: UUIDv7

    field :created_by_id, :integer

    belongs_to :updated_by, PhoenixKit.Users.Auth.User,
      foreign_key: :updated_by_uuid,
      references: :uuid,
      type: UUIDv7

    field :updated_by_id, :integer

    has_many :versions, PhoenixKit.Modules.Publishing.PublishingVersion, foreign_key: :post_uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a publishing post.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [
      :group_uuid,
      :slug,
      :status,
      :mode,
      :primary_language,
      :published_at,
      :scheduled_at,
      :post_date,
      :post_time,
      :created_by_uuid,
      :created_by_id,
      :updated_by_uuid,
      :updated_by_id,
      :data
    ])
    |> validate_required([:group_uuid, :slug, :status, :mode, :primary_language])
    |> validate_inclusion(:status, ["draft", "published", "archived", "scheduled"])
    |> validate_inclusion(:mode, ["timestamp", "slug"])
    |> validate_length(:slug, max: 500)
    |> validate_length(:primary_language, max: 10)
    |> validate_scheduled_at()
    |> unique_constraint([:group_uuid, :slug], name: :idx_publishing_posts_group_slug)
    |> foreign_key_constraint(:group_uuid, name: :fk_publishing_posts_group)
    |> foreign_key_constraint(:created_by_uuid, name: :fk_publishing_posts_created_by)
    |> foreign_key_constraint(:updated_by_uuid, name: :fk_publishing_posts_updated_by)
  end

  @doc "Check if post is published."
  def published?(%__MODULE__{status: "published"}), do: true
  def published?(_), do: false

  @doc "Check if post is scheduled for future publishing."
  def scheduled?(%__MODULE__{status: "scheduled"}), do: true
  def scheduled?(_), do: false

  @doc "Check if post is a draft."
  def draft?(%__MODULE__{status: "draft"}), do: true
  def draft?(_), do: false

  # Data JSONB accessors

  @doc "Returns whether older versions are publicly accessible."
  def allow_version_access?(%__MODULE__{data: data}),
    do: Map.get(data, "allow_version_access", false)

  @doc "Returns the featured image reference."
  def get_featured_image(%__MODULE__{data: data}), do: Map.get(data, "featured_image")

  @doc "Returns the post tags."
  def get_tags(%__MODULE__{data: data}), do: Map.get(data, "tags", [])

  @doc "Returns SEO metadata."
  def get_seo(%__MODULE__{data: data}), do: Map.get(data, "seo", %{})

  defp validate_scheduled_at(changeset) do
    status = get_field(changeset, :status)
    scheduled_at = get_field(changeset, :scheduled_at)
    status_changed? = get_change(changeset, :status) != nil
    scheduled_at_changed? = get_change(changeset, :scheduled_at) != nil

    case {status, scheduled_at} do
      {"scheduled", nil} ->
        add_error(changeset, :scheduled_at, "must be set when status is scheduled")

      {"scheduled", datetime} when not is_nil(datetime) ->
        if (scheduled_at_changed? or status_changed?) and
             DateTime.compare(datetime, DateTime.utc_now()) == :lt do
          add_error(changeset, :scheduled_at, "must be in the future")
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
