defmodule PhoenixKit.Modules.Shop.CartItem do
  @moduledoc """
  Cart item schema with price snapshot for consistency.

  When a product is added to the cart, we snapshot the current price and product
  details. This ensures that:

  1. Price changes after adding don't affect the cart total unexpectedly
  2. If the product is deleted, we still have the title and other info
  3. We can show users when prices have changed since they added items

  ## Fields

  - `cart_id` - Reference to the cart (required)
  - `product_id` - Reference to the product (nullable, ON DELETE SET NULL)
  - `product_title` - Product title snapshot (required)
  - `product_slug` - Product slug snapshot
  - `product_sku` - Product SKU snapshot
  - `product_image` - Product image URL snapshot
  - `unit_price` - Price per unit at time of adding (required)
  - `compare_at_price` - Original price for showing discounts
  - `quantity` - Number of items (required, > 0)
  - `line_total` - Calculated: unit_price * quantity
  - `weight_grams` - Weight for shipping calculation
  - `taxable` - Whether item is taxable
  - `selected_specs` - JSON object for specification-based pricing (e.g., {"material": "PETG", "color": "Gold"})
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Modules.Shop.Cart
  alias PhoenixKit.Modules.Shop.Product

  schema "phoenix_kit_shop_cart_items" do
    field :uuid, Ecto.UUID

    belongs_to :cart, Cart
    belongs_to :product, Product

    # Snapshot
    field :product_title, :string
    field :product_slug, :string
    field :product_sku, :string
    field :product_image, :string

    # Pricing (snapshot)
    field :unit_price, :decimal
    field :compare_at_price, :decimal
    field :currency, :string, default: "USD"

    # Quantity
    field :quantity, :integer, default: 1

    # Calculated
    field :line_total, :decimal

    # Physical
    field :weight_grams, :integer, default: 0
    field :taxable, :boolean, default: true

    # Specification-based pricing
    field :selected_specs, :map, default: %{}

    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for cart item creation and updates.
  """
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :cart_id,
      :product_id,
      :product_title,
      :product_slug,
      :product_sku,
      :product_image,
      :unit_price,
      :compare_at_price,
      :currency,
      :quantity,
      :line_total,
      :weight_grams,
      :taxable,
      :selected_specs,
      :metadata
    ])
    |> validate_required([:cart_id, :product_title, :unit_price, :quantity])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_price, greater_than_or_equal_to: 0)
    |> validate_length(:currency, is: 3)
    |> calculate_line_total()
    |> maybe_generate_uuid()
    |> foreign_key_constraint(:cart_id)
    |> foreign_key_constraint(:product_id)
  end

  @doc """
  Creates changeset attributes from a product.

  ## Examples

      iex> from_product(product, 2)
      %{
        product_id: 1,
        product_title: "Widget",
        product_slug: "widget",
        unit_price: Decimal.new("19.99"),
        quantity: 2,
        ...
      }
  """
  def from_product(%Product{} = product, quantity \\ 1) do
    %{
      product_id: product.id,
      product_title: product.title,
      product_slug: product.slug,
      product_image: product.featured_image,
      unit_price: product.price,
      compare_at_price: product.compare_at_price,
      currency: product.currency,
      quantity: quantity,
      weight_grams: product.weight_grams || 0,
      taxable: product.taxable
    }
  end

  @doc """
  Returns true if product data has changed since the item was added.
  Useful for showing price change warnings.
  """
  def product_changed?(%__MODULE__{product_id: nil}, _product), do: true

  def product_changed?(%__MODULE__{} = item, %Product{} = product) do
    Decimal.compare(item.unit_price, product.price) != :eq
  end

  @doc """
  Returns the price difference if the product price has changed.
  Positive = price increased, Negative = price decreased.
  """
  def price_difference(%__MODULE__{} = item, %Product{} = product) do
    Decimal.sub(product.price, item.unit_price)
  end

  @doc """
  Returns true if this item is on sale (has compare_at_price > unit_price).
  """
  def on_sale?(%__MODULE__{compare_at_price: nil}), do: false

  def on_sale?(%__MODULE__{compare_at_price: compare, unit_price: price}) do
    Decimal.compare(compare, price) == :gt
  end

  @doc """
  Returns discount percentage for sale items.
  """
  def discount_percentage(%__MODULE__{} = item) do
    if on_sale?(item) do
      diff = Decimal.sub(item.compare_at_price, item.unit_price)

      diff
      |> Decimal.div(item.compare_at_price)
      |> Decimal.mult(100)
      |> Decimal.round(0)
      |> Decimal.to_integer()
    else
      0
    end
  end

  @doc """
  Returns true if the product has been deleted (product_id is nil after SET NULL).
  """
  def product_deleted?(%__MODULE__{product_id: nil}), do: true
  def product_deleted?(_), do: false

  # Private helpers

  defp calculate_line_total(changeset) do
    quantity = get_field(changeset, :quantity) || 1
    unit_price = get_field(changeset, :unit_price) || Decimal.new("0")
    line_total = Decimal.mult(unit_price, quantity)
    put_change(changeset, :line_total, line_total)
  end

  defp maybe_generate_uuid(changeset) do
    case get_field(changeset, :uuid) do
      nil -> put_change(changeset, :uuid, Ecto.UUID.generate())
      _ -> changeset
    end
  end
end
