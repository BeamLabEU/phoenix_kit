defmodule PhoenixKit.Modules.Shared.Components.ImageSet do
  @moduledoc """
  Responsive image component that renders a `<picture>` element with `<source>` tags.

  The browser automatically picks the best format it supports (AVIF > WebP > JPEG)
  AND the right size for the viewport width, minimizing bandwidth.

  ## Usage

  ### Basic (auto-loads variants from DB):

      <.image_set file_uuid="018e3c4a-..." alt="Photo" />

  ### With pre-loaded variants (for list pages, avoids N+1):

      <.image_set file_uuid="018e3c4a-..." variants={@variants["018e3c4a-..."]} alt="Photo" />

  List pages that pre-load variants should pre-load the alt text too —
  `Storage.translated_alts/2` reads it for every file in one query.

  ### Alt text

  Leave `alt` out and the image gets the file's own alt text, in the language
  the page is rendered in. Pass `alt=""` for a decorative image. With
  pre-loaded `variants` nothing is looked up — the component must not bring
  back the query per image the caller just avoided — so pass `alt` too.

  ### With custom sizes attribute:

      <.image_set file_uuid="018e3c4a-..." alt="Photo" sizes="(max-width: 768px) 100vw, 50vw" />

  ### Cropped tiles (`object-cover`):

      <.image_set file_uuid="018e3c4a-..." alt="" fit="cover" box_aspect={1}
        sizes="(max-width: 768px) 33vw, 160px" class="w-full h-full object-cover" />

  `sizes` describes the slot's width, but a picture cropped to fill the box
  is scaled to whichever side of the box it must cover. A landscape picture
  in a square or portrait tile fills the tile's height, so the variant the
  browser would pick by width alone is too short and gets stretched. With
  `fit="cover"` and `box_aspect` (the box's width ÷ height), each `srcset`
  candidate advertises the width of the box it can fill,
  `min(width, height × box_aspect)`, so a wide picture gets a larger variant
  only when the crop needs it and a portrait one keeps the small file. The
  advertised widths are not the files' own, so the image's natural size
  changes: the box must be sized by CSS (`w-full h-full`), as any cropped
  tile is.

  ## How it works

  1. Groups file variants by format (AVIF, WebP, JPEG, etc.)
  2. Renders a `<source>` per format with `srcset` using width descriptors
  3. Falls back to a standard `<img>` tag with the primary format srcset
  4. Format priority: AVIF > WebP > others (browsers pick the first supported `<source>`)
  """
  use Phoenix.Component

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.VariantNaming

  attr :file_uuid, :string, required: true, doc: "File UUID from PhoenixKit Storage"

  attr :variants, :list,
    default: nil,
    doc: "Pre-loaded variant data from Storage.list_image_set_variants/1"

  attr :alt, :string,
    default: nil,
    doc: "Alt text. Left out, it is the file's own alt text in the page's language"

  attr :sizes, :string, default: "100vw", doc: "Sizes attribute for responsive images"

  attr :fit, :string,
    default: nil,
    values: [nil, "cover"],
    doc: ~s(Set to "cover" when the image fills a cropped box \(`object-cover`\); see box_aspect)

  attr :box_aspect, :any,
    default: 1,
    doc:
      "With fit=\"cover\": the box's width ÷ height (a number, or \"4/5\"); 1 for a square tile"

  attr :class, :string, default: "", doc: "CSS classes for the img element"
  attr :loading, :string, default: "lazy", doc: "Loading strategy: lazy or eager"
  attr :rest, :global

  def image_set(assigns) do
    variants = assigns.variants || load_variants(assigns.file_uuid)

    # Parse variant names and group by format
    grouped = group_variants_by_format(variants, cover_aspect(assigns))

    # Format priority: AVIF first, then WebP, then fallback
    source_formats = prioritize_formats(grouped)
    fallback_variants = Map.get(grouped, nil, [])

    # Pick a good fallback src (prefer medium, then the largest available)
    fallback_src = pick_fallback_src(fallback_variants, variants)

    assigns =
      assigns
      |> assign(:alt, assigns.alt || file_alt(assigns))
      |> assign(:source_formats, source_formats)
      |> assign(:fallback_variants, fallback_variants)
      |> assign(:fallback_src, fallback_src)
      |> assign(:fallback_srcset, build_srcset(fallback_variants))
      |> assign(:has_sources, source_formats != [] or fallback_variants != [])

    ~H"""
    <%= if @has_sources do %>
      <picture>
        <%= for {format, format_variants} <- @source_formats do %>
          <source
            type={VariantNaming.mime_type_for_format(format)}
            srcset={build_srcset(format_variants)}
            sizes={@sizes}
          />
        <% end %>
        <img
          src={@fallback_src}
          srcset={if(@fallback_srcset != "", do: @fallback_srcset)}
          sizes={if(@fallback_srcset != "", do: @sizes)}
          alt={@alt}
          class={@class}
          loading={@loading}
          {@rest}
        />
      </picture>
    <% else %>
      <img
        src={@fallback_src}
        alt={@alt}
        class={@class}
        loading={@loading}
        {@rest}
      />
    <% end %>
    """
  end

  defp file_alt(%{variants: nil, file_uuid: file_uuid}) do
    if Code.ensure_loaded?(Storage) and function_exported?(Storage, :translated_alt_by_uuid, 2) do
      Storage.translated_alt_by_uuid(file_uuid, PhoenixKit.Utils.Multilang.current_locale())
    else
      ""
    end
  rescue
    _ -> ""
  end

  defp file_alt(_assigns), do: ""

  defp load_variants(file_uuid) do
    if Code.ensure_loaded?(Storage) and function_exported?(Storage, :list_image_set_variants, 1) do
      Storage.list_image_set_variants(file_uuid)
    else
      []
    end
  end

  defp group_variants_by_format(variants, cover_aspect) do
    # Group by actual mime_type, not variant name — this way files that failed
    # format conversion (e.g. AVIF without libheif) end up in the correct group.
    variants
    |> Enum.filter(&(&1.width && &1.width > 0))
    |> Enum.reject(&String.starts_with?(&1.variant_name, "video_"))
    |> Enum.map(&cover_width(&1, cover_aspect))
    |> Enum.group_by(&mime_to_format(&1.mime_type))
    |> Enum.map(fn {fmt, vs} ->
      # Deduplicate by width — keep the best variant per width per format
      # (for a cover box, the smallest file that fills a given width: a
      # wider one of the same height covers no more of the box)
      deduped =
        vs
        |> Enum.sort_by(&{&1.width, Map.get(&1, :file_width, &1.width)})
        |> Enum.uniq_by(& &1.width)

      {fmt, deduped}
    end)
    |> Map.new()
  end

  # In a cropped box the picture is scaled to cover it: a variant w × h fills
  # a box at most min(w, h × box_aspect) wide before it is stretched. That is
  # the width its `srcset` descriptor advertises, so the browser's choice by
  # `sizes` (the slot's width) brings a wide picture a variant tall enough.
  defp cover_width(variant, nil), do: variant

  defp cover_width(%{width: w} = variant, aspect) do
    case Map.get(variant, :height) do
      h when is_integer(h) and h > 0 ->
        # rounded down: a candidate never claims more than it covers
        fills = max(1, min(w, trunc(h * aspect)))
        variant |> Map.put(:file_width, w) |> Map.put(:width, fills)

      _ ->
        variant
    end
  end

  defp cover_aspect(%{fit: "cover", box_aspect: aspect}), do: parse_aspect(aspect)
  defp cover_aspect(_assigns), do: nil

  # 1:100 to 100:1; anything outside is no box a tile has
  defp parse_aspect(n) when is_number(n) and n >= 0.01 and n <= 100, do: n

  defp parse_aspect(text) when is_binary(text) do
    case text |> String.split("/", parts: 2) |> Enum.map(&number/1) do
      [w, h] when is_number(w) and is_number(h) and h > 0 -> parse_aspect(w / h)
      [n] -> parse_aspect(n)
      _ -> nil
    end
  end

  defp parse_aspect(_aspect), do: nil

  defp number(text) do
    case Float.parse(String.trim(text)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp mime_to_format("image/webp"), do: "webp"
  defp mime_to_format("image/avif"), do: "avif"
  # PNG goes into the fallback <img> group — no separate <source> needed
  defp mime_to_format(_), do: nil

  # Returns [{format, sorted_variants}] in priority order: AVIF > WebP > others
  # Excludes nil (primary/fallback format) — that goes in the <img> fallback
  defp prioritize_formats(grouped) do
    priority = ["avif", "webp"]

    grouped
    |> Enum.reject(fn {fmt, _} -> is_nil(fmt) end)
    |> Enum.sort_by(fn {fmt, _} ->
      case Enum.find_index(priority, &(&1 == fmt)) do
        nil -> 999
        idx -> idx
      end
    end)
  end

  defp build_srcset(variants) when is_list(variants) do
    variants
    |> Enum.filter(&(&1.url && &1.width))
    |> Enum.map_join(", ", fn v -> "#{v.url} #{v.width}w" end)
  end

  defp pick_fallback_src(fallback_variants, all_variants) do
    # Prefer "medium" primary variant, then largest primary, then any variant
    medium =
      Enum.find(fallback_variants, fn v ->
        {base, _} = VariantNaming.parse_variant_name(v.variant_name)
        base == "medium"
      end)

    cond do
      medium -> medium.url
      fallback_variants != [] -> List.last(fallback_variants).url
      all_variants != [] -> List.first(all_variants).url
      true -> ""
    end
  end
end
