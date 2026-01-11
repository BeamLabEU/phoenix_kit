defmodule PhoenixKit.Modules.Shop.ShippingMethod do
  @moduledoc """
  Shipping method schema for E-Commerce module.

  Supports weight-based, price-based, and geographic restrictions.

  ## Fields

  - `name` - Method name (required)
  - `slug` - URL-friendly identifier (unique, auto-generated)
  - `description` - Method description
  - `price` - Shipping cost
  - `free_above_amount` - Free shipping threshold
  - `min_weight_grams`, `max_weight_grams` - Weight limits
  - `min_order_amount`, `max_order_amount` - Order amount limits
  - `countries` - Allowed countries (empty = all)
  - `excluded_countries` - Excluded countries
  - `active` - Enabled/disabled
  - `position` - Sort order
  - `estimated_days_min`, `estimated_days_max` - Delivery estimate
  - `tracking_supported` - Tracking available
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "phoenix_kit_shop_shipping_methods" do
    field :uuid, Ecto.UUID

    field :name, :string
    field :slug, :string
    field :description, :string

    # Pricing
    field :price, :decimal, default: Decimal.new("0")
    field :currency, :string, default: "USD"
    field :free_above_amount, :decimal

    # Constraints
    field :min_weight_grams, :integer, default: 0
    field :max_weight_grams, :integer
    field :min_order_amount, :decimal
    field :max_order_amount, :decimal

    # Geographic
    field :countries, {:array, :string}, default: []
    field :excluded_countries, {:array, :string}, default: []

    # Status
    field :active, :boolean, default: true
    field :position, :integer, default: 0

    # Delivery info
    field :estimated_days_min, :integer
    field :estimated_days_max, :integer
    field :tracking_supported, :boolean, default: false

    field :metadata, :map, default: %{}

    timestamps()
  end

  @required_fields [:name, :price]
  @optional_fields [
    :slug,
    :description,
    :currency,
    :free_above_amount,
    :min_weight_grams,
    :max_weight_grams,
    :min_order_amount,
    :max_order_amount,
    :countries,
    :excluded_countries,
    :active,
    :position,
    :estimated_days_min,
    :estimated_days_max,
    :tracking_supported,
    :metadata
  ]

  @doc """
  Changeset for shipping method creation and updates.
  """
  def changeset(method, attrs) do
    method
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, max: 255)
    |> validate_length(:slug, max: 100)
    |> validate_length(:currency, is: 3)
    |> validate_number(:price, greater_than_or_equal_to: 0)
    |> validate_number(:free_above_amount, greater_than: 0)
    |> validate_number(:min_weight_grams, greater_than_or_equal_to: 0)
    |> validate_number(:max_weight_grams, greater_than: 0)
    |> validate_number(:min_order_amount, greater_than: 0)
    |> validate_number(:max_order_amount, greater_than: 0)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:estimated_days_min, greater_than_or_equal_to: 0)
    |> validate_number(:estimated_days_max, greater_than: 0)
    |> maybe_generate_slug()
    |> unique_constraint(:slug)
  end

  @doc """
  Checks if this method is available for given cart parameters.

  ## Examples

      iex> available_for?(method, %{weight_grams: 500, subtotal: Decimal.new("50"), country: "EE"})
      true
  """
  def available_for?(%__MODULE__{active: false}, _params), do: false

  def available_for?(%__MODULE__{} = method, %{
        weight_grams: weight,
        subtotal: subtotal,
        country: country
      }) do
    weight_ok?(method, weight) &&
      amount_ok?(method, subtotal) &&
      country_ok?(method, country)
  end

  def available_for?(%__MODULE__{} = method, params) when is_map(params) do
    weight = Map.get(params, :weight_grams, 0)
    subtotal = Map.get(params, :subtotal, Decimal.new("0"))
    country = Map.get(params, :country)

    available_for?(method, %{weight_grams: weight, subtotal: subtotal, country: country})
  end

  @doc """
  Calculates shipping cost for given subtotal.
  Returns 0 if free shipping threshold is met.
  """
  def calculate_cost(%__MODULE__{free_above_amount: nil, price: price}, _subtotal) do
    price
  end

  def calculate_cost(%__MODULE__{free_above_amount: threshold, price: price}, subtotal) do
    if Decimal.compare(subtotal, threshold) != :lt do
      Decimal.new("0")
    else
      price
    end
  end

  @doc """
  Returns estimated delivery string.

  ## Examples

      iex> delivery_estimate(%ShippingMethod{estimated_days_min: 3, estimated_days_max: 5})
      "3-5 days"

      iex> delivery_estimate(%ShippingMethod{estimated_days_min: 1, estimated_days_max: 1})
      "1 day"
  """
  def delivery_estimate(%__MODULE__{estimated_days_min: nil}), do: nil

  def delivery_estimate(%__MODULE__{estimated_days_min: min, estimated_days_max: nil}) do
    "#{min}+ days"
  end

  def delivery_estimate(%__MODULE__{estimated_days_min: 1, estimated_days_max: 1}) do
    "1 day"
  end

  def delivery_estimate(%__MODULE__{estimated_days_min: min, estimated_days_max: max})
      when min == max do
    "#{min} days"
  end

  def delivery_estimate(%__MODULE__{estimated_days_min: min, estimated_days_max: max}) do
    "#{min}-#{max} days"
  end

  @doc """
  Returns true if method is active.
  """
  def active?(%__MODULE__{active: true}), do: true
  def active?(_), do: false

  @doc """
  Checks if shipping is free for the given subtotal.
  """
  def free_for?(%__MODULE__{free_above_amount: nil}, _subtotal), do: false

  def free_for?(%__MODULE__{free_above_amount: threshold}, subtotal) do
    Decimal.compare(subtotal, threshold) != :lt
  end

  # Private helpers

  defp weight_ok?(%{min_weight_grams: min, max_weight_grams: max}, weight) do
    min_ok = is_nil(min) or weight >= min
    max_ok = is_nil(max) or weight <= max
    min_ok and max_ok
  end

  defp amount_ok?(%{min_order_amount: min, max_order_amount: max}, amount) do
    min_ok = is_nil(min) or Decimal.compare(amount, min) != :lt
    max_ok = is_nil(max) or Decimal.compare(amount, max) != :gt
    min_ok and max_ok
  end

  defp country_ok?(%{countries: [], excluded_countries: []}, _country), do: true

  defp country_ok?(%{countries: [], excluded_countries: excluded}, country) do
    is_nil(country) or country not in excluded
  end

  defp country_ok?(%{countries: allowed, excluded_countries: excluded}, country) do
    (is_nil(country) or country in allowed) and
      (is_nil(country) or country not in excluded)
  end

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

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
