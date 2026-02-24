defmodule PhoenixKit.Modules.Publishing.PublishingGroup do
  @moduledoc """
  Schema for publishing groups (blog, faq, legal, etc.).

  Each group contains posts and defines the content mode (timestamp or slug).
  Extensible settings are stored in the `data` JSONB column.

  ## Data JSONB Keys

  - `type` - Group type: "blogging", "faq", "legal", or custom string
  - `item_singular` - Display name for single item (e.g., "Post", "Article")
  - `item_plural` - Display name for multiple items (e.g., "Posts", "Articles")
  - `description` - Group description
  - `icon` - Heroicon name for admin UI
  - `settings` - Group-specific settings map
  - `comments_enabled` - Whether comments are enabled for this group
  - `likes_enabled` - Whether likes are enabled for this group
  - `views_enabled` - Whether view tracking is enabled for this group
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t(),
          slug: String.t(),
          mode: String.t(),
          position: integer(),
          data: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_publishing_groups" do
    field :name, :string
    field :slug, :string
    field :mode, :string, default: "timestamp"
    field :position, :integer, default: 0
    field :data, :map, default: %{}

    has_many :posts, PhoenixKit.Modules.Publishing.PublishingPost, foreign_key: :group_uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a publishing group.
  """
  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :slug, :mode, :position, :data])
    |> validate_required([:name, :slug, :mode])
    |> validate_inclusion(:mode, ["timestamp", "slug"])
    |> validate_length(:name, max: 255)
    |> validate_length(:slug, max: 255)
    |> unique_constraint(:slug, name: :idx_publishing_groups_slug)
    |> maybe_generate_slug()
  end

  # Data JSONB accessors

  @doc "Returns the group type from data (blogging/faq/legal/custom)."
  def get_type(%__MODULE__{data: data}), do: Map.get(data, "type", "blogging")

  @doc "Returns the singular item name (e.g., 'Post')."
  def get_item_singular(%__MODULE__{data: data}), do: Map.get(data, "item_singular", "Post")

  @doc "Returns the plural item name (e.g., 'Posts')."
  def get_item_plural(%__MODULE__{data: data}), do: Map.get(data, "item_plural", "Posts")

  @doc "Returns the group description."
  def get_description(%__MODULE__{data: data}), do: Map.get(data, "description")

  @doc "Returns the group icon name."
  def get_icon(%__MODULE__{data: data}), do: Map.get(data, "icon")

  @doc "Returns whether comments are enabled for this group."
  def comments_enabled?(%__MODULE__{data: data}), do: Map.get(data, "comments_enabled", false)

  @doc "Returns whether likes are enabled for this group."
  def likes_enabled?(%__MODULE__{data: data}), do: Map.get(data, "likes_enabled", false)

  @doc "Returns whether view tracking is enabled for this group."
  def views_enabled?(%__MODULE__{data: data}), do: Map.get(data, "views_enabled", false)

  defp maybe_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        name = get_field(changeset, :name)

        if name do
          slug =
            name
            |> String.downcase()
            |> String.replace(~r/[^\w\s-]/, "")
            |> String.replace(~r/\s+/, "-")
            |> String.trim("-")

          put_change(changeset, :slug, slug)
        else
          changeset
        end

      _slug ->
        changeset
    end
  end
end
