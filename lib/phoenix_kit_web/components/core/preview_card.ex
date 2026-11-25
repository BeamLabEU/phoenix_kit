defmodule PhoenixKitWeb.Components.Core.PreviewCard do
  @moduledoc """
  A read-only preview card for any resource that has photos/files and a
  handful of display fields — the catalogue product card, generalised.
  Opened from a picker thumbnail or a list's featured-image thumb, and
  potentially shown to a CLIENT, not just admins, so it has to stand on
  its own.

  `preview_card/1` renders a `<.modal>` whose media area is ONE continuous
  swipeable carousel: images first, then attached files (a PDF renders
  inline, any other file as a tile with an Open action) — swipe through the
  images and just keep going into the files. Below it: the resource's
  filled scalar fields and a compact file list for saving. Slide switching
  is entirely client-side (scroll-snap); the only server event left is the
  close.

  The component is pure render: every DB-backed value (`images`, `files`,
  `fields`, `title`) is resolved by the caller, so it stays testable
  without a database. `preview_card_body/1` is the same content without
  the modal shell (the "notpopup" form).

  ## Usage

  The catalogue item card:

      <PreviewCard.preview_card
        id={@id}
        show={@card_open}
        title={@card_name}
        images={ProductCard.resolve_images(@item)}
        files={ProductCard.resolve_files(@item)}
        fields={ProductCard.build_fields(@item, @locale)}
        target={@myself}
        on_close="card_close"
      />

  A host app's sub-order featured-image card:

      <PreviewCard.preview_card
        id="sub-order-card"
        show={true}
        title={SubOrderCard.build(@sub_order, @order).name}
        images={@sub_order_card.images}
        files={@sub_order_card.files}
        fields={@sub_order_card.fields}
        target={nil}
        on_close="close_sub_order_card"
      />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Format

  # ── Render ───────────────────────────────────────────────────────

  @doc """
  Renders the preview card modal. Pure: every DB-backed value (`images`,
  `files`, `fields`, `title`) is resolved by the caller and passed in.

  Attrs:

    * `:id` (required) — used to derive the modal's DOM id.
    * `:show` (required) — whether the modal is open.
    * `:target` (required, `nil` allowed) — the `@myself` of the
      LiveComponent that handles the close event, or `nil` when the host
      is a LiveView itself.
    * `:title` — card title; falls back to gettext "Preview".
    * `:images` — ordered list of images, main image first. Each is a
      Storage file `%{uuid, name}`, or a picture that is not one —
      `%{src, name}` with an optional `:thumb_src` for the jump strip (a
      host-served page preview, say). See `image_url/2`.
    * `:fields` — list of `{label, value}` for the already-filtered,
      non-empty fields.
    * `:files` — ordered list of `%{uuid, name, size, pdf?}`.
    * `:on_close` — event pushed to `@target` on close (default
      `"preview_card_close"`).
    * `:max_width` — modal width class, forwarded to `<.modal>` (default
      `"3xl"`).
  """
  attr(:id, :string, required: true)
  attr(:show, :boolean, required: true)
  attr(:target, :any, required: true)
  attr(:title, :string, default: nil)
  attr(:images, :list, default: [])
  attr(:fields, :list, default: [])
  attr(:files, :list, default: [])
  attr(:on_close, :string, default: "preview_card_close")
  attr(:max_width, :string, default: "3xl")

  slot(:extra_actions,
    doc:
      "rendered in the modal's action row before Close — a host puts a " <>
        "mode-aware Add/quantity control or similar here."
  )

  def preview_card(assigns) do
    ~H"""
    <.modal show={@show} id={"#{@id}-card"} on_close={@on_close} max_width={@max_width}>
      <:title>{@title || gettext("Preview")}</:title>

      <.preview_card_body
        title={@title}
        images={@images}
        fields={@fields}
        files={@files}
      />

      <:actions>
        {render_slot(@extra_actions)}
        <button type="button" class="btn btn-ghost" phx-click={@on_close} phx-target={@target}>
          {gettext("Close")}
        </button>
      </:actions>
    </.modal>
    """
  end

  @doc """
  The card's content without the modal shell — the "notpopup" form, for
  embedding the same preview inline (a detail pane, a future product
  page). Same attrs as `preview_card/1` minus the modal ones — and
  minus `:target`: the body renders no event of its own (slide
  switching is client-side, the close button lives in the modal's
  action row), so an inline embedder has nothing to point at.

  The media area is ONE continuous swipeable carousel: images first, then
  the attached files (a PDF renders inline, any other file as a tile) — the
  client swipes through the images and just keeps going into the files.
  Scroll-snap (daisyUI `carousel`) drives it entirely client-side: native
  swipe on touch, arrow buttons on desktop, no server round-trip per slide.
  """
  attr(:title, :string, default: nil)
  attr(:images, :list, default: [])
  attr(:fields, :list, default: [])
  attr(:files, :list, default: [])

  def preview_card_body(assigns) do
    assigns = assign(assigns, :slide_count, length(assigns.images) + length(assigns.files))

    ~H"""
    <div class="flex flex-col gap-4" data-pc-root>
      <%!-- Unified media carousel — images, then files, one swipe track.
           All client-side: the arrows (`data-pc-step`), the jump tiles
           (`data-pc-jump`) and the scroll that keeps the strip's active
           tile in sync are listeners in phoenix_kit.js, which every page
           loads; no inline handlers, which a strict CSP would block. --%>
      <div :if={@slide_count > 0} class="relative">
        <div
          class="carousel w-full rounded-lg bg-base-200"
          data-pc-track
          role="region"
          aria-label={@title || gettext("Preview")}
        >
          <div
            :for={{img, idx} <- Enum.with_index(@images)}
            class="carousel-item w-full justify-center items-center"
          >
            <img
              src={image_url(img, "medium")}
              alt={Map.get(img, :name) || @title || ""}
              loading={(idx == 0 && "eager") || "lazy"}
              class="w-full h-[50vh] object-contain"
            />
          </div>
          <div :for={file <- @files} class="carousel-item w-full justify-center items-center">
            <%!-- Inline PDF only from `sm` up: iOS Safari renders iframe
                 PDFs as a broken single page AND the iframe swallows the
                 swipe gesture, stranding the carousel. Small screens get
                 the file tile; the strip and Open still work. --%>
            <iframe
              :if={file.pdf?}
              src={URLSigner.signed_url(file.uuid, "original")}
              title={file.name}
              class="w-full h-[50vh] hidden sm:block"
            ></iframe>
            <div
              :if={!file.pdf?}
              class="w-full h-[50vh] flex flex-col items-center justify-center gap-3"
            >
              <.file_slide_tile file={file} />
            </div>
            <div
              :if={file.pdf?}
              class="w-full h-[50vh] flex flex-col items-center justify-center gap-3 sm:hidden"
            >
              <.file_slide_tile file={file} />
            </div>
          </div>
        </div>
        <%!-- Arrows: desktop/pointer only — on touch the swipe IS the
             navigation and the buttons just crowd the photo edge. --%>
        <button
          :if={@slide_count > 1}
          type="button"
          aria-label={gettext("Previous")}
          class="btn btn-circle btn-sm bg-base-100/80 border-0 shadow absolute left-2 top-1/2 -translate-y-1/2 hidden sm:inline-flex"
          data-pc-step="-1"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" />
        </button>
        <button
          :if={@slide_count > 1}
          type="button"
          aria-label={gettext("Next")}
          class="btn btn-circle btn-sm bg-base-100/80 border-0 shadow absolute right-2 top-1/2 -translate-y-1/2 hidden sm:inline-flex"
          data-pc-step="1"
        >
          <.icon name="hero-chevron-right" class="w-4 h-4" />
        </button>
      </div>

      <%!-- Nothing attached: a placeholder, so a card without media keeps
           the same shape as one with it instead of collapsing to a bare
           list of fields (the catalogue's View popup, 2026-09-19 — most
           items have no photo yet). --%>
      <div
        :if={@slide_count == 0}
        class="rounded-lg bg-base-200 h-40 flex flex-col items-center justify-center gap-2 text-base-content/40"
      >
        <.icon name="hero-photo" class="w-8 h-8" />
        <span class="text-xs">{gettext("No images")}</span>
      </div>

      <%!-- Jump strip: a tile per slide (image thumbs, then file tiles).
           The border marks the current slide; the track's scroll moves
           it as the user swipes. Tile 0 starts active server-side. --%>
      <div :if={@slide_count > 1} class="flex gap-2 overflow-x-auto pb-1" data-pc-strip>
        <button
          :for={{img, idx} <- Enum.with_index(@images)}
          type="button"
          class={[
            "shrink-0 cursor-pointer rounded border-2 overflow-hidden transition-colors hover:border-primary",
            (idx == 0 && "border-primary") || "border-base-300"
          ]}
          aria-label={gettext("Show image %{number}", number: idx + 1)}
          aria-current={idx == 0 && "true"}
          data-pc-jump={idx}
        >
          <img
            src={image_url(img, "thumbnail")}
            alt=""
            class="w-16 h-16 object-cover"
          />
        </button>
        <button
          :for={{file, idx} <- Enum.with_index(@files, length(@images))}
          type="button"
          class="shrink-0 cursor-pointer w-[68px] h-[68px] rounded border-2 border-base-300 hover:border-primary transition-colors flex flex-col items-center justify-center gap-0.5 bg-base-200"
          aria-label={file.name}
          title={file.name}
          data-pc-jump={idx}
        >
          <.icon
            name={(file.pdf? && "hero-document-text") || "hero-document"}
            class="w-5 h-5 text-base-content/50"
          />
          <span class="text-[9px] leading-tight text-base-content/50 uppercase">
            {(file.pdf? && "pdf") || file_ext(file.name)}
          </span>
        </button>
      </div>

      <%!-- Filled fields (empty ones already dropped by the caller) --%>
      <dl
        :if={@fields != []}
        class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-3 border-t border-base-200 pt-4"
      >
        <div :for={{label, value} <- @fields} class="min-w-0">
          <dt class="text-xs font-medium text-base-content/50">{label}</dt>
          <dd class="text-sm text-base-content break-words whitespace-pre-line">{value}</dd>
        </div>
      </dl>

      <%!-- Compact file list — names, sizes, and a direct Open for saving;
           the slides above are the viewing surface. --%>
      <div :if={@files != []} class="border-t border-base-200 pt-4">
        <h4 class="text-xs font-medium text-base-content/50 mb-2">
          {gettext("Files")}
        </h4>
        <ul class="flex flex-col gap-1.5">
          <li
            :for={file <- @files}
            class="flex items-center gap-3 px-3 py-2 rounded-lg border border-base-200"
          >
            <.icon
              name={(file.pdf? && "hero-document-text") || "hero-document"}
              class="w-4 h-4 shrink-0 text-base-content/40"
            />
            <span class="text-sm truncate flex-1 min-w-0">{file.name}</span>
            <span class="text-xs text-base-content/50 tabular-nums shrink-0">
              {format_size(file.size)}
            </span>
            <a
              href={URLSigner.signed_url(file.uuid, "original")}
              target="_blank"
              rel="noopener"
              class="btn btn-ghost btn-xs"
            >
              {gettext("Open")}
            </a>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  The URL an `:images` entry renders from at `variant` (`"medium"` for the
  slide, `"thumbnail"` for the jump strip): a Storage file's signed URL for
  that variant, or — for an entry given by URL — its `:src`, with
  `:thumb_src` taking over for `"thumbnail"` when present.
  """
  @spec image_url(map(), String.t()) :: String.t()
  def image_url(%{thumb_src: thumb}, "thumbnail") when is_binary(thumb), do: thumb
  def image_url(%{src: src}, _variant) when is_binary(src), do: src
  def image_url(%{uuid: uuid}, variant), do: URLSigner.signed_url(uuid, variant)

  # A non-viewable file as a slide: icon, name, size, and an Open action.
  attr(:file, :map, required: true)

  defp file_slide_tile(assigns) do
    ~H"""
    <.icon name="hero-document" class="w-16 h-16 text-base-content/30" />
    <p class="text-sm font-medium text-center px-6 break-words max-w-full">{@file.name}</p>
    <p class="text-xs text-base-content/50 tabular-nums">{format_size(@file.size)}</p>
    <a
      href={URLSigner.signed_url(@file.uuid, "original")}
      target="_blank"
      rel="noopener"
      class="btn btn-sm btn-outline"
    >
      {gettext("Open")}
    </a>
    """
  end

  # Scrolls the slide at `idx` into view inside this card's own snap track.
  # `block: "nearest"` keeps the vertical position of the modal untouched.
  defp file_ext(name) when is_binary(name) do
    case Path.extname(name) do
      "." <> ext when byte_size(ext) in 1..4 -> ext
      _ -> "file"
    end
  end

  defp file_ext(_), do: "file"

  defp format_size(size) when is_integer(size) and size > 0,
    do: Format.bytes(size, base: 1000, decimals: 2)

  defp format_size(_), do: ""
end
