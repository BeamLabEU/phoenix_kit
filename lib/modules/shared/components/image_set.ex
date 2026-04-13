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

  ### With custom sizes attribute:

      <.image_set file_uuid="018e3c4a-..." alt="Photo" sizes="(max-width: 768px) 100vw, 50vw" />

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

  attr :alt, :string, default: "", doc: "Alt text for accessibility"
  attr :sizes, :string, default: "100vw", doc: "Sizes attribute for responsive images"
  attr :class, :string, default: "", doc: "CSS classes for the img element"
  attr :loading, :string, default: "lazy", doc: "Loading strategy: lazy or eager"
  attr :rest, :global

  def image_set(assigns) do
    variants = assigns.variants || load_variants(assigns.file_uuid)

    # Parse variant names and group by format
    grouped = group_variants_by_format(variants)

    # Format priority: AVIF first, then WebP, then fallback
    source_formats = prioritize_formats(grouped)
    fallback_variants = Map.get(grouped, nil, [])

    # Pick a good fallback src (prefer medium, then the largest available)
    fallback_src = pick_fallback_src(fallback_variants, variants)

    assigns =
      assigns
      |> assign(:source_formats, source_formats)
      |> assign(:fallback_variants, fallback_variants)
      |> assign(:fallback_src, fallback_src)
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
          srcset={build_srcset(@fallback_variants)}
          sizes={@sizes}
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

  defp load_variants(file_uuid) do
    if Code.ensure_loaded?(Storage) and function_exported?(Storage, :list_image_set_variants, 1) do
      Storage.list_image_set_variants(file_uuid)
    else
      []
    end
  end

  defp group_variants_by_format(variants) do
    # Group by actual mime_type, not variant name — this way files that failed
    # format conversion (e.g. AVIF without libheif) end up in the correct group.
    variants
    |> Enum.filter(&(&1.width && &1.width > 0))
    |> Enum.reject(&String.starts_with?(&1.variant_name, "video_"))
    |> Enum.group_by(&mime_to_format(&1.mime_type))
    |> Enum.map(fn {fmt, vs} ->
      # Deduplicate by width — keep the best variant per width per format
      deduped =
        vs
        |> Enum.sort_by(& &1.width)
        |> Enum.uniq_by(& &1.width)

      {fmt, deduped}
    end)
    |> Map.new()
  end

  defp mime_to_format("image/webp"), do: "webp"
  defp mime_to_format("image/avif"), do: "avif"
  defp mime_to_format("image/png"), do: "png"
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
