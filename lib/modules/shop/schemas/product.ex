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
  - `made_to_order` - Always available regardless of inventory
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

  @type t :: %__MODULE__{}

  @statuses ["draft", "active", "archived"]
  @product_types ["physical", "digital"]

  schema "phoenix_kit_shop_products" do
    field :uuid, Ecto.UUID

    # Localized fields (JSONB maps: %{"en" => "value", "ru" => "значение"})
    field :title, :map, default: %{}
    field :slug, :map, default: %{}
    field :description, :map, default: %{}
    field :body_html, :map, default: %{}

    # Status (non-localized)
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

    # Availability
    field :made_to_order, :boolean, default: false

    # Media (legacy URL-based)
    field :images, {:array, :map}, default: []
    field :featured_image, :string

    # Media (Storage integration)
    field :featured_image_id, Ecto.UUID
    field :image_ids, {:array, Ecto.UUID}, default: []

    # SEO (localized JSONB maps)
    field :seo_title, :map, default: %{}
    field :seo_description, :map, default: %{}

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
  @localized_fields [:title, :slug, :description, :body_html, :seo_title, :seo_description]

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
      :made_to_order,
      :images,
      :featured_image,
      :featured_image_id,
      :image_ids,
      :seo_title,
      :seo_description,
      :file_id,
      :download_limit,
      :download_expiry_days,
      :metadata,
      :category_id,
      :created_by
    ])
    |> normalize_map_fields(@localized_fields)
    |> validate_required([:price])
    |> validate_localized_required(:title)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:product_type, @product_types)
    |> validate_number(:price, greater_than_or_equal_to: 0)
    |> validate_number(:compare_at_price, greater_than_or_equal_to: 0)
    |> validate_number(:cost_per_item, greater_than_or_equal_to: 0)
    |> validate_number(:weight_grams, greater_than_or_equal_to: 0)
    |> validate_number(:download_limit, greater_than: 0)
    |> validate_number(:download_expiry_days, greater_than: 0)
    |> validate_length(:currency, is: 3)
    |> maybe_generate_slug()
  end

  @doc """
  Returns the list of localized field names.
  """
  def localized_fields, do: @localized_fields

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

  # Generate slug from title for each language
  defp maybe_generate_slug(changeset) do
    title_map = get_field(changeset, :title) || %{}
    slug_map = get_field(changeset, :slug) || %{}

    # For each language with a title but no slug, generate one
    updated_slugs =
      Enum.reduce(title_map, slug_map, fn {lang, title}, acc ->
        if Map.get(acc, lang) in [nil, ""] and title not in [nil, ""] do
          generated = slugify(title)
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
