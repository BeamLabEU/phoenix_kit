defmodule PhoenixKit.Modules.Shop.Product do
  @moduledoc """
  Product schema for e-commerce shop.

  Supports both physical and digital products with JSONB flexibility.

  ## Fields

  - `title` - Product title (required)
  - `slug` - URL-friendly identifier (unique)
  - `description` - Short description
  - `body_html` - Full rich text description
  - `status` - draft | active | archived
  - `product_type` - physical | digital
  - `vendor` - Brand/manufacturer
  - `tags` - JSONB array of tags
  - `price` - Base price (required)
  - `compare_at_price` - Original price for discounts
  - `cost_per_item` - Cost for profit calculation
  - `currency` - ISO currency code (default: USD)
  - `taxable` - Subject to tax
  - `weight_grams` - Weight for shipping
  - `requires_shipping` - Needs physical delivery
  - `has_variants` - Has product variants
  - `option_names` - JSONB array of variant option names
  - `images` - JSONB array of image objects
  - `featured_image` - Main image URL
  - `seo_title` - SEO title
  - `seo_description` - SEO description
  - `file_id` - Storage file reference (digital products)
  - `download_limit` - Max downloads (digital)
  - `download_expiry_days` - Days until download expires
  - `metadata` - JSONB for custom fields
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ["draft", "active", "archived"]
  @product_types ["physical", "digital"]

  schema "phoenix_kit_shop_products" do
    field :uuid, Ecto.UUID

    # Basic info
    field :title, :string
    field :slug, :string
    field :description, :string
    field :body_html, :string
    field :status, :string, default: "draft"

    # Type
    field :product_type, :string, default: "physical"
    field :vendor, :string
    field :tags, {:array, :string}, default: []

    # Pricing
    field :price, :decimal
    field :compare_at_price, :decimal
    field :cost_per_item, :decimal
    field :currency, :string, default: "USD"
    field :taxable, :boolean, default: true

    # Physical properties
    field :weight_grams, :integer, default: 0
    field :requires_shipping, :boolean, default: true

    # Variants
    field :has_variants, :boolean, default: false
    field :option_names, {:array, :string}, default: []

    # Media
    field :images, {:array, :map}, default: []
    field :featured_image, :string

    # SEO
    field :seo_title, :string
    field :seo_description, :string

    # Digital products
    field :file_id, Ecto.UUID
    field :download_limit, :integer
    field :download_expiry_days, :integer

    # Extensibility
    field :metadata, :map, default: %{}

    # Relations
    belongs_to :category, PhoenixKit.Modules.Shop.Category
    belongs_to :created_by_user, PhoenixKit.Users.Auth.User, foreign_key: :created_by

    timestamps()
  end

  @doc """
  Changeset for product creation and updates.
  """
  def changeset(product, attrs) do
    product
    |> cast(attrs, [
      :title,
      :slug,
      :description,
      :body_html,
      :status,
      :product_type,
      :vendor,
      :tags,
      :price,
      :compare_at_price,
      :cost_per_item,
      :currency,
      :taxable,
      :weight_grams,
      :requires_shipping,
      :has_variants,
      :option_names,
      :images,
      :featured_image,
      :seo_title,
      :seo_description,
      :file_id,
      :download_limit,
      :download_expiry_days,
      :metadata,
      :category_id,
      :created_by
    ])
    |> validate_required([:title, :price])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:product_type, @product_types)
    |> validate_number(:price, greater_than_or_equal_to: 0)
    |> validate_number(:compare_at_price, greater_than_or_equal_to: 0)
    |> validate_number(:cost_per_item, greater_than_or_equal_to: 0)
    |> validate_number(:weight_grams, greater_than_or_equal_to: 0)
    |> validate_number(:download_limit, greater_than: 0)
    |> validate_number(:download_expiry_days, greater_than: 0)
    |> validate_length(:title, max: 255)
    |> validate_length(:slug, max: 255)
    |> validate_length(:currency, is: 3)
    |> maybe_generate_slug()
    |> unique_constraint(:slug)
  end

  @doc """
  Returns true if product is active.
  """
  def active?(%__MODULE__{status: "active"}), do: true
  def active?(_), do: false

  @doc """
  Returns true if product is physical.
  """
  def physical?(%__MODULE__{product_type: "physical"}), do: true
  def physical?(_), do: false

  @doc """
  Returns true if product is digital.
  """
  def digital?(%__MODULE__{product_type: "digital"}), do: true
  def digital?(_), do: false

  @doc """
  Returns true if product requires shipping.
  """
  def requires_shipping?(%__MODULE__{product_type: "digital"}), do: false
  def requires_shipping?(%__MODULE__{requires_shipping: requires}), do: requires

  @doc """
  Returns the display price (compare_at_price if set, otherwise price).
  """
  def display_price(%__MODULE__{compare_at_price: nil, price: price}), do: price
  def display_price(%__MODULE__{compare_at_price: compare}), do: compare

  @doc """
  Returns true if product has a discount (compare_at_price > price).
  """
  def on_sale?(%__MODULE__{compare_at_price: nil}), do: false

  def on_sale?(%__MODULE__{compare_at_price: compare, price: price}) do
    Decimal.compare(compare, price) == :gt
  end

  @doc """
  Calculates discount percentage.
  """
  def discount_percentage(%__MODULE__{} = product) do
    if on_sale?(product) do
      diff = Decimal.sub(product.compare_at_price, product.price)
      percentage = Decimal.div(diff, product.compare_at_price)
      Decimal.mult(percentage, 100) |> Decimal.round(0) |> Decimal.to_integer()
    else
      0
    end
  end

  # Generate slug from title if not provided
  defp maybe_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        case get_change(changeset, :title) do
          nil -> changeset
          title -> put_change(changeset, :slug, slugify(title))
        end

      _ ->
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
