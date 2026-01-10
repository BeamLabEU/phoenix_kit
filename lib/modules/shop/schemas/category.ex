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
  - `metadata` - JSONB for custom fields
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "phoenix_kit_shop_categories" do
    field :uuid, Ecto.UUID

    field :name, :string
    field :slug, :string
    field :description, :string
    field :image_url, :string
    field :position, :integer, default: 0
    field :metadata, :map, default: %{}

    # Self-referential for nesting
    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id

    # Products in this category
    has_many :products, PhoenixKit.Modules.Shop.Product

    timestamps()
  end

  @doc """
  Changeset for category creation and updates.
  """
  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :slug, :description, :image_url, :parent_id, :position, :metadata])
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
    |> validate_length(:slug, max: 255)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> maybe_generate_slug()
    |> validate_not_self_parent()
    |> unique_constraint(:slug)
  end

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
