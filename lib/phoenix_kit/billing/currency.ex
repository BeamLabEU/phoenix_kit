defmodule PhoenixKit.Billing.Currency do
  @moduledoc """
  Currency schema for PhoenixKit Billing system.

  Manages supported currencies with exchange rates for multi-currency billing.

  ## Schema Fields

  - `code`: ISO 4217 currency code (e.g., "EUR", "USD", "GBP")
  - `name`: Full currency name (e.g., "Euro", "US Dollar")
  - `symbol`: Currency symbol (e.g., "€", "$", "£")
  - `decimal_places`: Number of decimal places (usually 2)
  - `is_default`: Whether this is the default currency
  - `enabled`: Whether currency is available for use
  - `exchange_rate`: Rate relative to base currency
  - `sort_order`: Display order in currency lists

  ## Usage Examples

      # List all enabled currencies
      currencies = PhoenixKit.Billing.list_currencies()

      # Get default currency
      currency = PhoenixKit.Billing.get_default_currency()

      # Format amount in currency
      PhoenixKit.Billing.Currency.format_amount(99.99, currency)
      # => "€99.99"
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  @primary_key {:id, :id, autogenerate: true}

  schema "phoenix_kit_currencies" do
    field :code, :string
    field :name, :string
    field :symbol, :string
    field :decimal_places, :integer, default: 2
    field :is_default, :boolean, default: false
    field :enabled, :boolean, default: true
    field :exchange_rate, :decimal, default: Decimal.new("1.0")
    field :sort_order, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for currency creation and updates.
  """
  def changeset(currency, attrs) do
    currency
    |> cast(attrs, [
      :code,
      :name,
      :symbol,
      :decimal_places,
      :is_default,
      :enabled,
      :exchange_rate,
      :sort_order
    ])
    |> validate_required([:code, :name, :symbol])
    |> validate_length(:code, is: 3)
    |> validate_length(:symbol, min: 1, max: 5)
    |> validate_number(:decimal_places, greater_than_or_equal_to: 0, less_than_or_equal_to: 4)
    |> validate_number(:exchange_rate, greater_than: 0)
    |> unique_constraint(:code)
    |> upcase_code()
  end

  defp upcase_code(changeset) do
    case get_change(changeset, :code) do
      nil -> changeset
      code -> put_change(changeset, :code, String.upcase(code))
    end
  end

  @doc """
  Formats an amount with currency symbol.

  ## Examples

      iex> currency = %Currency{symbol: "€", decimal_places: 2}
      iex> Currency.format_amount(Decimal.new("99.99"), currency)
      "€99.99"

      iex> Currency.format_amount(1234.5, currency)
      "€1,234.50"
  """
  def format_amount(amount, %__MODULE__{symbol: symbol, decimal_places: places}) do
    amount
    |> to_decimal()
    |> Decimal.round(places)
    |> format_with_thousands()
    |> then(&"#{symbol}#{&1}")
  end

  @doc """
  Formats an amount without currency symbol.
  """
  def format_amount_plain(amount, %__MODULE__{decimal_places: places}) do
    amount
    |> to_decimal()
    |> Decimal.round(places)
    |> format_with_thousands()
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_number(n), do: Decimal.from_float(n * 1.0)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp format_with_thousands(decimal) do
    decimal
    |> Decimal.to_string(:normal)
    |> String.split(".")
    |> case do
      [integer] ->
        format_integer_part(integer)

      [integer, fraction] ->
        "#{format_integer_part(integer)}.#{fraction}"
    end
  end

  defp format_integer_part(str) do
    str
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  @doc """
  Converts amount from one currency to another.

  ## Examples

      iex> from = %Currency{exchange_rate: Decimal.new("1.0")}  # EUR (base)
      iex> to = %Currency{exchange_rate: Decimal.new("1.1")}    # USD
      iex> Currency.convert(100, from, to)
      Decimal.new("110.00")
  """
  def convert(amount, %__MODULE__{exchange_rate: from_rate}, %__MODULE__{exchange_rate: to_rate}) do
    amount
    |> to_decimal()
    |> Decimal.div(from_rate)
    |> Decimal.mult(to_rate)
    |> Decimal.round(2)
  end
end
