defmodule PhoenixKit.Modules.Shop.Import.Filter do
  @moduledoc """
  Filter products for import (3D printed only, exclude decals).

  Inclusion keywords: 3D, printed, shelf, mask, vase, holder, stand, lamp, figurine, etc.
  Exclusion keywords: decal, sticker, wall art, poster, etc.
  """

  @include_keywords ~w(3d printed shelf mask vase planter holder stand lamp light figurine sculpture statue)
  @exclude_keywords ~w(decal sticker mural wallpaper poster tapestry canvas)
  @exclude_phrases ["wall art"]

  # Category rules: list of {keywords, category_slug}
  # First match wins, order matters
  @category_rules [
    {["shelf"], "shelves"},
    {["mask"], "masks"},
    {["vase", "planter"], "vases-planters"},
    {["holder", "stand"], "holders-stands"},
    {["lamp", "light"], "lamps"},
    {["figurine", "sculpture", "statue"], "figurines"}
  ]

  @doc """
  Check if product should be included in import.

  Returns true if:
  - Title matches at least one include pattern
  - Title does NOT match any exclude pattern

  ## Examples

      Filter.should_include?([%{"Title" => "3D Printed Cat Shelf", ...}])
      # => true

      Filter.should_include?([%{"Title" => "Cat Wall Decal Sticker", ...}])
      # => false
  """
  def should_include?(rows) when is_list(rows) do
    first_row = List.first(rows)
    title = first_row["Title"] || ""
    handle = first_row["Handle"] || ""

    # Skip special handles
    if skip_handle?(handle) do
      false
    else
      has_include_match?(title) and not has_exclude_match?(title)
    end
  end

  @doc """
  Categorize product based on title keywords.

  Returns category slug or "other-3d" if can't determine.
  """
  def categorize(title) when is_binary(title) do
    title_lower = String.downcase(title)
    find_category(title_lower) || "other-3d"
  end

  defp find_category(title_lower) do
    Enum.find_value(@category_rules, fn {keywords, category} ->
      if Enum.any?(keywords, &String.contains?(title_lower, &1)) do
        category
      end
    end)
  end

  # Private helpers

  defp has_include_match?(title) do
    title_lower = String.downcase(title)
    Enum.any?(@include_keywords, &String.contains?(title_lower, &1))
  end

  defp has_exclude_match?(title) do
    title_lower = String.downcase(title)

    has_keyword = Enum.any?(@exclude_keywords, &String.contains?(title_lower, &1))
    has_phrase = Enum.any?(@exclude_phrases, &String.contains?(title_lower, &1))

    has_keyword or has_phrase
  end

  defp skip_handle?(handle) do
    handle_lower = String.downcase(handle)

    String.contains?(handle_lower, "shipping") or
      String.contains?(handle_lower, "payment") or
      String.contains?(handle_lower, "gift-card") or
      String.contains?(handle_lower, "custom-order")
  end
end
