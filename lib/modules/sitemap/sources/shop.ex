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
  defp category_entries(base_url, language, is_default) do
    Shop.list_active_categories()
    |> Enum.filter(&has_slug?(&1, language))
    |> Enum.map(fn category ->
      url = build_url(Shop.category_url(category, language), base_url)
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
  defp product_entries(base_url, language, is_default) do
    Shop.list_products(status: "active")
    |> Enum.filter(&has_slug?(&1, language))
    |> Enum.map(fn product ->
      url = build_url(Shop.product_url(product, language), base_url)
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
          to_string(category.id)

      _ ->
        to_string(category.id)
    end
  end

  defp product_canonical_slug(product) do
    case product.slug do
      %{} = slugs ->
        default = default_language()
        dialect = Languages.DialectMapper.base_to_dialect(default)

        Map.get(slugs, default) || Map.get(slugs, dialect) || first_value(slugs) ||
          to_string(product.id)

      _ ->
        to_string(product.id)
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
        %{"code" => code} -> Languages.DialectMapper.extract_base(code)
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
