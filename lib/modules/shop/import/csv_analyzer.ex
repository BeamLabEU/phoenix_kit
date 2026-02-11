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
  alias PhoenixKit.Modules.Shop.Import.Filter

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
  def analyze_options(file_path, config \\ nil) do
    grouped = CSVParser.parse_and_group(file_path)

    # Apply import config filter if provided and not skipped
    {filtered, skipped_count} =
      if config && !config.skip_filter do
        filtered =
          grouped
          |> Enum.filter(fn {_handle, rows} -> Filter.should_include?(rows, config) end)
          |> Map.new()

        {filtered, map_size(grouped) - map_size(filtered)}
      else
        {grouped, 0}
      end

    # Group options by NAME instead of position
    # This handles cases where different products use Option1 for different purposes
    {option_data, total_variants} =
      Enum.reduce(filtered, {%{}, 0}, fn {_handle, rows}, {acc, variant_count} ->
        # Get option names and values from all rows
        first_row = List.first(rows)
        variant_rows = Enum.filter(rows, &has_price?/1)

        # Collect options by name
        acc = collect_options_by_name(acc, first_row, variant_rows)

        {acc, variant_count + length(variant_rows)}
      end)

    # Convert to output format, sorted by name
    options =
      option_data
      |> Enum.sort_by(fn {name, _} -> String.downcase(name) end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{name, values}, index} ->
        %{
          name: name,
          position: index,
          values: MapSet.to_list(values) |> Enum.sort()
        }
      end)

    %{
      options: options,
      total_products: map_size(filtered),
      total_variants: total_variants,
      total_skipped: skipped_count
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

  # Collect options grouped by name (not position)
  defp collect_options_by_name(acc, first_row, variant_rows) do
    # Get option names from first row
    option_names =
      for i <- 1..@max_options,
          name = get_option_name(first_row, i),
          name != nil,
          do: {i, name}

    # Collect values for each option name
    Enum.reduce(option_names, acc, fn {position, name}, acc ->
      # Get all values for this option from variant rows
      values =
        Enum.reduce(variant_rows, MapSet.new(), fn row, values_acc ->
          case get_option_value(row, position) do
            nil -> values_acc
            "" -> values_acc
            value -> MapSet.put(values_acc, value)
          end
        end)

      # Merge with existing values for this option name
      existing = Map.get(acc, name, MapSet.new())
      Map.put(acc, name, MapSet.union(existing, values))
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
