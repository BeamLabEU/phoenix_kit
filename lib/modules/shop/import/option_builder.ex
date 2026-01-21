defmodule PhoenixKit.Modules.Shop.Import.OptionBuilder do
  @moduledoc """
  Build option values and price modifiers from Shopify variant rows.

  Extracts Option1/Option2 names and values from CSV rows,
  calculates base price (minimum) and price modifiers (deltas from base).
  """

  @doc """
  Build options data from variant rows.

  Returns a map with:
  - base_price: minimum variant price (Decimal)
  - option1_name: name of first option (e.g., "Size")
  - option1_values: list of unique values for option1
  - option1_modifiers: map of value => price delta from base
  - option2_name: name of second option (e.g., "Color")
  - option2_values: list of unique values for option2

  ## Examples

      OptionBuilder.build_from_variants(rows)
      # => %{
      #   base_price: Decimal.new("22.80"),
      #   option1_name: "Size",
      #   option1_values: ["4 inches (10 cm)", "5 inches (13 cm)", ...],
      #   option1_modifiers: %{"4 inches (10 cm)" => "0", "5 inches (13 cm)" => "5.00", ...},
      #   option2_name: "Color",
      #   option2_values: ["Black", "White", ...]
      # }
  """
  def build_from_variants(rows) when is_list(rows) do
    # Get option names from first row
    first_row = List.first(rows)
    option1_name = get_non_empty(first_row, "Option1 Name")
    option2_name = get_non_empty(first_row, "Option2 Name")

    # Extract variants with prices
    variants =
      rows
      |> Enum.map(fn row ->
        %{
          option1_value: get_non_empty(row, "Option1 Value"),
          option2_value: get_non_empty(row, "Option2 Value"),
          price: parse_price(row["Variant Price"])
        }
      end)
      |> Enum.filter(& &1.price)

    # Calculate base price (minimum)
    base_price =
      variants
      |> Enum.map(& &1.price)
      |> Enum.min(fn -> Decimal.new("0") end)

    # Build option1 data (typically Size - affects price)
    {option1_values, option1_modifiers} = build_option_data(variants, :option1_value, base_price)

    # Build option2 values (typically Color - no price impact, just values)
    option2_values = get_unique_values(variants, :option2_value)

    %{
      base_price: base_price,
      option1_name: option1_name,
      option1_values: option1_values,
      option1_modifiers: option1_modifiers,
      option2_name: option2_name,
      option2_values: option2_values
    }
  end

  # Private helpers

  defp get_non_empty(row, key) do
    case row[key] do
      nil -> nil
      "" -> nil
      value -> String.trim(value)
    end
  end

  defp parse_price(nil), do: nil
  defp parse_price(""), do: nil

  defp parse_price(str) when is_binary(str) do
    str = String.trim(str)

    case Decimal.parse(str) do
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  defp build_option_data(variants, field, base_price) do
    # Get unique values preserving order of first appearance
    values =
      variants
      |> Enum.map(&Map.get(&1, field))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # Build price modifiers for each value
    # Group by value and take the first price for each
    price_by_value =
      variants
      |> Enum.reduce(%{}, fn v, acc ->
        value = Map.get(v, field)

        if value && !Map.has_key?(acc, value) do
          Map.put(acc, value, v.price)
        else
          acc
        end
      end)

    # Calculate modifiers as delta from base price
    modifiers =
      price_by_value
      |> Enum.reduce(%{}, fn {value, price}, acc ->
        modifier = Decimal.sub(price, base_price)
        Map.put(acc, value, Decimal.to_string(modifier))
      end)

    {values, modifiers}
  end

  defp get_unique_values(variants, field) do
    variants
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
