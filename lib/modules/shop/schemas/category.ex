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

    field :name, :string
    field :slug, :string
    field :description, :string
    field :image_url, :string
    field :image_id, Ecto.UUID
    field :position, :integer, default: 0
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}
    field :option_schema, {:array, :map}, default: []

    # Multi-language support
    field :translations, :map, default: %{}

    # Self-referential for nesting
    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id

    # Products in this category
    has_many :products, PhoenixKit.Modules.Shop.Product

    timestamps()
  end

  @doc "Returns list of valid category statuses"
  def statuses, do: @statuses

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
      :option_schema,
      :translations
    ])
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
    |> validate_length(:slug, max: 255)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @statuses)
    |> maybe_generate_slug()
    |> validate_not_self_parent()
    |> unique_constraint(:slug)
  end

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

  # Generate slug from name if not provided
  defp maybe_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        case get_change(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :slug, slugify(name))
        end

      _ ->
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

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
