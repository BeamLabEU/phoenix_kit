defmodule PhoenixKit.Modules.Publishing.PublishingContent do
  @moduledoc """
  Schema for publishing content — one row per language per version.

  This mirrors the filesystem's one-`.phk`-file-per-language model. Each content
  row has its own title, content body, status, and optional URL slug.

  ## Data JSONB Keys

  - `description` - SEO meta description
  - `previous_url_slugs` - List of previous URL slugs for 301 redirects
  - `featured_image_id` - Per-language featured image override
  - `seo_title` - Custom SEO title (if different from title)
  - `excerpt` - Custom excerpt (if different from auto-generated)
  - `custom_css` - Per-language custom CSS
  - `updated_by_uuid` - UUID of last editor for this language
  - `updated_by_id` - Integer ID of last editor (dual-write)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          version_uuid: UUIDv7.t(),
          language: String.t(),
          title: String.t(),
          content: String.t() | nil,
          status: String.t(),
          url_slug: String.t() | nil,
          data: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_publishing_contents" do
    field :language, :string
    field :title, :string
    field :content, :string
    field :status, :string, default: "draft"
    field :url_slug, :string
    field :data, :map, default: %{}

    belongs_to :version, PhoenixKit.Modules.Publishing.PublishingVersion,
      foreign_key: :version_uuid,
      references: :uuid,
      type: UUIDv7

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating publishing content.
  """
  def changeset(content, attrs) do
    content
    |> cast(attrs, [:version_uuid, :language, :title, :content, :status, :url_slug, :data],
      empty_values: []
    )
    |> validate_required([:version_uuid, :language, :status])
    |> default_if_nil(:title, "")
    |> default_if_nil(:content, "")
    |> normalize_empty_to_nil(:url_slug)
    |> validate_inclusion(:status, ["draft", "published", "archived"])
    |> validate_length(:language, max: 10)
    |> validate_length(:title, max: 500)
    |> validate_length(:url_slug, max: 500)
    |> unique_constraint([:version_uuid, :language],
      name: :idx_publishing_contents_version_language
    )
    |> foreign_key_constraint(:version_uuid, name: :fk_publishing_contents_version)
  end

  defp default_if_nil(changeset, field, default) do
    if get_field(changeset, field) == nil do
      put_change(changeset, field, default)
    else
      changeset
    end
  end

  defp normalize_empty_to_nil(changeset, field) do
    if get_field(changeset, field) == "" do
      put_change(changeset, field, nil)
    else
      changeset
    end
  end

  # Data JSONB accessors

  @doc "Returns the SEO description."
  def get_description(%__MODULE__{data: data}), do: Map.get(data, "description")

  @doc "Returns previous URL slugs for 301 redirects."
  def get_previous_url_slugs(%__MODULE__{data: data}),
    do: Map.get(data, "previous_url_slugs", [])

  @doc "Returns the per-language featured image ID."
  def get_featured_image_id(%__MODULE__{data: data}), do: Map.get(data, "featured_image_id")

  @doc "Returns the custom SEO title."
  def get_seo_title(%__MODULE__{data: data}), do: Map.get(data, "seo_title")

  @doc "Returns the custom excerpt."
  def get_excerpt(%__MODULE__{data: data}), do: Map.get(data, "excerpt")

  @doc "Returns the UUID of the last editor for this language."
  def get_updated_by_uuid(%__MODULE__{data: data}), do: Map.get(data, "updated_by_uuid")
end
