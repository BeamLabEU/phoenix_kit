defmodule PhoenixKitWeb.Components.Core.CurrencyDisplay do
  @moduledoc """
  Provides currency formatting components for the billing system.

  Supports formatting monetary amounts with currency symbols,
  locale-aware number formatting, and various display styles.
  """

  use Phoenix.Component

  @doc """
  Formats and displays a monetary amount with currency symbol.

  ## Attributes
  - `amount` - Decimal or number to display (required)
  - `currency` - Currency code like "EUR", "USD" (default: "EUR")
  - `symbol_position` - :before or :after (default: :before)
  - `show_code` - Show currency code alongside symbol (default: false)
  - `class` - Additional CSS classes

  ## Examples

      <.currency_amount amount={99.99} />
      <.currency_amount amount={@order.total} currency="USD" />
      <.currency_amount amount={150.00} currency="EUR" show_code={true} />
  """
  attr :amount, :any, required: true
  attr :currency, :string, default: "EUR"
  attr :symbol_position, :atom, default: :before, values: [:before, :after]
  attr :show_code, :boolean, default: false
  attr :class, :string, default: ""

  def currency_amount(assigns) do
    assigns = assign(assigns, :formatted, format_amount(assigns.amount, assigns.currency))

    ~H"""
    <span class={["font-mono", @class]}>
      <%= if @symbol_position == :before do %>
        <span class="text-base-content/70">{currency_symbol(@currency)}</span>{@formatted}
      <% else %>
        {@formatted}<span class="text-base-content/70">{currency_symbol(@currency)}</span>
      <% end %>
      <%= if @show_code do %>
        <span class="text-xs text-base-content/50 ml-1">{@currency}</span>
      <% end %>
    </span>
    """
  end

  @doc """
  Displays a compact currency amount, useful for tables and lists.

  ## Attributes
  - `amount` - Decimal or number to display (required)
  - `currency` - Currency code (default: "EUR")
  - `class` - Additional CSS classes

  ## Examples

      <.currency_compact amount={99.99} />
      <.currency_compact amount={@invoice.total} currency="USD" />
  """
  attr :amount, :any, required: true
  attr :currency, :string, default: "EUR"
  attr :class, :string, default: ""

  def currency_compact(assigns) do
    assigns = assign(assigns, :formatted, format_amount(assigns.amount, assigns.currency))

    ~H"""
    <span class={["font-mono tabular-nums", @class]}>
      {currency_symbol(@currency)}{@formatted}
    </span>
    """
  end

  @doc """
  Displays currency with styling for positive/negative amounts.

  ## Attributes
  - `amount` - Decimal or number to display (required)
  - `currency` - Currency code (default: "EUR")
  - `class` - Additional CSS classes

  ## Examples

      <.currency_colored amount={100.00} />
      <.currency_colored amount={-50.00} currency="USD" />
  """
  attr :amount, :any, required: true
  attr :currency, :string, default: "EUR"
  attr :class, :string, default: ""

  def currency_colored(assigns) do
    assigns =
      assigns
      |> assign(:formatted, format_amount(assigns.amount, assigns.currency))
      |> assign(:color_class, amount_color_class(assigns.amount))

    ~H"""
    <span class={["font-mono tabular-nums", @color_class, @class]}>
      {currency_symbol(@currency)}{@formatted}
    </span>
    """
  end

  @doc """
  Displays a currency badge with symbol and name.

  ## Attributes
  - `code` - Currency code like "EUR", "USD" (required)
  - `name` - Currency name (optional, will be looked up if not provided)
  - `size` - Badge size: :xs, :sm, :md, :lg (default: :sm)
  - `class` - Additional CSS classes

  ## Examples

      <.currency_badge code="EUR" />
      <.currency_badge code="USD" name="US Dollar" size={:md} />
  """
  attr :code, :string, required: true
  attr :name, :string, default: nil
  attr :size, :atom, default: :sm, values: [:xs, :sm, :md, :lg]
  attr :class, :string, default: ""

  def currency_badge(assigns) do
    assigns =
      assign_new(assigns, :display_name, fn -> assigns.name || currency_name(assigns.code) end)

    ~H"""
    <span class={["badge badge-outline", size_class(@size), @class]}>
      <span class="font-bold mr-1">{currency_symbol(@code)}</span>
      <span>{@code}</span>
      <%= if @display_name do %>
        <span class="text-base-content/60 ml-1">- {@display_name}</span>
      <% end %>
    </span>
    """
  end

  # Private helper functions

  defp format_amount(nil, _currency), do: "0.00"

  defp format_amount(amount, currency) when is_struct(amount, Decimal) do
    places = decimal_places(currency)

    amount
    |> Decimal.round(places)
    |> Decimal.to_string()
    |> format_with_separators()
  end

  defp format_amount(amount, currency) when is_number(amount) do
    places = decimal_places(currency)

    :erlang.float_to_binary(amount / 1, decimals: places)
    |> format_with_separators()
  end

  defp format_amount(amount, currency) when is_binary(amount) do
    case Decimal.parse(amount) do
      {decimal, _} -> format_amount(decimal, currency)
      :error -> "0.00"
    end
  end

  defp format_with_separators(str) do
    [integer, decimal] =
      case String.split(str, ".") do
        [int] -> [int, "00"]
        [int, dec] -> [int, String.pad_trailing(dec, 2, "0")]
      end

    formatted_int =
      integer
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.join(",")
      |> String.reverse()

    "#{formatted_int}.#{decimal}"
  end

  defp currency_symbol("EUR"), do: "€"
  defp currency_symbol("USD"), do: "$"
  defp currency_symbol("GBP"), do: "£"
  defp currency_symbol("JPY"), do: "¥"
  defp currency_symbol("CHF"), do: "CHF "
  defp currency_symbol("CAD"), do: "C$"
  defp currency_symbol("AUD"), do: "A$"
  defp currency_symbol("PLN"), do: "zł"
  defp currency_symbol("SEK"), do: "kr"
  defp currency_symbol("NOK"), do: "kr"
  defp currency_symbol("DKK"), do: "kr"
  defp currency_symbol("CZK"), do: "Kč"
  defp currency_symbol("HUF"), do: "Ft"
  defp currency_symbol("RON"), do: "lei"
  defp currency_symbol("BGN"), do: "лв"
  defp currency_symbol("INR"), do: "₹"
  defp currency_symbol(code), do: "#{code} "

  defp currency_name("EUR"), do: "Euro"
  defp currency_name("USD"), do: "US Dollar"
  defp currency_name("GBP"), do: "British Pound"
  defp currency_name("JPY"), do: "Japanese Yen"
  defp currency_name("CHF"), do: "Swiss Franc"
  defp currency_name("CAD"), do: "Canadian Dollar"
  defp currency_name("AUD"), do: "Australian Dollar"
  defp currency_name("PLN"), do: "Polish Zloty"
  defp currency_name("SEK"), do: "Swedish Krona"
  defp currency_name("NOK"), do: "Norwegian Krone"
  defp currency_name("DKK"), do: "Danish Krone"
  defp currency_name("CZK"), do: "Czech Koruna"
  defp currency_name("HUF"), do: "Hungarian Forint"
  defp currency_name("RON"), do: "Romanian Leu"
  defp currency_name("BGN"), do: "Bulgarian Lev"
  defp currency_name("INR"), do: "Indian Rupee"
  defp currency_name(_), do: nil

  defp decimal_places("JPY"), do: 0
  defp decimal_places("HUF"), do: 0
  defp decimal_places(_), do: 2

  defp amount_color_class(amount) when is_struct(amount, Decimal) do
    cond do
      Decimal.negative?(amount) -> "text-error"
      Decimal.positive?(amount) -> "text-success"
      true -> "text-base-content"
    end
  end

  defp amount_color_class(amount) when is_number(amount) do
    cond do
      amount < 0 -> "text-error"
      amount > 0 -> "text-success"
      true -> "text-base-content"
    end
  end

  defp amount_color_class(_), do: "text-base-content"

  defp size_class(:xs), do: "badge-xs"
  defp size_class(:sm), do: "badge-sm"
  defp size_class(:md), do: "badge-md"
  defp size_class(:lg), do: "badge-lg"
end
