defmodule PhoenixKitWeb.Components.MediaBrowser.Helpers do
  @moduledoc false
  # What the media browser's templates draw with: its file and folder cards
  # and the small formatting helpers. A module of its own so the template
  # modules (`MediaBrowser.View` and its sections) and the component can all
  # import it, and each stays quick to compile.
  use PhoenixKitWeb, :html

  import PhoenixKitWeb.Components.FolderExplorer, only: [folder_color_hex: 1]

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ImageEditing
  alias PhoenixKit.Modules.Storage.Shape
  alias PhoenixKit.Utils.Format
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  # ── Upload problems ───────────────────────────────────────────────
  #
  # One row per upload that did not land, whatever the reason:
  #
  #   :server       received, but the store failed — bytes kept, retryable
  #   :interrupted  received, but processing never finished (the LiveView
  #                 died, the page was refreshed) — bytes kept, retryable
  #   :rejected     turned away before transfer (too large, wrong type, more
  #                 than fit at once) — nothing kept; the reason says what to do
  #   :browser      a transfer the page lost, reported by the UploadResume
  #                 hook — retryable when the browser kept a copy
  #
  # The first two come from the user's UploadInbox (on disk, so they survive
  # a refresh); the rest live in this browser's session.

  @doc false
  def upload_problems(assigns) do
    (assigns[:upload_inbox_problems] || []) ++
      Enum.reverse(assigns[:upload_problems_session] || [])
  end

  # Who the browser-side stash belongs to: it holds file bytes on a machine
  # the next person may sign in on, and Resume would upload them as them.
  def upload_stash_user(%{phoenix_kit_current_user: %{uuid: uuid}}), do: to_string(uuid)
  def upload_stash_user(_assigns), do: ""

  # The in-flight file plus everything still queued, as upload entries for the
  # template's "Processing on server…" rows.
  def processing_upload_entries(assigns) do
    [assigns[:upload_processing] | assigns[:upload_process_queue] || []]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {_path, entry} -> entry end)
  end

  @doc false
  # The canvas viewer's component id — single source for the heex render
  # and the refresh poke above, which must address the SAME component
  # instance. Encodes the dims + variant count so a processing-completion
  # refresh remounts with the real canvas (see the heex comment).
  def viewer_component_id(f) do
    # The original's URL carries its version, so an edit remounts too.
    "media-canvas-viewer-#{f.file_uuid}-#{f.width || 0}x#{f.height || 0}-#{map_size(f.urls)}-" <>
      Integer.to_string(:erlang.phash2(f.urls["original"]))
  end

  # ──────────────────────────────────────────────────────────────
  # Stacks view — function components
  # ──────────────────────────────────────────────────────────────

  # A collapsed folder "pile": up to a few preview thumbnails fanned out, the
  # file count, and the folder name. Clicking toggles its inline grid.
  attr :folder, :map, required: true
  attr :previews, :list, default: []
  attr :count, :integer, default: 0
  attr :expanded, :boolean, default: false
  attr :myself, :any, required: true

  def stack_tile(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={
        if @expanded,
          do: JS.dispatch("pk:close-stack", to: "#pk-stack-#{@folder.uuid}"),
          else:
            JS.push("toggle_stack_expand",
              target: @myself,
              value: %{"folder-uuid" => @folder.uuid}
            )
      }
      data-stack-tile={@folder.uuid}
      data-drop-folder={@folder.uuid}
      data-drop-color={drop_outline_color(@folder.color)}
      class="group flex flex-col items-center gap-2 w-40 rounded-lg focus:outline-none"
      title={@folder.name}
    >
      <div
        class={[
          "relative w-36 h-28 grid place-items-center rounded-lg transition-shadow",
          @expanded && "ring-2 ring-offset-2 ring-offset-base-100"
        ]}
        style={@expanded && "--tw-ring-color: #{drop_outline_color(@folder.color)}"}
      >
        <%= if @previews == [] do %>
          <div class="w-32 h-24 rounded-lg border-2 border-dashed border-base-300 grid place-items-center text-xs text-base-content/50">
            {gettext("No images")}
          </div>
        <% else %>
          <%= for {pf, i} <- @previews |> Enum.take(3) |> Enum.with_index() |> Enum.reverse() do %>
            <div class={[
              "absolute w-32 h-24 rounded-lg overflow-hidden shadow border border-base-100 bg-base-300",
              stack_offset_class(i)
            ]}>
              <.thumbnail_url :let={url} file={pf} size={:card}>
                <%= if url do %>
                  <img
                    src={url}
                    alt=""
                    class={[
                      "w-full h-full object-cover",
                      rotation_class(pf, box: :landscape_4_3)
                    ]}
                  />
                <% else %>
                  <div class="w-full h-full grid place-items-center text-base-content/40">
                    <.icon name={file_icon_for(pf)} class="w-8 h-8" />
                  </div>
                <% end %>
              </.thumbnail_url>
            </div>
          <% end %>
        <% end %>

        <span
          :if={@count > 0}
          class="absolute -top-1 -right-1 z-30 badge badge-neutral badge-sm shadow"
        >
          {@count}
        </span>
      </div>
      <p class="text-sm font-medium text-center truncate w-36">{@folder.name}</p>
    </button>
    """
  end

  # Pile fan-out: the front card (index 0) sits flat on top; the ones behind it
  # are rotated/offset to read as a stack.
  def stack_offset_class(0), do: "rotate-0 translate-y-0 z-20"
  def stack_offset_class(1), do: "rotate-[5deg] translate-x-2 -translate-y-1 z-10"
  def stack_offset_class(_), do: "-rotate-[5deg] -translate-x-2 -translate-y-0.5 z-0"

  # Drag-accept outline colour for a folder drop target — the folder's own
  # colour (matching its icon) instead of a generic blue. Default folders use
  # the same accent their icon does.
  def drop_outline_color(color), do: folder_color_hex(color) || "oklch(var(--wa))"

  # Whether `file_uuid` is the host's current featured image. `featured`
  # is the raw `:featured` attr (nil when the host never opted in).
  def featured?(nil, _file_uuid), do: false
  def featured?(%{uuid: uuid}, file_uuid), do: uuid == file_uuid

  # Star in the top-left corner of an image tile when the host opted into
  # `:featured` — styled like the tile's ⋮ trigger (white glyph on a
  # translucent black circle). Interactive, it is a toggle on every image
  # tile: solid on the featured one (click → `unset_featured`), outline on
  # the rest (click → `set_featured`, moving the pointer there). Not
  # interactive (read-only, select mode, trash), only the featured tile
  # keeps its star, as a plain badge. Callers render it as a sibling of the
  # tile's `click_file` target, like the kebab, so a click on the star
  # never also opens the viewer. Shares placement with the video/PDF badges
  # — safe because those only ever appear on non-image files, and only
  # images can be featured. In select mode the corner belongs to the
  # selection checkbox (`top-1 left-1 z-10`, the same size as the star), so
  # the passive badge steps right of it instead of hiding underneath.
  attr :file, :map, required: true
  attr :featured, :any, default: nil
  attr :interactive, :boolean, default: false
  attr :select_mode, :boolean, default: false
  attr :myself, :any, default: nil

  def featured_badge(assigns) do
    assigns = assign(assigns, :on, featured?(assigns.featured, assigns.file.file_uuid))

    ~H"""
    <button
      :if={@interactive and @featured != nil and @file.file_type == "image"}
      type="button"
      data-role={if @on, do: "featured-badge", else: "featured-toggle"}
      phx-click={if @on, do: "unset_featured", else: "set_featured"}
      phx-target={@myself}
      phx-value-file-uuid={@file.file_uuid}
      aria-pressed={to_string(@on)}
      aria-label={if @on, do: gettext("Unset featured"), else: gettext("Set as featured")}
      title={
        if @on,
          do: @featured[:label] || gettext("Featured image"),
          else: gettext("Set as featured")
      }
      class="absolute top-1.5 left-1.5 w-5 h-5 flex items-center justify-center rounded-full bg-black/40 hover:bg-black/60 text-white transition-colors cursor-pointer"
    >
      <.icon name={if @on, do: "hero-star-solid", else: "hero-star"} class="w-3 h-3 block" />
    </button>
    <div
      :if={not @interactive and @on and @file.file_type == "image"}
      data-role="featured-badge"
      class={[
        "absolute top-1.5 w-5 h-5 flex items-center justify-center rounded-full bg-black/40 text-white pointer-events-none",
        if(@select_mode, do: "left-7", else: "left-1.5")
      ]}
    >
      <span
        class="block pointer-events-auto"
        title={@featured[:label] || gettext("Featured image")}
      >
        <.icon name="hero-star-solid" class="w-3 h-3 block" />
      </span>
    </div>
    """
  end

  # A single file thumbnail tile, reused by the "Everything else" grid and each
  # expanded stack. Selection-aware; opens the viewer / detail on click.
  attr :file, :map, required: true
  attr :select_mode, :boolean, default: false
  attr :selected_files, :any, required: true
  attr :myself, :any, required: true
  attr :filter_trash, :boolean, default: false
  # When set (stacks expand), `data-stack-card` marks the card for the
  # StackExpand JS hook, which makes it fly out of the pile (FLIP) staggered by
  # this index. nil = no animation (grid / "Everything else" reuse).
  attr :index, :integer, default: nil
  # See the moduledoc's `:featured` attr. `nil` (the default) keeps the
  # star badge and kebab item off.
  attr :featured, :any, default: nil
  attr :readonly, :boolean, default: false

  def file_card(assigns) do
    ~H"""
    <div
      data-draggable-file={if not @readonly, do: @file.file_uuid}
      data-selected={if @select_mode && MapSet.member?(@selected_files, @file.file_uuid), do: "true"}
      data-stack-card={@index}
      class={[
        "group relative aspect-square bg-base-300 rounded-lg overflow-hidden hover:shadow-lg transition-shadow",
        @select_mode && MapSet.member?(@selected_files, @file.file_uuid) && "ring-2 ring-primary"
      ]}
    >
      <label :if={@select_mode} class="absolute top-1 left-1 z-10 cursor-pointer">
        <input
          type="checkbox"
          class="checkbox checkbox-primary checkbox-sm"
          checked={MapSet.member?(@selected_files, @file.file_uuid)}
          phx-click="toggle_select"
          phx-target={@myself}
          phx-value-file-uuid={@file.file_uuid}
        />
      </label>

      <div
        phx-click="click_file"
        phx-target={@myself}
        phx-value-file-uuid={@file.file_uuid}
        class="block w-full h-full cursor-pointer"
      >
        <.thumbnail_url :let={url} file={@file} size={:card}>
          <%= if url do %>
            <img
              src={url}
              alt={Map.get(@file, :alt) || @file.filename}
              class={[
                "w-full h-full object-cover pointer-events-none group-hover:opacity-75 transition-opacity",
                rotation_class(@file)
              ]}
            />
          <% else %>
            <div class="grid place-items-center w-full aspect-square text-base-content/50">
              <div class="flex flex-col items-center">
                <.icon name={file_icon_for(@file)} class="w-12 h-12 mb-2" />
                <p class="text-sm font-semibold">{file_type_label(@file)}</p>
              </div>
            </div>
          <% end %>
        </.thumbnail_url>

        <div
          :if={@file.file_type == "video"}
          class="absolute top-2 left-2 bg-black/60 text-white p-1.5 rounded pointer-events-none flex items-center justify-center"
        >
          <.icon name="hero-play-solid" class="w-4 h-4" />
        </div>

        <div
          :if={@file.mime_type == "application/pdf"}
          class="absolute top-2 left-2 bg-error/80 text-white px-2 py-0.5 rounded text-xs font-bold pointer-events-none"
        >
          PDF
        </div>

        <div class="absolute bottom-2 right-2 bg-black/60 text-white text-xs px-2 py-1 rounded pointer-events-none">
          {format_file_size(@file.size)}
        </div>
      </div>

      <.featured_badge
        file={@file}
        featured={@featured}
        interactive={not @readonly and not @select_mode and not @filter_trash}
        select_mode={@select_mode}
        myself={@myself}
      />

      <%!--
      Per-file kebab menu. Sibling of the click target so its buttons don't
      fire `click_file`. Mirrors the grid-view card: hidden until hover,
      Download only when an "original" URL exists, Delete/Trash always.
      --%>
      <.table_row_menu
        :if={!@select_mode}
        id={"file-kebab-stack-#{@file.file_uuid}"}
        class="!absolute top-1 right-1 opacity-0 group-hover:opacity-100"
        trigger_class="!bg-black/40 hover:!bg-black/60 !text-white !border-0"
      >
        <.table_row_menu_button
          :if={
            Map.get(@file.urls || %{}, "original") ||
              Map.get(@file.urls || %{}, :original)
          }
          phx-click="download_file"
          phx-target={@myself}
          phx-value-file-uuid={@file.file_uuid}
          icon="hero-arrow-down-tray"
          label={gettext("Download")}
        />
        <%!-- Rotate the saved orientation ±90 (images only). Persists like
              the viewer; the thumbnail reorients live. --%>
        <.table_row_menu_button
          :if={
            not @readonly and @file.file_type == "image" and not @filter_trash and
              ImageEditing.editable_mime?(@file.mime_type)
          }
          phx-click="open_image_editor"
          phx-target={@myself}
          phx-value-file-uuid={@file.file_uuid}
          icon="hero-adjustments-horizontal"
          label={gettext("Edit image")}
        />
        <%!-- See the moduledoc's `:featured` attr — off entirely when the
              host didn't opt in. --%>
        <.table_row_menu_button
          :if={(not @readonly and @featured) && @file.file_type == "image" && !@filter_trash}
          phx-click={
            if featured?(@featured, @file.file_uuid), do: "unset_featured", else: "set_featured"
          }
          phx-target={@myself}
          phx-value-file-uuid={@file.file_uuid}
          icon={if featured?(@featured, @file.file_uuid), do: "hero-star-solid", else: "hero-star"}
          label={
            if featured?(@featured, @file.file_uuid),
              do: gettext("Unset featured"),
              else: gettext("Set as featured")
          }
        />
        <.table_row_menu_button
          :if={not @readonly and @file.file_type == "image"}
          phx-click="rotate_file"
          phx-target={@myself}
          phx-value-file-uuid={@file.file_uuid}
          phx-value-dir="left"
          icon="hero-arrow-uturn-left"
          label={gettext("Rotate left")}
        />
        <.table_row_menu_button
          :if={not @readonly and @file.file_type == "image"}
          phx-click="rotate_file"
          phx-target={@myself}
          phx-value-file-uuid={@file.file_uuid}
          phx-value-dir="right"
          icon="hero-arrow-uturn-right"
          label={gettext("Rotate right")}
        />
        <.table_row_menu_button
          :if={not @readonly}
          phx-click="prepare_move_file"
          phx-target={@myself}
          phx-value-file-uuid={@file.file_uuid}
          icon="hero-folder-arrow-down"
          label={gettext("Move")}
        />
        <%!-- Restore (trash view). This menu is the one a trashed file
             actually offers, and it held Move and Delete Permanently and
             no way back — the trash read as permanent. --%>
        <.table_row_menu_button
          :if={not @readonly and @filter_trash}
          phx-click="restore_file"
          phx-target={@myself}
          phx-value-file-uuid={@file.file_uuid}
          icon="hero-arrow-uturn-left"
          label={gettext("Restore")}
        />
        <.table_row_menu_button
          :if={not @readonly}
          phx-click="delete_file"
          phx-target={@myself}
          phx-value-file-uuid={@file.file_uuid}
          data-confirm={
            if @filter_trash,
              do:
                gettext("Permanently delete '%{name}'? This cannot be undone.",
                  name: @file.filename
                )
          }
          icon="hero-trash"
          label={
            if @filter_trash,
              do: gettext("Delete Permanently"),
              else: gettext("Move to Trash")
          }
          variant="error"
        />
      </.table_row_menu>
    </div>
    """
  end

  # The folder whose header customizations to render in the hero, or `nil`.
  #
  # An embedded (scoped) browser treats the scope folder as its effective root,
  # so that folder's header (description / logo / cover / creation-info) shows
  # at the root even though `current_folder` is `nil` there. But ONLY at the
  # root: the `<h2>` title (`media_browser.html.heex` cond) reads "All Files" /
  # "Trash" / "Orphaned Files" in the flat listings and shows the scope folder
  # name in search, so the scope folder's metadata would disagree with the
  # title there — fall back to `nil` (plain hero) instead.
  #
  # Single source of truth: both the nav data path (`apply_nav_params`) and the
  # template's `header_folder` local pipe the current view state through this,
  # so display and the seeded `folder_*` assigns can't drift apart.
  @doc false
  def header_folder_target(
        current_folder,
        file_view,
        filter_orphaned,
        search_query,
        filter_trash,
        scope_folder
      ) do
    cond do
      current_folder -> current_folder
      file_view == "all" -> nil
      filter_orphaned -> nil
      filter_trash -> nil
      search_query not in ["", nil] -> nil
      scope_folder -> scope_folder
      true -> nil
    end
  end

  # Class list for a folder-cover `<img>` honoring the saved rotation. The
  # cover box's aspect is arbitrary (hero height depends on header size and
  # viewport), so quarter turns can't use a fixed re-cover scale like the
  # stacks pile does — instead the image swaps its dimensions via
  # container-query units (width from the box's height and vice versa; the
  # wrapping div is the size container) and rotates about the center, which
  # covers the box exactly.
  def cover_image_class(rotation) when rotation in [90, 270] do
    [
      "absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 max-w-none",
      "w-[100cqh] h-[100cqw] object-cover",
      if(rotation == 90, do: "rotate-90", else: "-rotate-90")
    ]
  end

  def cover_image_class(180), do: "absolute inset-0 w-full h-full object-cover rotate-180"
  def cover_image_class(_), do: "absolute inset-0 w-full h-full object-cover"

  @doc false
  def image_editor_id(browser_id, file_uuid), do: "#{browser_id}-image-editor-#{file_uuid}"

  # Enriches raw Storage.File structs with URLs, folder paths, and display fields.
  # A picture 2:1 or wider (`Storage.Shape`), read from the sizes the enriched
  # file carries: the grid marks it with a panorama badge.
  @doc false
  def panorama?(%{file_type: "image"} = file), do: Shape.classify(file) == :wide
  def panorama?(_file), do: false

  @doc false
  # The URL the viewer paints first: `burned_large`, else `burned`, else the
  # live layer's `small`. A step's stand-in and the neighbour warm use this,
  # so an arrow press does not flash the markup-free rung while the burn loads.
  def viewer_open_url(file) when is_map(file) do
    urls = Map.get(file, :urls) || %{}

    case Map.get(file, :burn_size) do
      %{variant: variant} when is_binary(variant) -> urls[variant] || urls["small"]
      _ -> urls["small"]
    end
  end

  def viewer_open_url(_), do: nil

  # What to warm for a neighbour. A burned file opens on that copy; an
  # unburned one still climbs `small` → `large`.
  # The original of a neighbour, or nil where nothing would raster-load it
  # (see the `data-neighbor-original-*` note in the template). Only images.
  def neighbor_original_url(%{file_type: "image"} = n) do
    urls = n.urls || %{}

    cond do
      is_binary(urls["burned_large"]) or is_binary(urls["burned"]) ->
        nil

      max(Map.get(n, :width) || 0, Map.get(n, :height) || 0) > 4096 and is_binary(urls["dzi"]) and
          urls["dzi"] != "" ->
        nil

      is_binary(urls["original"]) ->
        urls["original"]

      true ->
        nil
    end
  end

  def neighbor_original_url(_), do: nil

  # What the viewer's warm may use for one neighbour (see `data-neighbors` in
  # the template). Only images are warmable; anything else is nil.
  def neighbor_warm_data(%{file_type: "image"} = file) do
    urls = Map.get(file, :urls) || %{}
    burned? = is_binary(urls["burned_large"]) or is_binary(urls["burned"])

    %{
      "open" => viewer_open_url(file),
      "large" => if(burned?, do: nil, else: urls["large"]),
      "original" => neighbor_original_url(file),
      "aspect" => MediaCanvasViewer.neighbor_pane_aspect(file)
    }
  end

  def neighbor_warm_data(_), do: nil

  # The gallery's window (`Fresco.gallery`, the `ViewerGallery` hook): the
  # pictures either side of the one open, as the strip draws them. `src` is
  # the burned copy where there is one (the markup is part of the picture
  # here, and that copy has its own extent), else `large` — sharp enough for
  # a full-screen slide, unlike the `small` the viewer first paints. Sizes
  # are the copy's own for a burn (fitted), the original's otherwise (fitted,
  # or shown at 100% when smaller, as the viewer's actual-size view does).
  # Anything that isn't an image is a card with its name: the strip can
  # land on it, and the viewer takes over.
  @gallery_reach 12
  def gallery_items_json(siblings, idx) when is_list(siblings) and is_integer(idx) do
    from = max(idx - @gallery_reach, 0)
    upto = min(idx + @gallery_reach, length(siblings) - 1)

    items =
      if upto >= from,
        do: Enum.map(Enum.slice(siblings, from..upto//1), &gallery_item/1),
        else: []

    Jason.encode!(%{"items" => items, "index" => idx - from})
  end

  def gallery_items_json(_, _), do: Jason.encode!(%{"items" => [], "index" => 0})

  defp gallery_item(%{file_type: "image"} = f) do
    urls = Map.get(f, :urls) || %{}
    rot = gallery_rotation(Map.get(f, :rotation))

    case Map.get(f, :burn_size) do
      %{variant: variant, w: w, h: h} when is_binary(variant) ->
        %{
          "key" => f.file_uuid,
          "src" => urls[variant] || urls["large"] || urls["small"],
          "width" => w,
          "height" => h,
          "rotation" => rot,
          "actual" => false,
          "kind" => "image"
        }

      _ ->
        %{
          "key" => f.file_uuid,
          "src" => urls["large"] || urls["medium"] || urls["small"],
          "width" => Map.get(f, :width),
          "height" => Map.get(f, :height),
          "rotation" => rot,
          "actual" => true,
          "kind" => "image"
        }
    end
  end

  defp gallery_item(f) do
    %{
      "key" => f.file_uuid,
      "kind" => to_string(Map.get(f, :file_type) || "file"),
      "label" => Map.get(f, :filename) || ""
    }
  end

  defp gallery_rotation(deg) when is_integer(deg), do: Integer.mod(deg, 360)

  defp gallery_rotation(deg) when is_binary(deg) do
    case Integer.parse(deg) do
      {n, _} -> Integer.mod(n, 360)
      :error -> 0
    end
  end

  defp gallery_rotation(_), do: 0

  # NOTE: `tessera_sources/1` + `maybe_append_layer/4` were removed in
  # the Fresco 0.5 / Etcher 0.3 migration. Tessera 0.2 was OpenSeadragon-
  # backed (Fresco 0.1.x); Fresco 0.5 dropped OSD entirely, so the
  # Tessera layer no longer attaches. Restore once a Fresco 0.5-compatible
  # Tessera (or replacement) ships and `<Tessera.layer>` is wired back
  # into the file-zoom heex.

  # Build a "Folder1 / Folder2 / ..." path string from a folder uuid.
  # Returns nil at root so callers can render a `/` placeholder. Shared
  # by `enrich_files` (per-file folder_path) and `folder_list_path`
  # (single per-render path for the folder list view).
  @doc false
  def breadcrumb_path(nil), do: nil

  def breadcrumb_path(uuid) do
    case Storage.folder_breadcrumbs(uuid) do
      [] -> nil
      chain -> Enum.map_join(chain, " / ", & &1.name)
    end
  end

  # Path shown in the list-view folder rows' Path column. All folders
  # displayed share the same parent (children of @current_folder, or of
  # the scope when at the scoped root), so we compute it once per render
  # instead of recomputing per row — the previous `folder_parent_path/1`
  # did one breadcrumbs walk per folder, an N+1 over identical work.
  def folder_list_path(nil, scope_id), do: breadcrumb_path(scope_id)
  def folder_list_path(%{uuid: uuid}, _scope_id), do: breadcrumb_path(uuid)

  def format_file_size(bytes), do: Format.bytes(bytes, base: 1000, decimals: 2)

  def delete_selected_confirm(selected_files, selected_folders, filter_trash) do
    file_count = MapSet.size(selected_files)
    folder_count = MapSet.size(selected_folders)

    # The wording must match what the handler actually does: folders are
    # deleted RECURSIVELY (their whole subtree rides along, nothing moves to
    # the parent), and inside the trash view every branch is permanent.
    cond do
      filter_trash and folder_count > 0 and file_count > 0 ->
        files = ngettext("%{count} file", "%{count} files", file_count)
        folders = ngettext("%{count} folder", "%{count} folders", folder_count)

        gettext(
          "Permanently delete %{files} and %{folders} (including all folder contents)? This cannot be undone.",
          files: files,
          folders: folders
        )

      filter_trash and folder_count > 0 ->
        ngettext(
          "Permanently delete %{count} folder and all its contents? This cannot be undone.",
          "Permanently delete %{count} folders and all their contents? This cannot be undone.",
          folder_count
        )

      filter_trash ->
        ngettext(
          "Permanently delete %{count} file? This cannot be undone.",
          "Permanently delete %{count} files? This cannot be undone.",
          file_count
        )

      folder_count > 0 and file_count > 0 ->
        files = ngettext("%{count} file", "%{count} files", file_count)
        folders = ngettext("%{count} folder", "%{count} folders", folder_count)

        gettext(
          "Move %{files} and %{folders} (including all folder contents) to trash?",
          files: files,
          folders: folders
        )

      folder_count > 0 ->
        ngettext(
          "Move %{count} folder and all its contents to trash?",
          "Move %{count} folders and all their contents to trash?",
          folder_count
        )

      true ->
        ngettext("Move %{count} file to trash?", "Move %{count} files to trash?", file_count)
    end
  end

  # Known audio extensions — matched so audio files still get a music note in
  # the grid/list/stack views even when an upload's generic
  # `application/octet-stream` mime classified them as a document (mirrors the
  # viewer's detection).
  @audio_extensions ~w(.mp3 .wav .ogg .oga .m4a .aac .flac .opus .weba .mid .midi)

  # Icon for a whole file map: audio is detected by mime/type OR extension, so
  # mp3s show a music note regardless of how they were classified; everything
  # else falls back to the file_type-based icon.
  def file_icon_for(file) do
    if audio_file?(file), do: "hero-musical-note", else: file_icon(file.file_type)
  end

  def audio_file?(file) do
    mime = Map.get(file, :mime_type)
    name = Map.get(file, :filename)

    (is_binary(mime) and String.starts_with?(mime, "audio/")) or
      Map.get(file, :file_type) == "audio" or
      (is_binary(name) and String.ends_with?(String.downcase(name), @audio_extensions))
  end

  # Display label for a file's type — "AUDIO" for audio files (mirrors
  # file_icon_for/1's detection), otherwise the uppercased file_type.
  def file_type_label(file) do
    if audio_file?(file), do: "AUDIO", else: String.upcase(file.file_type || "FILE")
  end

  def file_icon("image"), do: "hero-photo"
  def file_icon("video"), do: "hero-play-circle"
  def file_icon("audio"), do: "hero-musical-note"
  def file_icon("pdf"), do: "hero-document-text"
  def file_icon("document"), do: "hero-document"
  def file_icon(_), do: "hero-document-arrow-down"
end
