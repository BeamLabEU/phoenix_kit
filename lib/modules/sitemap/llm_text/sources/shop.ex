defmodule PhoenixKit.Modules.Sitemap.LLMText.Sources.Shop do
  @moduledoc """
  LLM text source for PhoenixKit Ecommerce/Shop module.

  Provides:
  - Index entries (categories and products) for llms.txt
  - On-the-fly markdown content per product via serve_page/2

  Only active when the PhoenixKitEcommerce module is loaded and enabled.
  """

  @compile {:no_warn_undefined, PhoenixKitEcommerce}
  @compile {:no_warn_undefined, PhoenixKit.Modules.Storage.URLSigner}
  @behaviour PhoenixKit.Modules.Sitemap.LLMText.Sources.Source

  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Sitemap.LLMText.Sources.Source
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitEcommerce, as: Shop

  @impl true
  def source_name, do: :shop

  @impl true
  def enabled? do
    Code.ensure_loaded?(PhoenixKitEcommerce) and Shop.enabled?()
  rescue
    _ -> false
  end

  @impl true
  def collect_index_entries(language) do
    if enabled?() do
      lang = language || get_default_language()
      category_entries(lang) ++ product_entries(lang)
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "Sitemap.LLMText ShopSource failed to collect index entries: #{inspect(error)}"
      )

      []
  end

  @impl true
  def serve_page(["shop", "product", filename], language) do
    slug = String.replace_suffix(filename, ".md", "")
    lang = language || get_default_language()

    # Optimization: replace with Shop.get_product_by_slug(slug, lang) when Shop API supports it
    product =
      Shop.list_products(status: "active", exclude_hidden_categories: true)
      |> Enum.find(fn p -> extract_localized(p.slug, lang, "") == slug end)

    case product do
      nil ->
        :not_found

      product ->
        title = extract_localized(product.title, lang, "Product")
        url = build_full_url(Shop.product_url(product, lang))
        description = extract_localized(product.description, lang, "")
        {:ok, build_product_content(title, url, description, product)}
    end
  rescue
    _ -> :not_found
  end

  def serve_page(_, _), do: :not_found

  # Private helpers

  defp category_entries(language) do
    Shop.list_active_categories()
    |> Enum.map(fn category ->
      title = extract_localized(category.name, language, "Category")
      url = build_full_url(Shop.category_url(category, language))

      %{
        title: title,
        url: url,
        description: "",
        group: "Shop — Categories"
      }
    end)
  rescue
    error ->
      Logger.warning("ShopSource failed to collect categories: #{inspect(error)}")
      []
  end

  defp product_entries(language) do
    Shop.list_products(status: "active", exclude_hidden_categories: true)
    |> Enum.map(fn product ->
      title = extract_localized(product.title, language, "Product")
      slug = extract_localized(product.slug, language, "product")
      url = build_full_url("/llms/#{language}/shop/product/#{slug}.md")
      raw_desc = extract_localized(product.description, language, "")
      description = raw_desc |> Source.strip_markdown() |> String.slice(0, 200)

      %{
        title: title,
        url: url,
        description: description,
        group: "Shop — Products"
      }
    end)
  rescue
    error ->
      Logger.warning("ShopSource failed to collect products: #{inspect(error)}")
      []
  end

  @doc """
  Extracts a localized value from a map or returns the value if it's already a string.
  Falls back to the first available value, then to the default.

      iex> extract_localized(%{"en" => "hello", "et" => "tere"}, "en", "fallback")
      "hello"
      iex> extract_localized(%{"et" => "tere"}, "en", "fallback")
      "tere"
      iex> extract_localized("plain string", "en", "fallback")
      "plain string"
      iex> extract_localized(nil, "en", "fallback")
      "fallback"
  """
  @spec extract_localized(map() | String.t() | nil, String.t() | nil, String.t()) :: String.t()
  def extract_localized(value, language, default) do
    case value do
      %{} = map when map_size(map) > 0 ->
        language = language || "en"

        Map.get(map, language) ||
          Map.get(map, String.slice(language, 0, 2)) ||
          first_map_value(map) ||
          default

      str when is_binary(str) and str != "" ->
        str

      _ ->
        default
    end
  end

  defp first_map_value(map) do
    map |> Map.values() |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  defp build_product_content(title, url, description, product) do
    url_line = if url != "", do: "> Source: #{url}\n\n", else: ""
    desc_line = if description != "", do: "#{description}\n\n", else: ""
    images_section = build_images_section(title, product)
    "# #{Source.strip_markdown(title)}\n\n#{url_line}#{desc_line}#{images_section}"
  end

  defp build_images_section(title, product) do
    featured = Map.get(product, :featured_image_uuid)
    extras = Map.get(product, :image_uuids, []) || []
    site_url = get_site_url()

    image_uuids =
      [featured | extras]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()
      |> Enum.take(5)

    if image_uuids == [] or not Code.ensure_loaded?(URLSigner) do
      ""
    else
      image_uuids
      |> Enum.map(fn uuid ->
        relative = URLSigner.signed_url(uuid, "medium")
        absolute = String.trim_trailing(site_url, "/") <> relative
        "![#{title}](#{absolute})"
      end)
      |> case do
        [] -> ""
        lines -> Enum.join(lines, "\n") <> "\n\n"
      end
    end
  rescue
    _ -> ""
  end

  defp build_full_url(path) do
    site_url = get_site_url()

    if site_url != "" do
      String.trim_trailing(site_url, "/") <> path
    else
      path
    end
  end

  defp get_default_language do
    if Code.ensure_loaded?(Languages) and Languages.enabled?() do
      case Languages.get_default_language() do
        %{code: code} -> code
        _ -> "en"
      end
    else
      "en"
    end
  rescue
    _ -> "en"
  end

  defp get_site_url do
    PhoenixKit.Settings.get_setting("site_url", "")
  rescue
    _ -> ""
  end
end
