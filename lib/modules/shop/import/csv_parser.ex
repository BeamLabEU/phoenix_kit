defmodule PhoenixKit.Modules.Shop.Import.CSVParser do
  @moduledoc """
  Parse Shopify CSV and group rows by Handle.

  Shopify CSV structure:
  - First row with product data contains title, description, etc.
  - Subsequent rows for same Handle contain variant data only (empty title/description)
  - Each variant row has Option1/Option2 values and prices
  """

  NimbleCSV.define(ShopifyCSV, separator: ",", escape: "\"")

  @doc """
  Parse CSV file and group rows by Handle (product identifier).

  Returns a map where keys are handles and values are lists of row maps.

  ## Examples

      CSVParser.parse_and_group("/path/to/products.csv")
      # => %{
      #   "product-handle" => [
      #     %{"Handle" => "product-handle", "Title" => "Product", ...},
      #     %{"Handle" => "product-handle", "Option1 Value" => "Small", ...},
      #     ...
      #   ],
      #   ...
      # }
  """
  def parse_and_group(file_path) do
    {_headers, rows} =
      file_path
      |> File.stream!([:utf8])
      |> ShopifyCSV.parse_stream(skip_headers: false)
      |> Enum.reduce({nil, []}, fn
        row, {nil, []} ->
          # First row is headers
          {row, []}

        row, {headers, rows} ->
          # Convert row to map using headers
          row_map =
            Enum.zip(headers, row)
            |> Map.new()

          {headers, [row_map | rows]}
      end)

    # Group by Handle and reverse to maintain order
    rows
    |> Enum.reverse()
    |> Enum.group_by(& &1["Handle"])
  end

  @doc """
  Get the first (main) row for a product group.
  Contains title, description, and other product-level data.
  """
  def main_row(rows) when is_list(rows) do
    List.first(rows)
  end

  @doc """
  Get all variant rows (rows with price data).
  """
  def variant_rows(rows) when is_list(rows) do
    Enum.filter(rows, fn row ->
      price = row["Variant Price"]
      price != nil and price != ""
    end)
  end
end
