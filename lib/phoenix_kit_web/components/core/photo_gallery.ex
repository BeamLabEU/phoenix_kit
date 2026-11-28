defmodule PhoenixKitWeb.Components.Core.PhotoGallery do
  @moduledoc """
  A public photo gallery: a grid of thumbnails that opens a full-screen
  lightbox.

  In the lightbox a visitor can

    * swipe (finger or mouse) or use ← / → (Home / End) to go between photos,
    * drag a photo down, press Esc or click the dark backdrop to close it,
    * zoom with a pinch, a double tap / double click, the mouse wheel or
      `+` / `-` (`0` resets), and pan a zoomed photo by dragging it.

  Photos are core storage files (by uuid — the lightbox gets the file's
  variants as a `srcset`, AVIF/WebP first, like `<.image_set>`) or plain URLs,
  and the two can be mixed. Each photo can carry a caption, and the
  `:actions` slot puts the app's own buttons (download, share, report…) in
  the lightbox's top bar, rendered once per photo so a link can name the
  photo it is about.

  The lightbox is a native `<dialog>` opened with `showModal()`: the page
  behind it is inert, so focus stays inside, and focus returns to the
  thumbnail it was opened from. Slides are announced ("Photo 3 of 12"), the
  ones off screen are `inert`, and with `prefers-reduced-motion` nothing
  slides or springs. The behaviour lives in `phoenix_kit.js` as delegated
  document listeners (`data-pk-gallery*` attributes), not a hook, so it works
  on controller-rendered pages as well as in a LiveView.

  ## Examples

  Storage files (one query loads every file's variants, one more their alt
  text):

      <.photo_gallery id="listing-photos" photos={@listing.photo_uuids} />

  Plain URLs, captions and the app's own buttons:

      <.photo_gallery
        id="trip"
        photos={[
          %{src: "/images/a.jpg", thumb: "/images/a_small.jpg", alt: "Harbour", caption: "Tallinn harbour"},
          %{src: "/images/b.jpg", srcset: "/images/b_800.jpg 800w, /images/b.jpg 2000w", alt: "Old town"}
        ]}
      >
        <:actions :let={photo}>
          <a href={photo.download} download class="btn btn-sm btn-ghost text-white">Download</a>
          <button type="button" phx-click="report_photo" phx-value-index={photo.index}
            class="btn btn-sm btn-ghost text-white">Report</button>
        </:actions>
      </.photo_gallery>

  Opening it from your own button instead of the grid (`thumbnails={false}`):

      <button phx-click={PhotoGallery.open("trip", 2)}>See all photos</button>

  or from the server: `push_event(socket, "pk:photo-gallery-open", %{id: "trip", index: 0})`.
  A plain `<button data-pk-gallery-open="2" data-pk-gallery="trip">` works too,
  on any page.

  ## Photos

  Each entry of `photos` is one of

    * a storage file uuid (a string);
    * a map with `:file_uuid` and optionally `:variants` (pre-loaded with
      `Storage.list_image_set_variants_for_files/1`), `:alt`, `:caption`;
    * a map with `:src` (the full-size URL) and optionally `:srcset`,
      `:sizes`, `:thumb` (the grid's picture, default `src`), `:download`
      (default `src`), `:alt`, `:caption`, `:width`, `:height`;
    * a URL (a string that is not a uuid).

  String keys work as well as atom keys. Files in a **private** library:
  the uuid form mints permanent URLs, which the file route refuses for a
  private file; pass `src`/`thumb` built with `Storage.authorized_url/4`.

  Every photo is rendered into the page (the lightbox's pictures load
  lazily, the neighbours of the one on screen first), so a gallery is for
  tens of photos, not thousands.

  ## The `:actions` slot

  Called once per photo with a map: `:index` (0-based), `:src`, `:download`
  (the original's URL), `:alt`, `:caption`, `:file_uuid` (nil for a URL) and
  `:item` (the entry as you passed it). Only the current photo's bar is
  shown. The lightbox's own close button stays at the end of the bar.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.Shared.Components.ImageSet
  alias PhoenixKit.Modules.Storage

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  attr :id, :string, required: true, doc: "unique DOM id; the lightbox is `<id>-dialog`"
  attr :photos, :list, required: true, doc: "storage file uuids, URLs or maps — see Photos"

  attr :label, :string,
    default: nil,
    doc: "accessible name of the lightbox; defaults to a translated \"Photo gallery\""

  attr :thumbnails, :boolean,
    default: true,
    doc: "render the thumbnail grid; `false` when the page opens the lightbox itself"

  attr :class, :string,
    default: "grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-2",
    doc: "classes of the thumbnail grid"

  attr :thumb_class, :string,
    default: "aspect-square",
    doc: "classes of each thumbnail button (its box; the picture covers it)"

  attr :thumb_sizes, :string,
    default: "(max-width: 640px) 50vw, (max-width: 768px) 33vw, 25vw",
    doc: "`sizes` of the thumbnails' srcset (storage photos)"

  attr :max_zoom, :integer,
    default: 4,
    doc: "how far a photo can be zoomed in (× its fitted size)"

  attr :rest, :global

  slot :actions,
    doc: "the app's buttons in the lightbox's top bar, rendered per photo (`:let` — see above)"

  slot :caption,
    doc:
      "a rich caption, rendered per photo (`:let` as `:actions`); replaces the entry's `:caption`"

  def photo_gallery(assigns) do
    photos = normalize(assigns.photos)

    assigns =
      assigns
      |> assign(:items, photos)
      |> assign(:count, length(photos))
      |> assign(:stage_id, assigns.id <> "-stage-" <> fingerprint(photos))
      |> assign(:label, assigns.label || gettext("Photo gallery"))

    ~H"""
    <div id={@id} data-pk-gallery-root data-pk-gallery-max-zoom={@max_zoom} {@rest}>
      <ul :if={@thumbnails and @count > 0} class={@class} role="list">
        <li :for={photo <- @items} class="min-w-0">
          <button
            type="button"
            data-pk-gallery-open={photo.index}
            class={[
              "group block w-full overflow-hidden rounded-box bg-base-200 focus:outline-none focus-visible:ring-2 focus-visible:ring-primary",
              @thumb_class
            ]}
            aria-label={thumb_label(photo, @count)}
            aria-haspopup="dialog"
            aria-controls={@id <> "-dialog"}
          >
            <%= if photo.file_uuid do %>
              <ImageSet.image_set
                file_uuid={photo.file_uuid}
                variants={photo.variants}
                alt={photo.alt}
                fit="cover"
                box_aspect={1}
                sizes={@thumb_sizes}
                class="w-full h-full object-cover transition-transform motion-safe:group-hover:scale-105"
              />
            <% else %>
              <img
                src={photo.thumb}
                alt={photo.alt}
                loading="lazy"
                class="w-full h-full object-cover transition-transform motion-safe:group-hover:scale-105"
              />
            <% end %>
          </button>
        </li>
      </ul>

      <dialog
        id={@id <> "-dialog"}
        data-pk-gallery-dialog
        aria-label={@label}
        phx-mounted={JS.ignore_attributes(["open", "style"])}
        class="pk-photo-gallery m-0 p-0 w-screen h-screen max-w-none max-h-none bg-transparent overflow-hidden text-white backdrop:bg-transparent"
      >
        <%!-- Everything the script moves lives in here: a patch must not
             undo a slide's position or a zoom, so LiveView leaves it alone.
             The id changes with the photos, so new photos re-render it. --%>
        <div
          id={@stage_id}
          phx-update="ignore"
          data-pk-gallery-stage
          data-index="0"
          data-count={@count}
          class="relative w-full h-full select-none"
        >
          <div
            data-pk-gallery-backdrop
            class="absolute inset-0 bg-black/95"
            aria-hidden="true"
          >
          </div>

          <div
            data-pk-gallery-viewport
            class="absolute inset-0 overflow-hidden touch-none"
            aria-roledescription={gettext("carousel")}
          >
            <div data-pk-gallery-track dir="ltr" class="flex h-full w-full will-change-transform">
              <div
                :for={photo <- @items}
                data-pk-gallery-slide={photo.index}
                role="group"
                aria-roledescription={gettext("slide")}
                aria-label={position_label(photo, @count)}
                aria-hidden={if photo.index != 0, do: "true"}
                inert={photo.index != 0}
                class="relative flex h-full w-full shrink-0 items-center justify-center overflow-hidden"
              >
                <div
                  data-pk-gallery-zoom
                  class="flex h-full w-full items-center justify-center px-2 pt-14 pb-16 sm:px-14"
                >
                  <%= if photo.file_uuid do %>
                    <ImageSet.image_set
                      file_uuid={photo.file_uuid}
                      variants={photo.variants}
                      alt={photo.alt}
                      sizes="100vw"
                      loading="lazy"
                      class="max-h-full max-w-full object-contain"
                      draggable="false"
                      data-pk-gallery-img
                    />
                  <% else %>
                    <img
                      src={photo.src}
                      srcset={photo.srcset}
                      sizes={if photo.srcset, do: photo.sizes || "100vw"}
                      width={photo.width}
                      height={photo.height}
                      alt={photo.alt}
                      loading="lazy"
                      draggable="false"
                      data-pk-gallery-img
                      class="max-h-full max-w-full object-contain"
                    />
                  <% end %>
                </div>
              </div>
            </div>
          </div>

          <div
            data-pk-gallery-chrome
            class="pointer-events-none absolute inset-x-0 top-0 flex items-center gap-2 bg-gradient-to-b from-black/60 to-transparent p-2 sm:p-3"
          >
            <span
              :if={@count > 1}
              data-pk-gallery-counter
              data-template={counter_text("{n}", "{count}")}
              class="px-2 text-sm tabular-nums text-white/80"
            >
              {counter_text(1, @count)}
            </span>
            <div class="ml-auto flex items-center gap-1">
              <div
                :for={photo <- @items}
                data-pk-gallery-actions={photo.index}
                hidden={photo.index != 0}
                class="pointer-events-auto flex items-center gap-1"
              >
                {render_slot(@actions, photo)}
              </div>
              <button
                type="button"
                data-pk-gallery-close
                class="btn btn-circle btn-ghost btn-sm pointer-events-auto text-white hover:bg-white/15"
                aria-label={gettext("Close")}
              >
                <.icon name="hero-x-mark" class="w-6 h-6" />
              </button>
            </div>
          </div>

          <button
            :if={@count > 1}
            type="button"
            data-pk-gallery-prev
            class="btn btn-circle btn-ghost absolute left-2 top-1/2 -translate-y-1/2 text-white hover:bg-white/15 max-sm:hidden"
            aria-label={gettext("Previous photo")}
          >
            <.icon name="hero-chevron-left" class="w-7 h-7" />
          </button>
          <button
            :if={@count > 1}
            type="button"
            data-pk-gallery-next
            class="btn btn-circle btn-ghost absolute right-2 top-1/2 -translate-y-1/2 text-white hover:bg-white/15 max-sm:hidden"
            aria-label={gettext("Next photo")}
          >
            <.icon name="hero-chevron-right" class="w-7 h-7" />
          </button>

          <div
            data-pk-gallery-captions
            class="pointer-events-none absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/70 to-transparent px-4 pt-8 pb-4 text-center text-sm"
          >
            <div
              :for={photo <- @items}
              data-pk-gallery-caption={photo.index}
              hidden={photo.index != 0}
              class="pointer-events-auto mx-auto max-w-3xl"
            >
              <%= if @caption != [] do %>
                {render_slot(@caption, photo)}
              <% else %>
                {photo.caption}
              <% end %>
            </div>
          </div>

          <p data-pk-gallery-live class="sr-only" aria-live="polite" aria-atomic="true"></p>
        </div>
      </dialog>
    </div>
    """
  end

  @doc """
  A `Phoenix.LiveView.JS` that opens gallery `id` at photo `index` (0-based).

      <button phx-click={PhotoGallery.open("trip", 2)}>Photo 3</button>
  """
  @spec open(String.t(), non_neg_integer()) :: JS.t()
  def open(id, index \\ 0) when is_binary(id) and is_integer(index), do: open(%JS{}, id, index)

  @doc "As `open/2`, added to an existing `js`."
  @spec open(JS.t(), String.t(), non_neg_integer()) :: JS.t()
  def open(%JS{} = js, id, index) when is_binary(id) and is_integer(index) do
    JS.dispatch(js, "pk:photo-gallery-open", to: "#" <> id, detail: %{index: index})
  end

  # ── Photos ──────────────────────────────────────────────────────────

  @doc false
  # Public for the tests: every entry as one map, with the storage files'
  # variants and alt text loaded in one query each.
  def normalize(photos) when is_list(photos) do
    entries = photos |> Enum.map(&entry/1) |> Enum.reject(&is_nil/1)

    missing_variants =
      for %{file_uuid: uuid, variants: nil} <- entries, uuid != nil, uniq: true, do: uuid

    missing_alts = for %{file_uuid: uuid, alt: nil} <- entries, uuid != nil, uniq: true, do: uuid

    variants = load_variants(missing_variants)
    alts = load_alts(missing_alts)

    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> finish(entry, index, variants, alts) end)
  end

  def normalize(_photos), do: []

  defp entry(uuid) when is_binary(uuid) do
    if Regex.match?(@uuid, uuid), do: entry(%{file_uuid: uuid}), else: entry(%{src: uuid})
  end

  defp entry(%{} = item) do
    get = fn key -> Map.get(item, key, Map.get(item, Atom.to_string(key))) end
    uuid = get.(:file_uuid)
    src = get.(:src)

    cond do
      is_binary(uuid) and uuid != "" ->
        %{
          file_uuid: uuid,
          variants: get.(:variants),
          src: src,
          srcset: nil,
          sizes: nil,
          thumb: get.(:thumb),
          download: get.(:download),
          alt: get.(:alt),
          caption: get.(:caption),
          width: nil,
          height: nil,
          item: item
        }

      is_binary(src) and src != "" ->
        %{
          file_uuid: nil,
          variants: nil,
          src: src,
          srcset: get.(:srcset),
          sizes: get.(:sizes),
          thumb: get.(:thumb) || src,
          download: get.(:download) || src,
          alt: get.(:alt) || "",
          caption: get.(:caption),
          width: get.(:width),
          height: get.(:height),
          item: item
        }

      true ->
        nil
    end
  end

  defp entry(_item), do: nil

  defp finish(%{file_uuid: nil} = entry, index, _variants, _alts) do
    entry |> Map.put(:index, index) |> Map.update!(:item, &original_item/1)
  end

  defp finish(%{file_uuid: uuid} = entry, index, variants, alts) do
    file_variants = entry.variants || Map.get(variants, uuid, [])
    original = original_url(file_variants)

    entry
    |> Map.put(:index, index)
    |> Map.put(:variants, file_variants)
    |> Map.put(:alt, entry.alt || Map.get(alts, uuid, ""))
    |> Map.put(:src, entry.src || original)
    |> Map.put(:download, entry.download || original)
    |> Map.update!(:item, &original_item/1)
  end

  # A bare uuid / URL is handed back to the slot as the string it was.
  defp original_item(%{file_uuid: uuid} = item) when map_size(item) == 1, do: uuid
  defp original_item(%{src: src} = item) when map_size(item) == 1, do: src
  defp original_item(item), do: item

  # The original's URL, else the widest variant's.
  defp original_url([]), do: nil

  defp original_url(variants) do
    case Enum.find(variants, &(&1.variant_name == "original")) do
      %{url: url} ->
        url

      nil ->
        variants |> Enum.max_by(&(&1.width || 0)) |> Map.get(:url)
    end
  end

  defp load_variants([]), do: %{}

  defp load_variants(uuids) do
    Storage.list_image_set_variants_for_files(uuids)
  rescue
    _ -> %{}
  end

  defp load_alts([]), do: %{}

  defp load_alts(uuids) do
    Storage.translated_alts(uuids, PhoenixKit.Utils.Multilang.current_locale())
  rescue
    _ -> %{}
  end

  # Short and stable: changes whenever the photos (or their order) do.
  defp fingerprint(photos) do
    photos
    |> Enum.map(&{&1.file_uuid, &1.src, &1.srcset, &1.caption})
    |> :erlang.term_to_binary()
    |> :erlang.md5()
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 10)
  end

  # ── Labels ──────────────────────────────────────────────────────────

  defp counter_text(n, count), do: gettext("%{n} / %{count}", n: n, count: count)

  defp position_label(photo, count),
    do: gettext("Photo %{n} of %{count}", n: photo.index + 1, count: count)

  defp thumb_label(%{alt: alt} = photo, count) when is_binary(alt) and alt != "",
    do: gettext("Open photo %{n} of %{count}: %{alt}", n: photo.index + 1, count: count, alt: alt)

  defp thumb_label(photo, count),
    do: gettext("Open photo %{n} of %{count}", n: photo.index + 1, count: count)
end
