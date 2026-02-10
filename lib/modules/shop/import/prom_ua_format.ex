defmodule PhoenixKit.Modules.Shop.Import.PromUaFormat do
  @moduledoc """
  Prom.ua CSV format adapter implementing `ImportFormat` behaviour.

  Handles the Prom.ua export format:
  - One row = one product (no variant grouping)
  - Bilingual: Russian + Ukrainian titles/descriptions
  - Multiple images comma-separated in a single column
  - Ukrainian column names
  - Category by name (`Назва_групи`)
  - Prices in UAH
  """

  @behaviour PhoenixKit.Modules.Shop.Import.ImportFormat

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Translations

  require Logger

  # Prom.ua CSVs use comma separator (standard CSV)
  NimbleCSV.define(PromUaCSV, separator: ",", escape: "\"")

  @marker_columns ["Назва_позиції", "Ціна", "Номер_групи"]

  @impl true
  def detect?(headers) do
    header_set = MapSet.new(headers)
    Enum.all?(@marker_columns, &MapSet.member?(header_set, &1))
  end

  @impl true
  def requires_option_mapping?, do: false

  @impl true
  def count(path, _config) do
    parse_rows(path) |> length()
  end

  @impl true
  def parse_and_transform(path, categories_map, _config, _opts) do
    parse_rows(path)
    |> Enum.map(fn row -> transform_row(row, categories_map) end)
  end

  @impl true
  def default_config_attrs do
    %{
      name: "prom_ua_default",
      skip_filter: true,
      category_rules: [],
      required_columns: ["Назва_позиції", "Ціна"],
      is_default: false,
      active: true,
      download_images: true,
      include_keywords: [],
      exclude_keywords: [],
      exclude_phrases: [],
      option_mappings: []
    }
  end

  # ============================================
  # PARSING
  # ============================================

  defp parse_rows(path) do
    {headers, rows} =
      path
      |> File.stream!([:utf8])
      |> PromUaCSV.parse_stream(skip_headers: false)
      |> Enum.reduce({nil, []}, fn
        row, {nil, []} ->
          {row, []}

        row, {headers, acc} ->
          # Pad row to match header length (handles short rows)
          padded = pad_row(row, length(headers))
          row_map = Enum.zip(headers, padded) |> Map.new()
          {headers, [row_map | acc]}
      end)

    if headers == nil do
      []
    else
      rows
      |> Enum.reverse()
      |> Enum.filter(fn row ->
        name = row["Назва_позиції"] || ""
        String.trim(name) != ""
      end)
    end
  end

  defp pad_row(row, target_length) when length(row) >= target_length, do: row

  defp pad_row(row, target_length) do
    row ++ List.duplicate("", target_length - length(row))
  end

  # ============================================
  # TRANSFORMATION
  # ============================================

  defp transform_row(row, categories_map) do
    slug = extract_slug(row)
    category_id = resolve_category(row, categories_map)
    {price, compare_at_price} = parse_price_and_discount(row)
    image_urls = parse_image_urls(row["Посилання_зображення"])
    images = Enum.map(image_urls, fn url -> %{"src" => url} end)

    %{
      slug: bilingual_map(slug),
      title:
        localized_map(
          non_empty(row["Назва_позиції"]) || "",
          non_empty(row["Назва_позиції_укр"]) || ""
        ),
      body_html: localized_map(row["Опис"] || "", row["Опис_укр"] || ""),
      description:
        localized_map(extract_description(row["Опис"]), extract_description(row["Опис_укр"])),
      seo_title:
        localized_map(
          non_empty(row["HTML_заголовок"]) || "",
          non_empty(row["HTML_заголовок_укр"]) || ""
        ),
      seo_description:
        localized_map(non_empty(row["HTML_опис"]) || "", non_empty(row["HTML_опис_укр"]) || ""),
      vendor: non_empty(row["Виробник"]),
      tags: parse_tags(row["Пошукові_запити"]),
      status: parse_availability(row["Наявність"]),
      price: price,
      compare_at_price: compare_at_price,
      product_type: "physical",
      requires_shipping: true,
      taxable: true,
      featured_image: List.first(image_urls),
      images: images,
      category_id: category_id,
      weight_grams: parse_weight(row["Вага,кг"]),
      metadata: build_metadata(row)
    }
  end

  # ============================================
  # SLUG
  # ============================================

  defp extract_slug(row) do
    url = row["Продукт_на_сайті"] || ""

    slug =
      case Regex.run(~r|/p\d+-(.+?)\.html|, url) do
        [_, slug_part] -> slug_part
        _ -> nil
      end

    slug = slug || fallback_slug(row)
    slug
  end

  defp fallback_slug(row) do
    uid = non_empty(row["Унікальний_ідентифікатор"])

    if uid do
      "prom-#{uid}"
    else
      # Last resort: generate from product name
      name = row["Назва_позиції"] || "product"

      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.slice(0, 60)
    end
  end

  defp bilingual_map(value) do
    default_lang = Translations.default_language()

    %{"ru" => value, "uk" => value}
    |> maybe_put_default_lang(default_lang, value)
  end

  # Ensure the system's default language key is always present in localized maps.
  # Uses the Russian value as fallback for the default language.
  defp localized_map(ru_value, uk_value) do
    default_lang = Translations.default_language()

    %{"ru" => ru_value, "uk" => uk_value}
    |> maybe_put_default_lang(default_lang, ru_value)
  end

  defp maybe_put_default_lang(map, lang, _fallback) when lang in ["ru", "uk"], do: map
  defp maybe_put_default_lang(map, lang, fallback), do: Map.put_new(map, lang, fallback)

  # ============================================
  # CATEGORY
  # ============================================

  defp resolve_category(row, categories_map) do
    group_name = non_empty(row["Назва_групи"])
    group_number = non_empty(row["Номер_групи"])

    if group_name do
      # Build a slug from the group number for lookup
      category_slug = if group_number, do: "group-#{group_number}", else: slugify(group_name)

      case Map.get(categories_map, category_slug) do
        nil ->
          # Auto-create category with ru name and generated slug
          maybe_create_prom_category(group_name, category_slug)

        category_id ->
          category_id
      end
    else
      nil
    end
  end

  defp maybe_create_prom_category(group_name, slug) do
    lang = Translations.default_language()

    case Shop.get_category_by_slug_localized(slug, lang) do
      {:ok, %{id: id}} ->
        id

      {:error, :not_found} ->
        attrs = %{
          name: localized_map(group_name, group_name),
          slug: localized_map(slug, slug),
          status: "active"
        }

        case Shop.create_category(attrs) do
          {:ok, category} ->
            Logger.info("Auto-created Prom.ua category: #{slug} (#{group_name})")
            category.id

          {:error, changeset} ->
            Logger.warning("Failed to create category #{slug}: #{inspect(changeset.errors)}")
            nil
        end
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-zа-яёіїєґ0-9\s-]/u, "")
    |> String.replace(~r/\s+/, "-")
    |> String.slice(0, 80)
  end

  # ============================================
  # PRICE & DISCOUNT
  # ============================================

  defp parse_price_and_discount(row) do
    price_str = row["Ціна"] || "0"
    discount_str = row["Знижка"] || ""

    price =
      case Decimal.parse(String.trim(price_str)) do
        {decimal, _} -> decimal
        :error -> Decimal.new(0)
      end

    compare_at_price = calculate_compare_at_price(price, String.trim(discount_str))

    {price, compare_at_price}
  end

  defp calculate_compare_at_price(_price, ""), do: nil

  defp calculate_compare_at_price(price, discount_str) do
    if String.ends_with?(discount_str, "%") do
      # Percentage discount: "10%", "15%", "20%"
      percent_str = String.trim_trailing(discount_str, "%")

      case Decimal.parse(percent_str) do
        {percent, _} ->
          divisor = Decimal.sub(Decimal.new(1), Decimal.div(percent, Decimal.new(100)))

          if Decimal.gt?(divisor, Decimal.new(0)) do
            Decimal.div(price, divisor) |> Decimal.round(2)
          else
            nil
          end

        :error ->
          nil
      end
    else
      # Absolute discount: "1550.00", "360.00"
      case Decimal.parse(discount_str) do
        {absolute_discount, _} ->
          if Decimal.gt?(absolute_discount, Decimal.new(0)) do
            Decimal.add(price, absolute_discount)
          else
            nil
          end

        :error ->
          nil
      end
    end
  end

  # ============================================
  # IMAGES
  # ============================================

  defp parse_image_urls(nil), do: []
  defp parse_image_urls(""), do: []

  defp parse_image_urls(urls_string) do
    urls_string
    |> String.split(", ")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # ============================================
  # AVAILABILITY
  # ============================================

  defp parse_availability(nil), do: "draft"
  defp parse_availability(""), do: "draft"

  defp parse_availability(value) do
    trimmed = String.trim(value)

    cond do
      trimmed in ["+", "!", "@"] -> "active"
      trimmed == "-" || trimmed == "0" -> "draft"
      # Numeric values > 0 mean in stock
      match?({n, ""} when n > 0, Integer.parse(trimmed)) -> "active"
      true -> "draft"
    end
  end

  # ============================================
  # WEIGHT
  # ============================================

  defp parse_weight(nil), do: nil
  defp parse_weight(""), do: nil

  defp parse_weight(kg_str) do
    case Float.parse(String.trim(kg_str)) do
      {kg, _} -> round(kg * 1000)
      :error -> nil
    end
  end

  # ============================================
  # TAGS
  # ============================================

  defp parse_tags(nil), do: []
  defp parse_tags(""), do: []

  defp parse_tags(tags_str) do
    tags_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # ============================================
  # DESCRIPTION
  # ============================================

  defp extract_description(nil), do: ""
  defp extract_description(""), do: ""

  defp extract_description(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&[a-z]+;/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 500)
  end

  # ============================================
  # METADATA
  # ============================================

  defp build_metadata(row) do
    metadata = %{}

    metadata = put_if_present(metadata, "sku", row["Код_товару"])
    metadata = put_if_present(metadata, "prom_id", row["Ідентифікатор_товару"])
    metadata = put_if_present(metadata, "prom_uid", row["Унікальний_ідентифікатор"])
    metadata = put_if_present(metadata, "country", row["Країна_виробник"])
    metadata = put_if_present(metadata, "currency", row["Валюта"])
    metadata = put_if_present(metadata, "group_id", row["Номер_групи"])

    metadata
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, String.trim(value))

  # ============================================
  # HELPERS
  # ============================================

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value), do: String.trim(value)
end
