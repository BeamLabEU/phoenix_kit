defmodule PhoenixKit.Modules.Shop.Import.CSVAnalyzer do
  @moduledoc """
  Analyze Shopify CSV files to extract option metadata.

  Extracts all Option1..Option10 names and unique values from CSV
  for use in the import mapping UI.

  ## Usage

      CSVAnalyzer.analyze_options("/path/to/products.csv")
      # => %{
      #   options: [
      #     %{name: "Size", position: 1, values: ["Small", "Medium", "Large"]},
      #     %{name: "Color", position: 2, values: ["Red", "Blue", "Green"]}
      #   ],
      #   total_products: 150,
      #   total_variants: 450
      # }
  """

  alias PhoenixKit.Modules.Shop.Import.CSVParser

  @max_options 10

  @doc """
  Analyzes a CSV file and extracts option metadata.

  Returns a map with:
  - `options` - List of option definitions with name, position, and unique values
  - `total_products` - Number of unique product handles
  - `total_variants` - Total number of variant rows

  ## Examples

      CSVAnalyzer.analyze_options("/tmp/products.csv")
      # => %{
      #   options: [
      #     %{name: "Size", position: 1, values: ["S", "M", "L", "XL"]},
      #     %{name: "Cup Color", position: 2, values: ["Red", "Blue"]},
      #     %{name: "Liquid Color", position: 3, values: ["Clear", "Amber"]}
      #   ],
      #   total_products: 50,
      #   total_variants: 200
      # }
  """
  def analyze_options(file_path) do
    grouped = CSVParser.parse_and_group(file_path)

    # Initialize accumulators for each option position
    option_accumulators =
      for i <- 1..@max_options, into: %{} do
        {i, %{name: nil, values: MapSet.new()}}
      end

    # Process all products
    {option_data, total_variants} =
      Enum.reduce(grouped, {option_accumulators, 0}, fn {_handle, rows}, {acc, variant_count} ->
        # Get option names from first row
        first_row = List.first(rows)

        # Update names if not set yet
        acc = update_option_names(acc, first_row)

        # Collect values from all variant rows
        variant_rows = Enum.filter(rows, &has_price?/1)
        acc = collect_option_values(acc, variant_rows)

        {acc, variant_count + length(variant_rows)}
      end)

    # Convert to output format
    options =
      option_data
      |> Enum.filter(fn {_pos, data} -> data.name != nil end)
      |> Enum.sort_by(fn {pos, _} -> pos end)
      |> Enum.map(fn {pos, data} ->
        %{
          name: data.name,
          position: pos,
          values: MapSet.to_list(data.values) |> Enum.sort()
        }
      end)

    %{
      options: options,
      total_products: map_size(grouped),
      total_variants: total_variants
    }
  end

  @doc """
  Quick analysis - only extracts option names without values.

  Faster than full analysis, useful for initial UI display.
  """
  def analyze_option_names(file_path) do
    # Read just the first few rows to get option names
    grouped = CSVParser.parse_and_group(file_path)

    # Get first product's first row
    first_product_rows = grouped |> Map.values() |> List.first() || []
    first_row = List.first(first_product_rows) || %{}

    # Extract option names
    for i <- 1..@max_options,
        name = get_option_name(first_row, i),
        name != nil do
      %{name: name, position: i}
    end
  end

  @doc """
  Compares CSV option values with global option values.

  Returns a map showing which values are new (not in global option).

  ## Examples

      CSVAnalyzer.compare_with_global_option(csv_values, global_option)
      # => %{
      #   existing: ["Red", "Blue"],
      #   new: ["Yellow", "Purple"]
      # }
  """
  def compare_with_global_option(csv_values, global_option) when is_list(csv_values) do
    global_values = extract_global_option_values(global_option)
    global_set = MapSet.new(global_values)

    csv_set = MapSet.new(csv_values)

    existing = MapSet.intersection(csv_set, global_set) |> MapSet.to_list()
    new_values = MapSet.difference(csv_set, global_set) |> MapSet.to_list()

    %{
      existing: Enum.sort(existing),
      new: Enum.sort(new_values)
    }
  end

  def compare_with_global_option(_, _), do: %{existing: [], new: []}

  # Extract values from global option (handles both simple and enhanced format)
  defp extract_global_option_values(nil), do: []

  defp extract_global_option_values(%{"options" => options}) when is_list(options) do
    Enum.map(options, fn
      opt when is_binary(opt) -> opt
      %{"value" => value} -> value
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_global_option_values(_), do: []

  # Private helpers

  defp update_option_names(acc, first_row) do
    Enum.reduce(1..@max_options, acc, fn i, acc ->
      case get_option_name(first_row, i) do
        nil ->
          acc

        name ->
          # Only update if not already set
          if acc[i].name == nil do
            put_in(acc, [i, :name], name)
          else
            acc
          end
      end
    end)
  end

  defp collect_option_values(acc, variant_rows) do
    Enum.reduce(variant_rows, acc, fn row, acc ->
      Enum.reduce(1..@max_options, acc, fn i, acc ->
        case get_option_value(row, i) do
          nil -> acc
          "" -> acc
          value -> update_in(acc, [i, :values], &MapSet.put(&1, value))
        end
      end)
    end)
  end

  defp get_option_name(row, position) do
    key = "Option#{position} Name"

    case row[key] do
      nil -> nil
      "" -> nil
      name -> String.trim(name)
    end
  end

  defp get_option_value(row, position) do
    key = "Option#{position} Value"

    case row[key] do
      nil -> nil
      "" -> nil
      value -> String.trim(value)
    end
  end

  defp has_price?(row) do
    price = row["Variant Price"]
    price != nil and price != ""
  end
end
