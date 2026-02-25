defmodule PhoenixKit.Modules.Sitemap.Sources.Shop do
  @moduledoc """
  Shop source for sitemap generation.

  Collects catalog page, active category pages, and active product pages
  from the PhoenixKit Shop module for inclusion in the sitemap.

  ## URL Structure

  - Catalog: `/shop` (or `/et/shop` for non-default language)
  - Categories: `/shop/category/:slug` (or `/et/shop/category/:slug`)
  - Products: `/shop/product/:slug` (or `/et/shop/product/:slug`)

  ## Excluded URLs

  - `/cart` — user-specific
  - `/checkout` — user-specific
  - `/checkout/complete/:uuid` — user-specific

  ## Enabling

  This source is enabled when:
  1. Shop module is enabled (`shop_enabled` setting)
  2. Shop sitemap inclusion is enabled (`sitemap_include_shop` setting, default: true)

  ## Sitemap Properties

  - Catalog page: priority 0.8, changefreq "daily", category "Shop"
  - Categories: priority 0.7, changefreq "weekly", category "Shop > Categories"
  - Products: priority 0.8, changefreq "weekly", category "Shop > Products"
  """

  @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Sitemap.UrlEntry
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # Future: Hook into Shop.create_product/update_product to invalidate sitemap-shop

  @impl true
  def source_name, do: :shop

  @impl true
  def sitemap_filename, do: "sitemap-shop"

  @impl true
  def enabled? do
    Shop.enabled?() and
      Settings.get_boolean_setting("sitemap_include_shop", true)
  rescue
    _ -> false
  end

  @impl true
  def collect(opts \\ []) do
    if enabled?() do
      do_collect(opts)
    else
      []
    end
  rescue
    error ->
      Logger.warning("Shop sitemap source failed to collect: #{inspect(error)}")
      []
  end

  defp do_collect(opts) do
    base_url = Keyword.get(opts, :base_url)
    language = Keyword.get(opts, :language, default_language())
    is_default = Keyword.get(opts, :is_default_language, true)

    catalog_entries(base_url, language, is_default) ++
      category_entries(base_url, language, is_default) ++
      product_entries(base_url, language, is_default)
  end

  # Catalog page entry (/shop)
  defp catalog_entries(base_url, language, is_default) do
    canonical_path = "/shop"
    url = build_url(Shop.catalog_url(language), base_url)

    [
      UrlEntry.new(%{
        loc: url,
        lastmod: nil,
        changefreq: "daily",
        priority: 0.8,
        title: "Shop",
        category: "Shop",
        source: :shop,
        canonical_path: build_canonical(canonical_path, language, is_default)
      })
    ]
  end

  # Active category entries (/shop/category/:slug)
  # Includes categories with fallback slugs from other languages
  # Excludes categories with no active products (all archived/draft)
  defp category_entries(base_url, language, is_default) do
    # Pre-compute set of category IDs that have at least one active product
    categories_with_products = active_product_category_ids()

    Shop.list_active_categories()
    |> Enum.filter(fn cat ->
      has_any_slug?(cat) and MapSet.member?(categories_with_products, cat.id)
    end)
    |> Enum.map(fn category ->
      # Use current language if slug exists, otherwise fallback to best available
      effective_lang =
        if has_slug?(category, language), do: language, else: best_available_language(category)

      url = build_url(Shop.category_url(category, effective_lang), base_url)
      canonical_path = "/shop/category/#{category_canonical_slug(category)}"

      UrlEntry.new(%{
        loc: url,
        lastmod: category.updated_at,
        changefreq: "weekly",
        priority: 0.7,
        title: category_name(category, language),
        category: "Shop > Categories",
        source: :shop,
        canonical_path: build_canonical(canonical_path, language, is_default)
      })
    end)
  rescue
    error ->
      Logger.warning("Failed to collect shop categories: #{inspect(error)}")
      []
  end

  # Active product entries (/shop/product/:slug)
  # Includes products with fallback slugs from other languages
  # Excludes products in hidden categories (inaccessible to users)
  defp product_entries(base_url, language, is_default) do
    Shop.list_products(status: "active", exclude_hidden_categories: true)
    |> Enum.filter(&has_any_slug?/1)
    |> Enum.map(fn product ->
      # Use current language if slug exists, otherwise fallback to best available
      effective_lang =
        if has_slug?(product, language), do: language, else: best_available_language(product)

      url = build_url(Shop.product_url(product, effective_lang), base_url)
      canonical_path = "/shop/product/#{product_canonical_slug(product)}"

      UrlEntry.new(%{
        loc: url,
        lastmod: product.updated_at,
        changefreq: "weekly",
        priority: 0.8,
        title: product_title(product, language),
        category: "Shop > Products",
        source: :shop,
        canonical_path: build_canonical(canonical_path, language, is_default)
      })
    end)
  rescue
    error ->
      Logger.warning("Failed to collect shop products: #{inspect(error)}")
      []
  end

  # Extract display name from localized category name map
  defp category_name(category, language) do
    case category.name do
      %{} = names ->
        dialect = Languages.DialectMapper.base_to_dialect(language)
        Map.get(names, language) || Map.get(names, dialect) || first_value(names)

      name when is_binary(name) ->
        name

      _ ->
        "Category"
    end
  end

  # Extract display title from localized product title map
  defp product_title(product, language) do
    case product.title do
      %{} = titles ->
        dialect = Languages.DialectMapper.base_to_dialect(language)
        Map.get(titles, language) || Map.get(titles, dialect) || first_value(titles)

      title when is_binary(title) ->
        title

      _ ->
        "Product"
    end
  end

  # Get canonical slug (default language or first available) for canonical_path.
  # Slug field is always a map (localized slugs) or nil.
  defp category_canonical_slug(category) do
    case category.slug do
      %{} = slugs ->
        default = default_language()
        dialect = Languages.DialectMapper.base_to_dialect(default)

        Map.get(slugs, default) || Map.get(slugs, dialect) || first_value(slugs) ||
          to_string(category.uuid)

      _ ->
        to_string(category.uuid)
    end
  end

  defp product_canonical_slug(product) do
    case product.slug do
      %{} = slugs ->
        default = default_language()
        dialect = Languages.DialectMapper.base_to_dialect(default)

        Map.get(slugs, default) || Map.get(slugs, dialect) || first_value(slugs) ||
          to_string(product.uuid)

      _ ->
        to_string(product.uuid)
    end
  end

  # Check if entity has a slug for the given language (base code, dialect, or raw key)
  defp has_slug?(entity, language) do
    slug_map = entity.slug || %{}
    base = Languages.DialectMapper.extract_base(language)
    dialect = Languages.DialectMapper.base_to_dialect(language)

    Map.has_key?(slug_map, language) or
      Map.has_key?(slug_map, base) or
      Map.has_key?(slug_map, dialect)
  end

  # Check if entity has any slug at all (in any language)
  defp has_any_slug?(entity) do
    case entity.slug do
      %{} = slugs when map_size(slugs) > 0 -> true
      _ -> false
    end
  end

  # Find the best available language for an entity's slug.
  # Prefers content default, then Routes default, then first available.
  defp best_available_language(entity) do
    slug_map = entity.slug || %{}
    content_default = default_language()
    routes_default = Routes.get_default_admin_locale()
    dialect_routes = Languages.DialectMapper.base_to_dialect(routes_default)

    cond do
      Map.has_key?(slug_map, content_default) -> content_default
      Map.has_key?(slug_map, routes_default) -> routes_default
      Map.has_key?(slug_map, dialect_routes) -> dialect_routes
      true -> slug_map |> Map.keys() |> List.first()
    end
  end

  # Returns a MapSet of category IDs that have at least one active product.
  # Used to exclude empty categories (all products archived/draft) from sitemap.
  defp active_product_category_ids do
    Shop.list_products(status: "active", exclude_hidden_categories: true)
    |> Enum.map(& &1.category_uuid)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp first_value(map) when map_size(map) > 0 do
    map |> Map.values() |> List.first()
  end

  defp first_value(_), do: nil

  # Build canonical path only for default language entries (used for hreflang grouping)
  defp build_canonical(path, _language, true), do: path
  defp build_canonical(path, _language, _is_default), do: path

  defp default_language do
    if Languages.enabled?() do
      case Languages.get_default_language() do
        %{code: code} -> Languages.DialectMapper.extract_base(code)
        _ -> "en"
      end
    else
      "en"
    end
  rescue
    _ -> "en"
  end

  # Build full URL: if the path from Shop.*_url already includes the base,
  # just return it; otherwise prepend base_url
  defp build_url(path, nil) do
    base = Settings.get_setting("site_url", "")
    normalized_base = String.trim_trailing(base, "/")
    "#{normalized_base}#{path}"
  end

  defp build_url(path, base_url) when is_binary(base_url) do
    normalized_base = String.trim_trailing(base_url, "/")
    "#{normalized_base}#{path}"
  end
end
