defmodule PhoenixKit.Modules.Shop.Import.Filter do
  @moduledoc """
  Filter products for import based on configurable rules.

  Supports both legacy hardcoded keywords (for backward compatibility)
  and configurable ImportConfig-based filtering.

  ## Configuration-based filtering

      config = Shop.get_default_import_config()
      Filter.should_include?(rows, config)
      Filter.categorize(title, config)

  ## Legacy filtering (backward compatible)

      Filter.should_include?(rows)  # Uses hardcoded defaults
      Filter.categorize(title)      # Uses hardcoded defaults
  """

  alias PhoenixKit.Modules.Shop.ImportConfig

  # Legacy hardcoded defaults for backward compatibility
  @default_include_keywords ~w(3d printed shelf mask vase planter holder stand lamp light figurine sculpture statue)
  @default_exclude_keywords ~w(decal sticker mural wallpaper poster tapestry canvas)
  @default_exclude_phrases ["wall art"]

  @default_category_rules [
    {["shelf"], "shelves"},
    {["mask"], "masks"},
    {["vase", "planter"], "vases-planters"},
    {["holder", "stand"], "holders-stands"},
    {["lamp", "light"], "lamps"},
    {["figurine", "sculpture", "statue"], "figurines"}
  ]

  @default_category_slug "other-3d"

  # ============================================
  # SHOULD_INCLUDE? FUNCTIONS
  # ============================================

  @doc """
  Check if product should be included in import.

  ## With config

      Filter.should_include?(rows, config)

  Returns true if:
  - Config has `skip_filter: true`, OR
  - Title matches at least one include keyword AND
  - Title does NOT match any exclude keyword/phrase

  ## Without config (legacy)

      Filter.should_include?(rows)

  Uses hardcoded default keywords for backward compatibility.
  """
  def should_include?(rows, config \\ nil)

  def should_include?(rows, %ImportConfig{skip_filter: true}) when is_list(rows), do: true

  def should_include?(rows, %ImportConfig{} = config) when is_list(rows) do
    first_row = List.first(rows)
    title = first_row["Title"] || ""
    handle = first_row["Handle"] || ""

    if skip_handle?(handle) do
      false
    else
      has_include_match?(title, config) and not has_exclude_match?(title, config)
    end
  end

  def should_include?(rows, nil) when is_list(rows) do
    # Legacy behavior: use hardcoded defaults
    first_row = List.first(rows)
    title = first_row["Title"] || ""
    handle = first_row["Handle"] || ""

    if skip_handle?(handle) do
      false
    else
      has_include_match_legacy?(title) and not has_exclude_match_legacy?(title)
    end
  end

  # ============================================
  # CATEGORIZE FUNCTIONS
  # ============================================

  @doc """
  Categorize product based on title keywords.

  ## With config

      Filter.categorize(title, config)

  Uses category_rules from config. Returns default_category_slug if no match.

  ## Without config (legacy)

      Filter.categorize(title)

  Uses hardcoded category rules. Returns "other-3d" if no match.
  """
  def categorize(title, config \\ nil)

  def categorize(title, %ImportConfig{} = config) when is_binary(title) do
    title_lower = String.downcase(title)

    find_category_from_config(title_lower, config) || config.default_category_slug ||
      @default_category_slug
  end

  def categorize(title, nil) when is_binary(title) do
    # Legacy behavior
    title_lower = String.downcase(title)
    find_category_legacy(title_lower) || @default_category_slug
  end

  # ============================================
  # CONFIG-BASED HELPERS
  # ============================================

  defp has_include_match?(title, %ImportConfig{include_keywords: keywords}) do
    if keywords == [] do
      # No include keywords = include everything
      true
    else
      title_lower = String.downcase(title)
      Enum.any?(keywords, &String.contains?(title_lower, String.downcase(&1)))
    end
  end

  defp has_exclude_match?(title, %ImportConfig{
         exclude_keywords: keywords,
         exclude_phrases: phrases
       }) do
    title_lower = String.downcase(title)

    has_keyword = Enum.any?(keywords || [], &String.contains?(title_lower, String.downcase(&1)))
    has_phrase = Enum.any?(phrases || [], &String.contains?(title_lower, String.downcase(&1)))

    has_keyword or has_phrase
  end

  defp find_category_from_config(title_lower, %ImportConfig{category_rules: rules})
       when is_list(rules) do
    Enum.find_value(rules, fn rule ->
      keywords = rule["keywords"] || rule[:keywords] || []
      slug = rule["slug"] || rule[:slug]

      if Enum.any?(keywords, fn kw -> String.contains?(title_lower, String.downcase(kw)) end) do
        slug
      end
    end)
  end

  defp find_category_from_config(_title_lower, _config), do: nil

  # ============================================
  # LEGACY HELPERS (backward compatibility)
  # ============================================

  defp has_include_match_legacy?(title) do
    title_lower = String.downcase(title)
    Enum.any?(@default_include_keywords, &String.contains?(title_lower, &1))
  end

  defp has_exclude_match_legacy?(title) do
    title_lower = String.downcase(title)

    has_keyword = Enum.any?(@default_exclude_keywords, &String.contains?(title_lower, &1))
    has_phrase = Enum.any?(@default_exclude_phrases, &String.contains?(title_lower, &1))

    has_keyword or has_phrase
  end

  defp find_category_legacy(title_lower) do
    Enum.find_value(@default_category_rules, fn {keywords, category} ->
      if Enum.any?(keywords, &String.contains?(title_lower, &1)) do
        category
      end
    end)
  end

  # ============================================
  # SHARED HELPERS
  # ============================================

  defp skip_handle?(handle) do
    handle_lower = String.downcase(handle)

    String.contains?(handle_lower, "shipping") or
      String.contains?(handle_lower, "payment") or
      String.contains?(handle_lower, "gift-card") or
      String.contains?(handle_lower, "custom-order")
  end
end
