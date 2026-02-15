defmodule PhoenixKit.Modules.Shop.Category do
  @moduledoc """
  Category schema for product organization.

  Supports hierarchical nesting via parent_id.

  ## Fields

  - `name` - Category name (required)
  - `slug` - URL-friendly identifier (unique)
  - `description` - Category description
  - `featured_product_id` - Featured product for fallback image
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

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_shop_categories" do
    field :id, :integer, read_after_writes: true

    # Localized fields (JSONB maps: %{"en" => "value", "ru" => "значение"})
    field :name, :map, default: %{}
    field :slug, :map, default: %{}
    field :description, :map, default: %{}

    # Non-localized fields
    field :image_id, Ecto.UUID
    field :position, :integer, default: 0
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}
    field :option_schema, {:array, :map}, default: []

    # Self-referential for nesting
    # legacy
    field :parent_id, :integer
    belongs_to :parent, __MODULE__, foreign_key: :parent_uuid, references: :uuid, type: UUIDv7
    has_many :children, __MODULE__, foreign_key: :parent_uuid, references: :uuid

    # Products in this category
    has_many :products, PhoenixKit.Modules.Shop.Product,
      foreign_key: :category_uuid,
      references: :uuid

    # Featured product for fallback image
    # legacy
    field :featured_product_id, :integer

    belongs_to :featured_product, PhoenixKit.Modules.Shop.Product,
      foreign_key: :featured_product_uuid,
      references: :uuid,
      type: UUIDv7

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
      :image_id,
      :featured_product_id,
      :featured_product_uuid,
      :parent_id,
      :parent_uuid,
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
    |> validate_no_circular_parent()
    |> unique_constraint(:slug, name: "idx_shop_categories_slug_primary")
  end

  @doc """
  Returns the list of localized field names.
  """
  def localized_fields, do: @localized_fields

  @doc """
  Returns the image URL for a category.

  Priority:
  1. Storage media (image_id) if available
  2. Featured product's featured_image_id (requires :featured_product preloaded)
  3. Featured product's legacy featured_image URL (requires :featured_product preloaded)
  4. nil if no image

  ## Options
  - `:size` - Storage dimension to use (default: "large")
  """
  def get_image_url(category, opts \\ [])

  # Priority 1: direct Storage image
  def get_image_url(%__MODULE__{image_id: image_id}, opts)
      when is_binary(image_id) and image_id != "" do
    size = Keyword.get(opts, :size, "large")
    URLSigner.signed_url(image_id, size)
  end

  # Priority 2: featured product's Storage image (preloaded)
  def get_image_url(
        %__MODULE__{featured_product: %{featured_image_id: fid}},
        opts
      )
      when is_binary(fid) and fid != "" do
    size = Keyword.get(opts, :size, "large")
    URLSigner.signed_url(fid, size)
  end

  # Priority 3: featured product's legacy image URL (preloaded)
  def get_image_url(
        %__MODULE__{featured_product: %{featured_image: url}},
        _opts
      )
      when is_binary(url) and url != "" do
    url
  end

  # No image available
  def get_image_url(_category, _opts), do: nil

  @doc """
  Returns true if category is a root category (no parent).
  """
  def root?(%__MODULE__{parent_uuid: nil}), do: true
  def root?(%__MODULE__{}), do: false

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

  ## Parameters

    - `category` - Category struct with parent preloaded
    - `language` - Language code for localized names (default: system default)

  ## Examples

      iex> breadcrumb_path(category, "en")
      ["Home", "Electronics", "Phones"]
  """
  def breadcrumb_path(category, language \\ nil)

  def breadcrumb_path(%__MODULE__{parent: nil} = category, language) do
    [get_localized_name(category, language)]
  end

  def breadcrumb_path(%__MODULE__{parent: %__MODULE__{} = parent} = category, language) do
    breadcrumb_path(parent, language) ++ [get_localized_name(category, language)]
  end

  def breadcrumb_path(%__MODULE__{} = category, language) do
    [get_localized_name(category, language)]
  end

  # Extract localized name from JSONB map
  defp get_localized_name(%__MODULE__{name: name}, language) do
    lang = language || default_language()

    case name do
      nil -> nil
      map when is_map(map) -> map[lang] || first_value(map)
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp first_value(map) when map == %{}, do: nil
  defp first_value(map), do: map |> Map.values() |> List.first()

  defp default_language do
    alias PhoenixKit.Modules.Shop.Translations
    Translations.default_language()
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

  # Prevent category from being its own parent or creating circular references
  defp validate_no_circular_parent(changeset) do
    parent_uuid = get_change(changeset, :parent_uuid)
    category_uuid = changeset.data.uuid

    cond do
      is_nil(parent_uuid) ->
        changeset

      parent_uuid == category_uuid ->
        add_error(changeset, :parent_uuid, "cannot be self")

      true ->
        check_ancestor_cycle(changeset, category_uuid, parent_uuid)
    end
  end

  defp check_ancestor_cycle(changeset, target_uuid, current_uuid) do
    repo = PhoenixKit.RepoHelper.repo()

    case repo.get_by(__MODULE__, uuid: current_uuid) do
      nil ->
        changeset

      %{parent_uuid: nil} ->
        changeset

      %{parent_uuid: ^target_uuid} ->
        add_error(changeset, :parent_uuid, "would create a circular reference")

      %{parent_uuid: next_uuid} ->
        check_ancestor_cycle(changeset, target_uuid, next_uuid)
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
end
