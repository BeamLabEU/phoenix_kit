defmodule PhoenixKit.Modules.Shop.Import.ProductTransformer do
  @moduledoc """
  Transform Shopify CSV rows into PhoenixKit Product format.

  Handles:
  - Basic product fields (title, description, price, etc.)
  - Option values and price modifiers in metadata
  - Category assignment based on title keywords (configurable)
  - Image collection
  - Auto-creation of missing categories
  """

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Import.{Filter, OptionBuilder}

  require Logger

  @doc """
  Transform a group of CSV rows (one product) into Product attrs.

  ## Arguments

  - handle: Product handle (slug)
  - rows: List of CSV row maps for this product
  - categories_map: Map of slug => category_id
  - config: Optional ImportConfig for category rules (nil = legacy defaults)

  ## Returns

  Map suitable for `Shop.create_product/1`
  """
  def transform(handle, rows, categories_map \\ %{}, config \\ nil) do
    first_row = List.first(rows)
    options = OptionBuilder.build_from_variants(rows)

    # Determine category using config or legacy defaults
    title = first_row["Title"] || ""
    category_slug = Filter.categorize(title, config)

    # Get category_id, auto-creating if necessary
    category_id = resolve_category_id(category_slug, categories_map)

    # Build metadata with option values and price modifiers
    metadata = build_metadata(options)

    %{
      slug: handle,
      title: title,
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

  @doc """
  Resolves category_id from slug, auto-creating if necessary.

  If category doesn't exist, creates it with:
  - name: Generated from slug (capitalize, replace hyphens with spaces)
  - status: "active"
  - slug: The original slug
  """
  def resolve_category_id(category_slug, categories_map) when is_binary(category_slug) do
    case Map.get(categories_map, category_slug) do
      nil ->
        # Category doesn't exist - try to create it
        maybe_create_category(category_slug)

      category_id ->
        category_id
    end
  end

  def resolve_category_id(_, _), do: nil

  defp maybe_create_category(slug) when is_binary(slug) and slug != "" do
    # Generate name from slug: "vases-planters" -> "Vases Planters"
    name =
      slug
      |> String.replace("-", " ")
      |> String.split(" ")
      |> Enum.map_join(" ", &String.capitalize/1)

    attrs = %{
      name: name,
      slug: slug,
      status: "active"
    }

    case Shop.create_category(attrs) do
      {:ok, category} ->
        Logger.info("Auto-created category: #{slug} (id: #{category.id})")
        category.id

      {:error, changeset} ->
        # Might already exist due to race condition - try to fetch
        case Shop.get_category_by_slug(slug) do
          nil ->
            Logger.warning("Failed to create category #{slug}: #{inspect(changeset.errors)}")
            nil

          category ->
            category.id
        end
    end
  end

  defp maybe_create_category(_), do: nil

  @doc """
  Build an updated categories_map including any auto-created categories.

  Call this after transform() to update the map for subsequent products.
  """
  def update_categories_map(categories_map, category_slug) when is_binary(category_slug) do
    if Map.has_key?(categories_map, category_slug) do
      categories_map
    else
      case Shop.get_category_by_slug(category_slug) do
        nil -> categories_map
        category -> Map.put(categories_map, category_slug, category.id)
      end
    end
  end

  def update_categories_map(categories_map, _), do: categories_map

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
