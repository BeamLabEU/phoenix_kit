defmodule PhoenixKit.Modules.Shop.Category do
  @moduledoc """
  Category schema for product organization.

  Supports hierarchical nesting via parent_id.

  ## Fields

  - `name` - Category name (required)
  - `slug` - URL-friendly identifier (unique)
  - `description` - Category description
  - `image_url` - Category image
  - `parent_id` - Parent category for nesting
  - `position` - Sort order
  - `status` - Category status: "active", "hidden", "archived"
  - `metadata` - JSONB for custom fields
  - `option_schema` - Category-specific product option definitions (JSONB array)

  ## Status Values

  - `active` - Category and products visible in storefront
  - `unlisted` - Category hidden from menu, but products still visible
  - `hidden` - Category and all products hidden from storefront
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Modules.Storage.URLSigner

  @type t :: %__MODULE__{}

  @statuses ~w(active unlisted hidden)

  schema "phoenix_kit_shop_categories" do
    field :uuid, Ecto.UUID

    # Localized fields (JSONB maps: %{"en" => "value", "ru" => "значение"})
    field :name, :map, default: %{}
    field :slug, :map, default: %{}
    field :description, :map, default: %{}

    # Non-localized fields
    field :image_url, :string
    field :image_id, Ecto.UUID
    field :position, :integer, default: 0
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}
    field :option_schema, {:array, :map}, default: []

    # Self-referential for nesting
    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id

    # Products in this category
    has_many :products, PhoenixKit.Modules.Shop.Product

    timestamps()
  end

  @doc "Returns list of valid category statuses"
  def statuses, do: @statuses

  @localized_fields [:name, :slug, :description]

  @doc """
  Changeset for category creation and updates.
  """
  def changeset(category, attrs) do
    category
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :image_url,
      :image_id,
      :parent_id,
      :position,
      :status,
      :metadata,
      :option_schema
    ])
    |> normalize_map_fields(@localized_fields)
    |> validate_localized_required(:name)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @statuses)
    |> maybe_generate_slug()
    |> validate_not_self_parent()
  end

  @doc """
  Returns the list of localized field names.
  """
  def localized_fields, do: @localized_fields

  @doc """
  Returns the image URL for a category.

  Priority:
  1. Storage media (image_id) if available
  2. External image_url if available
  3. nil if no image

  ## Options
  - `:size` - Storage dimension to use (default: "large")
  """
  def get_image_url(category, opts \\ [])

  def get_image_url(%__MODULE__{image_id: image_id}, opts)
      when is_binary(image_id) and image_id != "" do
    size = Keyword.get(opts, :size, "large")
    URLSigner.signed_url(image_id, size)
  end

  def get_image_url(%__MODULE__{image_url: image_url}, _opts)
      when is_binary(image_url) and image_url != "" do
    image_url
  end

  def get_image_url(_category, _opts), do: nil

  @doc """
  Returns true if category is a root category (no parent).
  """
  def root?(%__MODULE__{parent_id: nil}), do: true
  def root?(_), do: false

  @doc """
  Returns true if category has children.
  """
  def has_children?(%__MODULE__{children: children}) when is_list(children) do
    children != []
  end

  def has_children?(_), do: false

  @doc """
  Returns true if category is active (visible in storefront).
  """
  def active?(%__MODULE__{status: "active"}), do: true
  def active?(_), do: false

  @doc """
  Returns true if category is unlisted (not in menu, but products visible).
  """
  def unlisted?(%__MODULE__{status: "unlisted"}), do: true
  def unlisted?(_), do: false

  @doc """
  Returns true if category is hidden (category and products not visible).
  """
  def hidden?(%__MODULE__{status: "hidden"}), do: true
  def hidden?(_), do: false

  @doc """
  Returns true if products in this category should be visible in storefront.
  Products are visible when category is active or unlisted.
  """
  def products_visible?(%__MODULE__{status: status}) when status in ["active", "unlisted"],
    do: true

  def products_visible?(_), do: false

  @doc """
  Returns true if category should appear in category menu/list.
  Only active categories appear in the menu.
  """
  def show_in_menu?(%__MODULE__{status: "active"}), do: true
  def show_in_menu?(_), do: false

  @doc """
  Returns the full path of category names from root to this category.
  Requires parent to be preloaded.
  """
  def breadcrumb_path(%__MODULE__{parent: nil} = category) do
    [category.name]
  end

  def breadcrumb_path(%__MODULE__{parent: %__MODULE__{} = parent} = category) do
    breadcrumb_path(parent) ++ [category.name]
  end

  def breadcrumb_path(%__MODULE__{} = category) do
    [category.name]
  end

  # Remove empty string values from map fields
  defp normalize_map_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case get_change(acc, field) do
        nil ->
          acc

        map when is_map(map) ->
          cleaned =
            map
            |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
            |> Map.new()

          put_change(acc, field, cleaned)

        _ ->
          acc
      end
    end)
  end

  # Validate that localized field has value for default language
  defp validate_localized_required(changeset, field) do
    value = get_field(changeset, field) || %{}
    default_lang = default_language()

    if Map.get(value, default_lang) in [nil, ""] do
      add_error(changeset, field, "#{default_lang} translation is required")
    else
      changeset
    end
  end

  # Generate slug from name for each language
  defp maybe_generate_slug(changeset) do
    name_map = get_field(changeset, :name) || %{}
    slug_map = get_field(changeset, :slug) || %{}

    # For each language with a name but no slug, generate one
    updated_slugs =
      Enum.reduce(name_map, slug_map, fn {lang, name}, acc ->
        if Map.get(acc, lang) in [nil, ""] and name not in [nil, ""] do
          generated = slugify(name)
          Map.put(acc, lang, generated)
        else
          acc
        end
      end)

    if updated_slugs != slug_map do
      put_change(changeset, :slug, updated_slugs)
    else
      changeset
    end
  end

  # Prevent category from being its own parent
  defp validate_not_self_parent(changeset) do
    parent_id = get_change(changeset, :parent_id)
    category_id = changeset.data.id

    if parent_id && parent_id == category_id do
      add_error(changeset, :parent_id, "cannot be self")
    else
      changeset
    end
  end

  defp slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp slugify(_), do: ""

  defp default_language do
    alias PhoenixKit.Modules.Languages

    if Code.ensure_loaded?(Languages) and function_exported?(Languages, :enabled?, 0) and
         Languages.enabled?() do
      case Languages.get_default_language() do
        %{"code" => code} -> code
        _ -> "en"
      end
    else
      "en"
    end
  end
end
