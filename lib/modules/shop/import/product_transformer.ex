defmodule PhoenixKit.Modules.Shop.Import.ProductTransformer do
  @moduledoc """
  Transform Shopify CSV rows into PhoenixKit Product format.

  Handles:
  - Basic product fields (title, description, price, etc.)
  - Option values and price modifiers in metadata
  - Category assignment based on title keywords
  - Image collection
  """

  alias PhoenixKit.Modules.Shop.Import.{Filter, OptionBuilder}

  @doc """
  Transform a group of CSV rows (one product) into Product attrs.

  ## Arguments

  - handle: Product handle (slug)
  - rows: List of CSV row maps for this product
  - categories_map: Map of slug => category_id

  ## Returns

  Map suitable for `Shop.create_product/1`
  """
  def transform(handle, rows, categories_map \\ %{}) do
    first_row = List.first(rows)
    options = OptionBuilder.build_from_variants(rows)

    # Determine category
    category_slug = Filter.categorize(first_row["Title"] || "")
    category_id = Map.get(categories_map, category_slug)

    # Build metadata with option values and price modifiers
    metadata = build_metadata(options)

    %{
      slug: handle,
      title: first_row["Title"],
      body_html: first_row["Body (HTML)"],
      description: extract_description(first_row["Body (HTML)"]),
      vendor: get_non_empty(first_row, "Vendor"),
      tags: parse_tags(first_row["Tags"]),
      status: parse_status(first_row["Published"]),
      price: options.base_price,
      product_type: "physical",
      requires_shipping: true,
      taxable: true,
      featured_image: find_featured_image(rows),
      images: collect_images(rows),
      seo_title: get_non_empty(first_row, "SEO Title"),
      seo_description: get_non_empty(first_row, "SEO Description"),
      category_id: category_id,
      metadata: metadata
    }
  end

  # Private helpers

  defp build_metadata(options) do
    option_values = %{}
    price_modifiers = %{}

    # Option1 (typically Size) - affects price
    {option_values, price_modifiers} =
      if options.option1_name && options.option1_values != [] do
        key = normalize_key(options.option1_name)

        ov = Map.put(option_values, key, options.option1_values)

        pm =
          if options.option1_modifiers != %{} do
            Map.put(price_modifiers, key, options.option1_modifiers)
          else
            price_modifiers
          end

        {ov, pm}
      else
        {option_values, price_modifiers}
      end

    # Option2 (typically Color) - no price impact, just values
    option_values =
      if options.option2_name && options.option2_values != [] do
        key = normalize_key(options.option2_name)
        Map.put(option_values, key, options.option2_values)
      else
        option_values
      end

    result = %{}

    result =
      if option_values != %{} do
        Map.put(result, "_option_values", option_values)
      else
        result
      end

    result =
      if price_modifiers != %{} do
        Map.put(result, "_price_modifiers", price_modifiers)
      else
        result
      end

    result
  end

  defp normalize_key(name) do
    name
    |> String.downcase()
    |> String.replace(~r/\s+/, "_")
    |> String.replace(~r/[^a-z0-9_]/, "")
  end

  defp get_non_empty(row, key) do
    case row[key] do
      nil -> nil
      "" -> nil
      value -> String.trim(value)
    end
  end

  defp parse_tags(nil), do: []
  defp parse_tags(""), do: []

  defp parse_tags(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_status("true"), do: "active"
  defp parse_status("TRUE"), do: "active"
  defp parse_status(_), do: "draft"

  defp extract_description(nil), do: nil
  defp extract_description(""), do: nil

  defp extract_description(html) do
    # Extract first paragraph as description (strip HTML tags)
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp find_featured_image(rows) do
    # Find image with position 1, or first image
    featured =
      Enum.find(rows, fn row ->
        row["Image Position"] == "1"
      end)

    case featured do
      nil -> get_non_empty(List.first(rows), "Image Src")
      row -> get_non_empty(row, "Image Src")
    end
  end

  defp collect_images(rows) do
    rows
    |> Enum.map(fn row -> get_non_empty(row, "Image Src") end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn url -> %{"src" => url} end)
  end
end
