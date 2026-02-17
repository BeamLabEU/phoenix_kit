defmodule PhoenixKit.Modules.Shop.Import.ProductTransformer do
  @moduledoc """
  Transform Shopify CSV rows into PhoenixKit Product format.

  Handles:
  - Basic product fields (title, description, price, etc.)
  - Option values and price modifiers in metadata
  - Slot-based options with global option mapping
  - Category assignment based on title keywords (configurable)
  - Image collection
  - Auto-creation of missing categories

  ## Extended Transform

  Use `transform_extended/5` with `option_mappings` to enable slot-based
  options that reference global options. This allows multiple uses of the
  same global option in a product (e.g., cup_color and liquid_color both
  referencing the "color" global option).
  """

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Import.{Filter, OptionBuilder}
  alias PhoenixKit.Modules.Shop.SlugResolver
  alias PhoenixKit.Modules.Shop.Translations

  require Logger

  @doc """
  Transform a group of CSV rows (one product) into Product attrs.

  ## Arguments

  - handle: Product handle (slug)
  - rows: List of CSV row maps for this product
  - categories_map: Map of slug => category_id
  - config: Optional ImportConfig for category rules (nil = legacy defaults)
  - opts: Keyword options:
    - `:language` - Target language for imported content (default: system default language)

  ## Returns

  Map suitable for `Shop.create_product/1`
  """
  def transform(handle, rows, categories_map \\ %{}, config \\ nil, opts \\ []) do
    first_row = List.first(rows)
    options = OptionBuilder.build_from_variants(rows)

    # Get target language for localized fields
    language = Keyword.get(opts, :language, Translations.default_language())

    # Determine category using config or legacy defaults
    title = first_row["Title"] || ""
    category_slug = Filter.categorize(title, config)

    # Get category_uuid, auto-creating if necessary (with localized name/slug)
    category_uuid = resolve_category_id(category_slug, categories_map, language)

    # Build metadata with option values and price modifiers
    metadata = build_metadata(options)

    # Extract non-localized values
    body_html_raw = first_row["Body (HTML)"]
    description_raw = extract_description(body_html_raw)
    seo_title_raw = get_non_empty(first_row, "SEO Title")
    seo_description_raw = get_non_empty(first_row, "SEO Description")

    %{
      # Localized fields - stored as maps with language key
      slug: localized_map(handle, language),
      title: localized_map(title, language),
      body_html: localized_map(body_html_raw, language),
      description: localized_map(description_raw, language),
      seo_title: localized_map(seo_title_raw, language),
      seo_description: localized_map(seo_description_raw, language),
      # Non-localized fields
      vendor: get_non_empty(first_row, "Vendor"),
      tags: parse_tags(first_row["Tags"]),
      status: parse_status(first_row["Published"]),
      price: options.base_price,
      product_type: "physical",
      requires_shipping: true,
      taxable: true,
      featured_image: find_featured_image(rows),
      images: collect_images(rows),
      category_uuid: category_uuid,
      metadata: metadata
    }
  end

  # Build a localized field map for a single value
  # Idempotent: if value is already a map with string keys, return as-is
  defp localized_map(nil, _language), do: %{}
  defp localized_map("", _language), do: %{}

  defp localized_map(value, _language) when is_map(value) do
    # Already a localized map - return as-is to prevent double-wrapping
    value
  end

  defp localized_map(value, language) when is_binary(value), do: %{language => value}

  @doc """
  Resolves category_id from slug, auto-creating if necessary.

  If category doesn't exist, creates it with:
  - name: Generated from slug (capitalize, replace hyphens with spaces) - localized map
  - status: "active"
  - slug: The original slug - localized map

  ## Arguments

  - category_slug: The slug string to look up
  - categories_map: Map of slug => category_id
  - language: Target language for localized fields (default: system default)
  """
  def resolve_category_id(category_slug, categories_map, language \\ nil)

  def resolve_category_id(category_slug, categories_map, language)
      when is_binary(category_slug) do
    lang = language || Translations.default_language()

    case Map.get(categories_map, category_slug) do
      nil ->
        # Category doesn't exist - try to create it
        maybe_create_category(category_slug, lang)

      category_id ->
        category_id
    end
  end

  def resolve_category_id(_, _, _), do: nil

  defp maybe_create_category(slug, language) when is_binary(slug) and slug != "" do
    # First check if category already exists (using localized slug search)
    case Shop.get_category_by_slug_localized(slug, language) do
      {:ok, %{uuid: uuid}} ->
        # Category exists, return its uuid
        uuid

      {:error, :not_found} ->
        # Category doesn't exist - create it
        create_new_category(slug, language)
    end
  end

  defp create_new_category(slug, language) do
    # Normalize language to dialect format (e.g., "en" -> "en-US")
    # to match how SlugResolver queries slug JSONB fields
    normalized_lang = SlugResolver.normalize_language_public(language)

    # Generate name from slug: "vases-planters" -> "Vases Planters"
    name =
      slug
      |> String.replace("-", " ")
      |> String.split(" ")
      |> Enum.map_join(" ", &String.capitalize/1)

    # Create localized attributes with normalized language key
    attrs = %{
      name: %{normalized_lang => name},
      slug: %{normalized_lang => slug},
      status: "active"
    }

    case Shop.create_category(attrs) do
      {:ok, category} ->
        Logger.info(
          "Auto-created category: #{slug} (uuid: #{category.uuid}) with language: #{normalized_lang}"
        )

        category.uuid

      {:error, _changeset} ->
        # Unique constraint hit - category was created by concurrent process, fetch it
        case Shop.get_category_by_slug_localized(slug, language) do
          {:ok, %{uuid: uuid}} ->
            Logger.info("Category #{slug} already exists (uuid: #{uuid}), using existing")
            uuid

          {:error, :not_found} ->
            Logger.warning("Failed to create or find category: #{slug}")
            nil
        end
    end
  end

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
        category -> Map.put(categories_map, category_slug, category.uuid)
      end
    end
  end

  def update_categories_map(categories_map, _), do: categories_map

  @doc """
  Transform with extended options support (Option3..N and slot mappings).

  ## Arguments

  - handle: Product handle (slug)
  - rows: List of CSV row maps for this product
  - categories_map: Map of slug => category_id
  - config: Optional ImportConfig for category rules and option mappings
  - opts: Keyword options:
    - `:language` - Target language for imported content
    - `:option_mappings` - Explicit option mappings (overrides config)

  ## Returns

  Map suitable for `Shop.create_product/1` with slot-based metadata if mappings provided.
  """
  def transform_extended(handle, rows, categories_map \\ %{}, config \\ nil, opts \\ []) do
    first_row = List.first(rows)

    # Get option mappings from opts or config
    option_mappings = get_option_mappings(config, opts)

    # Build extended options with mappings support
    options = OptionBuilder.build_extended(rows, option_mappings: option_mappings)

    # Get target language for localized fields
    language = Keyword.get(opts, :language, Translations.default_language())

    # Determine category using config or legacy defaults
    title = first_row["Title"] || ""
    category_slug = Filter.categorize(title, config)

    # Get category_uuid, auto-creating if necessary (with localized name/slug)
    category_uuid = resolve_category_id(category_slug, categories_map, language)

    # Build metadata with slot-based option structure
    metadata = build_metadata_extended(options)

    # Extract non-localized values
    body_html_raw = first_row["Body (HTML)"]
    description_raw = extract_description(body_html_raw)
    seo_title_raw = get_non_empty(first_row, "SEO Title")
    seo_description_raw = get_non_empty(first_row, "SEO Description")

    %{
      # Localized fields - stored as maps with language key
      slug: localized_map(handle, language),
      title: localized_map(title, language),
      body_html: localized_map(body_html_raw, language),
      description: localized_map(description_raw, language),
      seo_title: localized_map(seo_title_raw, language),
      seo_description: localized_map(seo_description_raw, language),
      # Non-localized fields
      vendor: get_non_empty(first_row, "Vendor"),
      tags: parse_tags(first_row["Tags"]),
      status: parse_status(first_row["Published"]),
      price: options.base_price,
      product_type: "physical",
      requires_shipping: true,
      taxable: true,
      featured_image: find_featured_image(rows),
      images: collect_images(rows),
      category_uuid: category_uuid,
      metadata: metadata
    }
  end

  # Get option mappings from config or opts
  defp get_option_mappings(config, opts) do
    explicit_mappings = Keyword.get(opts, :option_mappings)

    cond do
      is_list(explicit_mappings) and explicit_mappings != [] ->
        explicit_mappings

      config != nil and is_list(config.option_mappings) ->
        config.option_mappings

      true ->
        []
    end
  end

  # Build metadata from extended options data
  defp build_metadata_extended(%{options: options, option_slots: option_slots}) do
    result = %{}

    # Build _option_values from all options
    option_values =
      options
      |> Enum.filter(fn opt -> opt.values != [] end)
      |> Enum.reduce(%{}, fn opt, acc ->
        key = normalize_key(opt.name)
        Map.put(acc, key, opt.values)
      end)

    result =
      if option_values != %{} do
        Map.put(result, "_option_values", option_values)
      else
        result
      end

    # Build _price_modifiers from options that have modifiers
    price_modifiers =
      options
      |> Enum.filter(fn opt -> opt.modifiers != %{} end)
      |> Enum.reduce(%{}, fn opt, acc ->
        key = normalize_key(opt.name)
        Map.put(acc, key, opt.modifiers)
      end)

    result =
      if price_modifiers != %{} do
        Map.put(result, "_price_modifiers", price_modifiers)
      else
        result
      end

    # Build _option_slots from slot mappings
    slots =
      option_slots
      |> Enum.map(fn slot ->
        %{
          "slot" => slot.slot,
          "source_key" => slot.source_key,
          "label" => slot.label
        }
      end)

    result =
      if slots != [] do
        # Also update _option_values to use slot keys instead of CSV names
        slot_option_values =
          option_slots
          |> Enum.filter(fn slot -> slot.values != [] end)
          |> Enum.reduce(%{}, fn slot, acc ->
            Map.put(acc, slot.slot, slot.values)
          end)

        result
        |> Map.put("_option_slots", slots)
        |> Map.update("_option_values", slot_option_values, fn existing ->
          Map.merge(existing, slot_option_values)
        end)
      else
        result
      end

    result
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
