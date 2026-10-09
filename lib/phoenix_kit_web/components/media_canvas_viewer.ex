defmodule PhoenixKitWeb.Components.MediaCanvasViewer do
  # PhoenixKitComments is an optional sibling package — silence undefined
  # warnings for parent apps that don't install it. The comments_enabled?/0
  # helper guards every actual call at runtime with Code.ensure_loaded?/1.
  @compile {:no_warn_undefined, [PhoenixKitComments, PhoenixKitComments.Web.CommentsComponent]}

  @moduledoc """
  Per-file viewer LiveComponent: `<Fresco.canvas>` + `<Etcher.layer>` for
  images, video / PDF / icon fallback for other types, plus a sidebar
  with filename + Download + metadata + comments thread. Owns the
  annotation lifecycle (composer popover, persistence sync via
  `EtcherAdapter`, the patch-shape / delete-shape JS bridges).

  Shared between `MediaBrowser` (admin file grid → click image → modal)
  and `MediaViewer` (lightbox embedded by `MediaGallery` and other
  consumers). Both parents own their own modal shell + prev/next
  navigation; this component is just the per-file content.

  ## Required assigns

    * `:id` — DOM id, **must include the file uuid** so the parent's
      prev/next navigation remounts the component on file change (and
      Fresco's `phx-update="ignore"` canvas DOM is replaced wholesale
      with the new file's image).
    * `:file` — curated file map (`%{file_uuid, mime_type, urls,
      filename, file_type, size, inserted_at, ...}`). Same shape
      `MediaBrowser`'s `uploaded_files` carries.
    * `:current_user` — logged-in user; nil-tolerant. When nil the
      composer + comments thread don't render (no user to attribute
      a comment to).
    * `:parent_id` — DOM id of the *outer* LiveComponent (the modal
      host). Currently unused by this component, but kept on the
      assigns map so future cross-component send_updates have a
      target without re-plumbing the API.

  ## A board instead of a file

  Pass `:board` (and no `:file`) to draw on an EMPTY canvas — a projects
  whiteboard, say: `%{target_type: "projects_whiteboard", target_uuid:
  board.uuid, width: 1920, height: 1080, background: nil}`. Fresco renders
  the scene with zero images (`infinite_canvas`), Etcher draws over it,
  and every shape persists against the target pair instead of a file
  (V183). No file means no rotation, no thumbnail job, no comment thread
  and no sidebar — the board is the canvas and its tools. The id should
  include the target uuid for the same remount reason as a file.

  ## Optional assigns

    * `:can_annotate` (default `true`) — whether THIS viewer may change
      the drawings. `false` is read-only: every shape arrives locked
      (Etcher's `readonly`, so it renders and tooltips but cannot be
      moved, resized, deleted or edited), the drawing toolbar and the
      pencil are gone, and the server refuses `etcher:annotations-changed`
      / `etcher:shape-drawn` outright — Etcher's flag is UX, this is the
      boundary. Hosts pass their own write permission (a project member's
      `can_write`); the default keeps every existing host as it was.
    * `:viewer_only` (default `false`) — render only the canvas /
      composer column; suppresses the close button and the sidebar
      (filename + Download + metadata + comments). Used by
      standalone-page hosts like `MediaDetail` that have their own
      surrounding chrome (admin actions, metadata editor, file
      details).
    * `:edit_target` (default `nil`) — `{module, id}` of a LiveComponent
      that opens the image editor. When set, the sidebar of an editable
      image shows "Edit image", which sends it
      `send_update(module, id: id, open_image_editor: file_uuid)`.
      `MediaBrowser` passes itself.
    * `:write_scope` (default `nil`) — the host's scope folder uuid. What
      this component writes onto the FILE row (title/description, a
      persisted rotation) shows in every folder holding the file, so a
      scoped host must not write a file that is merely linked into its
      scope — a content duplicate someone else uploaded first is theirs.
      With a scope set, those writes need the file's HOME folder inside it
      (`Storage.within_scope?/2`); the editor is not offered otherwise and
      a rotation stays view-only. `nil` means unscoped. `MediaBrowser`
      passes its own scope, the rule its grid rotation already follows.
    * `:own_files_only`, `:write_library_uuid`, `:viewer_uuid` (default `nil`) —
      the browser's uploader, library and visibility restrictions. Every file
      metadata or rotation write checks them against the current database row.
    * `:details_path` (default `nil`) — when set, the sidebar shows an
      "Open details page" button navigating to this path. Admin-context
      hosts (`MediaBrowser` with `admin={true}`) pass the file's
      `/admin/media/:uuid` page; public hosts leave it off.
    * `:featured` (default `nil`) — mirrors `MediaBrowser`'s own
      `:featured` attr (`nil` = off, or `%{uuid: uuid | nil}`). When set
      and the open file is an image, the sidebar shows a "Set as
      featured" / "Unset featured" button that posts `"set_featured"` /
      `"unset_featured"` straight to `:parent_id` (same `phx-target`
      routing the close/prev/next buttons use) — this component does
      not own the pointer and has no event handler of its own for it.
  """

  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Annotations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.FileDetails
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Format

  # Etcher's toolbar color slots are a single palette shared across every
  # Fresco viewer this user opens — stored in their `custom_fields`
  # ("user meta") under this key, not per-file like annotations.
  #
  # There is deliberately NO default palette here. A user with nothing
  # saved gets `nil`, and `<Etcher.layer colors={nil}>` omits the attr,
  # so Etcher seeds its slots from its own current presets. We used to
  # keep a copy of those presets as a constant, and it went stale the
  # way copies do: Etcher moved from pastels to full-strength hues
  # (0.16, 2026-09-20 — the pastels read as washed out over a
  # photograph) and this list kept seeding the old pastels, so anyone
  # who reset their annotation settings — or had never saved a palette —
  # drew in colors the rest of the product had moved off of.
  @etcher_colors_key "etcher_colors"

  # The palette arrives from a client JS hook, so it's untrusted: keep only
  # short color-shaped strings and cap the count before persisting into the
  # user's `custom_fields`. Blocks arbitrary/oversized JSON from being stored
  # and fed back into `<Etcher.layer colors={…}>`. Permissive on format (hex /
  # rgb() / hsl() / named) but bounded in length and count.
  @max_etcher_colors 24
  @etcher_color_format ~r/\A[#0-9a-zA-Z(),.%\s]{1,32}\z/

  # Etcher's global stroke defaults — the "ink" (line width / opacity / dash)
  # every new stroke shape adopts — are, like the color palette, one set per
  # user shared across every viewer, not per-file. Stored in `custom_fields`
  # ("user meta") under this key; seeded from the saved value until the user
  # edits the toolbar sliders. Defaults mirror Etcher's own built-in fallback.
  @etcher_line_params_key "etcher_line_params"
  @default_etcher_line_params %{"width" => 2, "opacity" => 1, "dash" => "solid"}
  @etcher_dash_values ~w(solid dashed dotted)
  # Label font size, when the user has pinned one. Deliberately absent from
  # the defaults above: having no value is what "size each label by its own
  # box" means, and that is what labels did before the control existed, so a
  # default here would silently pin every board to one size. Limits match the
  # control's own.
  @etcher_font_size_range {6, 200}

  # Whether the info sidebar (filename / Download / metadata / comments) is
  # collapsed to give the viewer the full popup width. Per-user, one value
  # across every viewer — stored in `custom_fields` ("user meta") like the
  # Etcher palette, so it survives prev/next remounts, reopen, and reload.
  @viewer_info_collapsed_key "media_viewer_info_collapsed"

  # Whether the viewer opens straight into the annotation editor (Etcher
  # armed, toolbar up) instead of on the burned copy. Per-user opt-in,
  # stored in `custom_fields` like the sidebar flag above and toggled on
  # the profile settings page's "Annotation tools" section — the shipped
  # default stays the burned picture, because most people open a file to
  # look at it, not to work on it. Honored only where it means something:
  # an image, with annotation rights.
  @viewer_open_annotating_key "media_viewer_open_annotating"

  # Canvas extent used when the file row recorded no dimensions. Sets only
  # the coordinate space — the image itself keeps its true ratio, see
  # put_natural_size/2.
  @placeholder_canvas_edge 1000

  # ──────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:viewer_canvas, nil)
     # Opens showing the burned copy when there is one: a picture with its
     # markup in it is what someone came to look at, and it is the thing
     # they can right-click and send on. The eye switches to the live
     # layer, which is the one you can edit.
     |> assign(:burn_mode, true)
     |> assign(:burn_canvas, nil)
     # The eye, while the burned copy is up: true means the markup is
     # hidden and the clean original is on screen instead. Deliberately
     # session state and nothing more — every open starts with the
     # markup showing, and the choice is never persisted.
     |> assign(:etchings_hidden, false)
     |> assign(:auto_annotate, false)
     |> assign(:burn_version, nil)
     |> assign(:viewer_annotations, [])
     |> assign(:replying_annotation_uuid, nil)
     |> assign(:reply_parent_uuid, nil)
     |> assign(:etcher_colors, nil)
     |> assign(:etcher_line_params, @default_etcher_line_params)
     |> assign(:viewer_only, false)
     |> assign(:can_annotate, true)
     |> assign(:viewer_rotation, 0)
     |> assign(:persist_rotation, false)
     |> assign(:rotation_status, nil)
     |> assign(:rotation_status_token, 0)
     |> assign(:sidebar_collapsed, false)
     |> assign(:details_path, nil)
     |> assign(:edit_target, nil)
     |> assign(:write_scope, nil)
     |> assign(:own_files_only, nil)
     |> assign(:write_library_uuid, nil)
     |> assign(:viewer_uuid, nil)
     |> assign(:file_writable, true)
     |> assign(:featured, nil)
     |> assign(:media_meta_status_token, 0)}
  end

  @impl true
  def update(%{action: :annotation_composer_posted}, socket) do
    # The reply landed under the master comment — refresh so the sidebar
    # thread, the tooltip preview, and the on-shape badge all pick it up.
    {:ok, close_reply_compose(socket)}
  end

  # Comment activity elsewhere in the LV (sidebar delete, another
  # session's post relayed by the host) — reload annotations so the
  # tooltip's comment_* fields and the on-shape badges match the table,
  # and patch every in-DOM shape (the canvas is phx-update="ignore";
  # patch-shape is the only road in).
  def update(%{action: :refresh_annotations}, socket) do
    {:ok, refresh_annotations(socket)}
  end

  # A burn landed for the file this viewer is showing — from a second
  # device, or from the editor that just closed here. Only this component
  # knows whether it may be taken: in burn mode the canvas IS the picture
  # and swapping it for a newer one is the whole point; with the editor
  # open the shapes on screen are the user's own, and replacing the board
  # under them is not a refresh, it is an interruption. The parent pokes
  # unconditionally and leaves the judgement here.
  def update(%{burn_refreshed: file}, socket) when is_map(file) do
    {:ok, apply_burn_refresh(socket, file)}
  end

  def update(%{action: :annotation_composer_cancelled}, socket) do
    # Nothing to roll back: shapes are never held hostage by the reply
    # popup. (If Reply had just lazily created the master comment, it
    # stays — it's the shape's topic row, dated at the shape's creation,
    # and the next Reply threads under it.)
    {:ok,
     socket
     |> assign(:replying_annotation_uuid, nil)
     |> assign(:reply_parent_uuid, nil)}
  end

  # Auto-hide timer for the sidebar's title/description save-status.
  # Token-guarded like the rotation pill below: a second Save inside the
  # two-second window bumps the token, so the earlier timer no longer
  # wipes the status the later save just put up.
  def update(%{action: :clear_media_meta_status, token: token}, socket) do
    if socket.assigns[:media_meta_status_token] == token do
      {:ok, assign(socket, :media_meta_status, nil)}
    else
      {:ok, socket}
    end
  end

  # Auto-hide timer for the rotation save-status pill (scheduled by
  # show_rotation_status/2). Token-guarded: a burst of saves bumps the
  # token, so only the latest timer clears the pill.
  def update(%{action: :clear_rotation_status, token: token}, socket) do
    if socket.assigns[:rotation_status_token] == token do
      {:ok, assign(socket, :rotation_status, nil)}
    else
      {:ok, socket}
    end
  end

  # Inline title edit posted from the sidebar's CommentsComponent.
  # The payload uses the comments package's generic decoration
  # vocabulary (`metadata_key`, `metadata_value`, `label`); we
  # translate to annotation-domain terms here. Same wire as
  # `finalize_annotation_compose/3` minus the composer-specific
  # bookkeeping: write → reload annotations → rebuild canvas →
  # push patch-shape so the tooltip reflects the new title →
  # CommentsComponent's next render picks up the fresh
  # `comment_decorations` via the heex helper.
  def update(%{action: :annotation_title_updated} = assigns, socket) do
    {:ok, apply_annotation_title_update(socket, assigns[:metadata_value], assigns[:label])}
  end

  def update(assigns, socket) do
    file = assigns[:file]
    board = if is_nil(file), do: normalize_board(assigns[:board]), else: nil

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:file, file)
      |> assign(:board, board)
      |> assign(:current_user, assigns[:current_user])
      |> assign(:parent_id, assigns[:parent_id])
      |> assign(:has_prev, assigns[:has_prev] || false)
      |> assign(:has_next, assigns[:has_next] || false)
      |> assign(:viewer_only, assigns[:viewer_only] || false)
      |> assign(:can_annotate, assigns[:can_annotate] != false)
      # Opt-in: hosts that pass `persist_rotation` write a rotation back to the
      # shared file row (see handle_event "fresco:rotate") — the media browser
      # popup and the detail page do, so any user who can open and rotate a file
      # saves its orientation for everyone. Hosts that don't opt in (the gallery
      # lightbox) still seed `initial_rotation` below so the saved orientation
      # shows; they just don't write.
      |> assign(:persist_rotation, assigns[:persist_rotation] || false)
      |> assign(:details_path, assigns[:details_path])
      |> assign(:edit_target, assigns[:edit_target])
      |> assign(:write_scope, assigns[:write_scope])
      |> assign(:own_files_only, assigns[:own_files_only])
      |> assign(:write_library_uuid, assigns[:write_library_uuid])
      |> assign(:viewer_uuid, assigns[:viewer_uuid])
      |> assign(:featured, assigns[:featured])
      |> assign_new(:media_meta, fn -> %{title: "", alt: "", description: ""} end)
      |> assign_new(:media_meta_own, fn -> %{title: "", alt: "", description: ""} end)
      |> assign_new(:media_meta_placeholders, fn -> %{title: "", alt: "", description: ""} end)
      |> assign_new(:media_meta_lang, fn -> nil end)
      |> assign_new(:media_meta_lang_name, fn -> nil end)
      |> assign_new(:file_row, fn -> nil end)
      |> assign_new(:file_exif, fn -> nil end)
      |> assign_new(:file_geo, fn -> {nil, nil} end)
      |> assign_new(:exif_tags, fn -> nil end)
      |> assign_new(:exif_status, fn -> nil end)
      |> assign_new(:media_meta_langs, fn -> [] end)
      |> assign_new(:media_meta_values, fn -> %{} end)
      |> assign_new(:media_tags, fn -> [] end)
      |> assign_new(:media_details_open, fn -> false end)
      |> assign_new(:media_meta_status, fn -> nil end)
      |> assign_new(:media_meta_status_token, fn -> 0 end)

    # First mount (or file changed via re-mount): hydrate annotations
    # + canvas. Because the id encodes the file uuid, the parent's
    # prev/next destroys this LC and mounts a fresh one, so this
    # branch effectively only runs at mount time.
    socket =
      cond do
        socket.assigns[:viewer_canvas] == nil and is_map(file) ->
          annotations = load_annotations_for(file.file_uuid)

          socket
          |> assign(:viewer_annotations, annotations)
          |> assign(:viewer_canvas, build_viewer_canvas(file, annotations, locked?(socket)))
          |> assign(:burn_canvas, build_burn_canvas(file))
          |> assign(:burn_version, Map.get(file, :burn_fingerprint))
          # Seed everything that lives on the file's own DB row — the saved
          # rotation (so the image paints already-rotated on open, no flash
          # of unrotated → rotated) and the title/description metadata the
          # sidebar shows. One read for both: they are fields of the same
          # row, and the parent-passed map does not carry `metadata`.
          |> seed_file_row_state(file.file_uuid)
          # Read fresh from the DB (not the parent-passed struct) so the
          # palette is correct even on modal prev/next after an in-session
          # edit, where the parent's `current_user` may be stale. ONE read
          # for all three: they are three fields of the same row, and this
          # used to fetch it three times per open.
          |> then(fn s ->
            prefs = viewer_user_prefs(assigns[:current_user])

            s
            |> assign(:etcher_colors, load_user_colors(prefs))
            |> assign(:etcher_line_params, load_user_line_params(prefs))
            |> assign(:sidebar_collapsed, load_sidebar_collapsed(prefs))
            |> maybe_open_annotating(prefs, file)
          end)

        socket.assigns[:viewer_canvas] == nil and is_map(board) ->
          annotations = load_annotations_for_target(board.target_type, board.target_uuid)

          socket
          |> assign(:viewer_annotations, annotations)
          |> assign(:viewer_canvas, build_board_canvas(board, annotations, locked?(socket)))
          |> assign(:viewer_rotation, 0)
          |> then(fn s ->
            prefs = viewer_user_prefs(assigns[:current_user])

            s
            |> assign(:etcher_colors, load_user_colors(prefs))
            |> assign(:etcher_line_params, load_user_line_params(prefs))
          end)
          |> assign(:sidebar_collapsed, true)

        true ->
          socket
      end

    {:ok, socket}
  end

  # The `:board` assign, validated: a target pair plus a canvas extent
  # (defaults to Full HD) and an optional CSS background for the stage.
  # A malformed board is nil — the component then renders nothing rather
  # than a canvas whose shapes could never persist.
  defp normalize_board(%{target_type: type, target_uuid: uuid} = board)
       when is_binary(type) and type != "file" and is_binary(uuid) do
    %{
      target_type: type,
      target_uuid: uuid,
      width: positive_int(Map.get(board, :width), 1920),
      height: positive_int(Map.get(board, :height), 1080),
      background: Map.get(board, :background)
    }
  end

  defp normalize_board(_), do: nil

  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n
  defp positive_int(_, default), do: default

  # ──────────────────────────────────────────────────────────────
  # Etcher events
  # ──────────────────────────────────────────────────────────────

  # Bulk persistence sync. Etcher 0.3 emits this on every shape
  # mutation (create, update, drag, delete, color, undo/redo, …) with
  # the full current annotations list. Diff against our last-known
  # state (`viewer_annotations`) to dispatch row-level
  # create/update/delete via `EtcherAdapter`, then reload from DB to
  # pick up fresh comment metadata and rebuild the canvas blob.
  #
  # Persist failures get logged so a stale CHECK constraint (e.g. a
  # new kind that hasn't migrated yet) doesn't silently drop
  # annotations — without this the only symptom is "tooltip shows the
  # kind name with no title sibling," which leads to long debugging
  # detours.
  @impl true
  def handle_event("etcher:annotations-changed", %{"annotations" => new_annotations}, socket) do
    case {socket.assigns.can_annotate, socket.assigns[:file], socket.assigns[:board]} do
      # Read-only viewer: the client should never send this (its shapes
      # are locked and its tools gone) — a crafted one changes nothing.
      {false, _, _} -> {:noreply, socket}
      {true, %{} = file, _} -> {:noreply, sync_annotations(socket, file, new_annotations)}
      {true, nil, %{} = board} -> {:noreply, sync_annotations(socket, board, new_annotations)}
      _ -> {:noreply, socket}
    end
  end

  # Etcher's color-save hook. The toolbar palette is per-user (one set of
  # slots across every viewer), not per-file, so we ignore the fresco_id
  # and persist the slots into the user's `custom_fields`, merging into a
  # freshly-read copy so a concurrent change elsewhere isn't clobbered.
  # `update_user_custom_fields/2` broadcasts `phoenix_kit_user_updated`,
  # so hosts that subscribe refresh their `current_user` automatically.
  def handle_event("etcher:colors-changed", %{"colors" => colors}, socket) do
    with %{uuid: uuid} = user <- socket.assigns[:current_user],
         [_ | _] = clean <- sanitize_colors(colors) do
      fresh = Auth.get_user(uuid) || user
      merged = Map.put(fresh.custom_fields || %{}, @etcher_colors_key, clean)

      # Internal editor preference — skip the custom-field-definition
      # registration so it never surfaces in the admin Custom Fields list.
      case Auth.update_user_custom_fields(fresh, merged, ensure_definitions: false) do
        {:ok, updated} ->
          {:noreply, socket |> assign(:current_user, updated) |> assign(:etcher_colors, clean)}

        {:error, _changeset} ->
          {:noreply, socket}
      end
    else
      # No user, or nothing valid survived sanitization — ignore the event
      # rather than persisting garbage or wiping the saved palette.
      _ -> {:noreply, socket}
    end
  end

  # Etcher's line-params save hook — the twin of `colors-changed`. The global
  # stroke defaults (width / opacity / dash for new shapes) are per-user, one
  # set across every viewer, so we ignore the fresco_id and persist the map
  # into the user's `custom_fields`, merging into a freshly-read copy so a
  # concurrent change elsewhere isn't clobbered. `update_user_custom_fields/2`
  # broadcasts `phoenix_kit_user_updated` for subscribed hosts to refresh.
  def handle_event("etcher:line-params-changed", %{"line_params" => params}, socket) do
    with %{uuid: uuid} = user <- socket.assigns[:current_user],
         %{} = clean <- sanitize_line_params(params) do
      fresh = Auth.get_user(uuid) || user
      merged = Map.put(fresh.custom_fields || %{}, @etcher_line_params_key, clean)

      # Internal editor preference — see the colors handler above.
      case Auth.update_user_custom_fields(fresh, merged, ensure_definitions: false) do
        {:ok, updated} ->
          {:noreply,
           socket |> assign(:current_user, updated) |> assign(:etcher_line_params, clean)}

        {:error, _changeset} ->
          {:noreply, socket}
      end
    else
      # No user, or nothing valid survived sanitization — ignore rather than
      # persisting garbage or wiping the saved ink.
      _ -> {:noreply, socket}
    end
  end

  # Fires only on a brand-new user draw (Etcher's `_finalizeShape`).
  # Deliberately a no-op: NO kind opens the composer at draw time
  # anymore. Drawing is just drawing — the shape (and its inline-typed
  # label, for the label-bearing kinds) persists via
  # `annotations-changed`, and the comment system is only entered when
  # someone presses Reply on the shape's tooltip. The event stays
  # handled so an older etcher bundle emitting it doesn't crash the LV.
  def handle_event("etcher:shape-drawn", _params, %{assigns: %{can_annotate: false}} = socket),
    do: {:noreply, socket}

  def handle_event("etcher:shape-drawn", _params, socket) do
    {:noreply, socket}
  end

  # Reply pressed on a shape's tooltip (via the `etcher:tooltip-action`
  # bridge in phoenix_kit.js). Ensure the shape's MASTER comment exists —
  # the topic row its discussion hangs under, content = the shape's label
  # (or kind), author = the shape's creator when known, `inserted_at`
  # backdated to the shape's creation — then open the body-only reply
  # popup threading under it.
  #
  # The tooltip still offers Reply on a readonly shape. The button is UX;
  # this clause is the boundary, same as `etcher:annotations-changed`.
  def handle_event("annotation_reply", _params, %{assigns: %{can_annotate: false}} = socket),
    do: {:noreply, socket}

  def handle_event("annotation_reply", %{"uuid" => uuid}, socket) do
    with %{} <- socket.assigns[:current_user],
         %{} = ann <- find_viewer_annotation(socket, uuid),
         {:ok, master_uuid} <- ensure_master_comment(socket, ann) do
      {:noreply,
       socket
       |> assign(:replying_annotation_uuid, to_string(ann.uuid))
       |> assign(:reply_parent_uuid, master_uuid)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Collapse/expand the info sidebar so the viewer gets the full popup
  # width (the win is biggest on small screens). Persisted per-user so
  # prev/next — which remounts this component — and later opens keep
  # the choice. Helpers live in "Info sidebar collapse" below.
  def handle_event("edit_image", _params, socket) do
    case {socket.assigns.edit_target, socket.assigns.file} do
      {{module, id}, %{file_uuid: uuid}} -> send_update(module, id: id, open_image_editor: uuid)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("toggle_media_details", _params, socket) do
    {:noreply, assign(socket, :media_details_open, !socket.assigns.media_details_open)}
  end

  # The photo's EXIF. It tells where a photo was taken, so it is offered only
  # where the title editor is (a host that gave the viewer a road to the metadata
  # editor); the clauses refuse everyone else, as `save_media_details` does. Reading
  # records the summary and the position, so it also needs a file the host may write.
  def handle_event(event, _params, %{assigns: %{details_path: nil, edit_target: nil}} = socket)
      when event in ["read_exif", "show_exif", "hide_exif"],
      do: {:noreply, socket}

  def handle_event("read_exif", _params, socket) do
    with %{file_uuid: uuid} <- socket.assigns.file,
         %Storage.File{} = row <- Storage.get_file(uuid),
         true <- file_writable?(row, socket.assigns),
         {:ok, row} <- Storage.read_exif(row) do
      {:noreply, assign_exif(socket, row)}
    else
      _ -> {:noreply, assign(socket, :exif_status, :error)}
    end
  end

  def handle_event("show_exif", _params, socket) do
    with %{file_uuid: uuid} <- socket.assigns.file,
         {:ok, tags} <- Storage.exif_tags(uuid) do
      {:noreply, socket |> assign(:exif_tags, tags) |> assign(:exif_status, nil)}
    else
      _ -> {:noreply, assign(socket, :exif_status, :error)}
    end
  end

  def handle_event("hide_exif", _params, socket) do
    {:noreply, assign(socket, :exif_tags, nil)}
  end

  # Hosts that never offered the editor: refuse the write outright. The
  # form is only rendered where `can_edit_media_meta?/2` holds, but the
  # sidebar itself renders for anyone who can open the viewer — including
  # the anonymous visitor of a readonly `MediaGallery` lightbox, which
  # passes neither assign — and a hidden form is not a boundary. Same rule
  # the `can_annotate: false` clauses above follow: the template flag is
  # UX, this clause is the boundary. Silent no-op, not an error status:
  # the UI these users see has nothing to report a failure in.
  def handle_event(
        "save_media_details",
        _params,
        %{assigns: %{details_path: nil, edit_target: nil}} = socket
      ),
      do: {:noreply, socket}

  # Saves the sidebar's title / alt text / description for every language the
  # form has a block for (`details[<language>][title]`: a tab per language, one
  # Save) — the same text, through the same `Storage` write, as the admin detail
  # page's editor, so the two surfaces read each other's writes. A flat
  # `title` / `alt` / `description` (the form from before the tabs) is the
  # page's language. That write re-reads the row and replaces only the languages
  # whose text changed: rotation, tags and the other languages survive. A key
  # the form did not send keeps its value.
  def handle_event("save_media_details", params, socket) do
    lang = socket.assigns[:media_meta_lang] || content_language()
    allowed = Enum.map(socket.assigns[:media_meta_langs] || [], & &1.code)

    by_lang =
      params
      |> Map.get("details", params)
      |> FileDetails.by_language(lang, allowed)
      |> Map.new(fn {code, attrs} ->
        {code, Map.new(attrs, fn {field, value} -> {field, text_param(value)} end)}
      end)

    with %{file_uuid: uuid} <- socket.assigns.file,
         %Storage.File{} = row <- Storage.get_file(uuid),
         # The boundary, on the row as it is NOW: the form is only offered
         # for a writable file, but a hidden form is not a boundary.
         true <- file_writable?(row, socket.assigns),
         {:ok, row} <-
           Storage.update_file_details_languages(
             row,
             by_lang,
             [original_values: socket.assigns[:media_meta_values]] ++ tags_metadata(params)
           ) do
      token = (socket.assigns[:media_meta_status_token] || 0) + 1

      Phoenix.LiveView.send_update_after(
        __MODULE__,
        [id: socket.assigns.id, action: :clear_media_meta_status, token: token],
        2000
      )

      {:noreply,
       socket
       |> assign_media_meta(row, lang)
       |> assign(:media_meta_status, :saved)
       |> assign(:media_meta_status_token, token)}
    else
      _ -> {:noreply, assign(socket, :media_meta_status, :error)}
    end
  end

  # The eye: burned copy ⇄ the live layer over the picture.
  #
  # Switching flips the id of the canvas below it, which is what makes
  # LiveView tear the old one down and mount the new one — Fresco's canvas
  # is `phx-update="ignore"`, so a patch would leave the previous image and
  # extent in place.
  # A burn just landed. The canvas built at mount points at the copy that
  # existed THEN — a signed URL carrying the old checksum — so switching to
  # the burned view would show yesterday's rendering until someone reloaded
  # the page. Rebuild it around what was just stored.
  #
  # The id carries a version for the same reason it carries the mode:
  # Fresco's canvas is `phx-update="ignore"`, so an unchanged id means the
  # old image and extent stay exactly where they are.
  #
  # The canvas is built from what is STORED for the file this viewer has
  # open, not from a URL and size the client sends: the client only says a
  # burn landed and which slot it prefers. The version is the stored bytes'
  # own (`URLSigner.version/1`), so it changes exactly when a new burn does —
  # the old `width * height` fallback collided for two burns of one size.
  def handle_event("burn_stored", params, socket) do
    with %{file_uuid: uuid} when is_binary(uuid) <- socket.assigns[:file],
         variant when variant in ~w(burned_large burned) <- params["variant"] || "burned",
         %{width: w, height: h} = instance
         when is_integer(w) and w > 0 and is_integer(h) and h > 0 <-
           Storage.get_file_instance_by_name(uuid, variant) do
      url =
        URLSigner.signed_url(uuid, variant,
          version: instance,
          locale: :none,
          private: Libraries.private_file?(Storage.get_file(uuid) || %{})
        )

      {:noreply,
       socket
       |> assign(:burn_canvas, burn_canvas(url, w, h))
       |> assign(:burn_version, URLSigner.version(instance))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_burn_mode", params, socket) do
    to_live? = socket.assigns[:burn_mode]

    {:noreply,
     socket
     |> assign(:burn_mode, not to_live?)
     # A mode switch always lands with the markup showing: the editor
     # edits shapes it can see, and coming back lands on the burned copy.
     |> assign(:etchings_hidden, false)
     # Pressed the pencil rather than the eye: the live layer is what it
     # needs, but what was asked for was to draw.
     |> assign(:auto_annotate, to_live? and params["annotate"] == true)}
  end

  # The eye: markup shown ⇄ the clean original. The burned picture IS the
  # markup — baked into the bitmap — so hiding the etchings cannot be a
  # client-side visibility flip; this swaps the canvas for the original
  # with nothing over it (see the heex), which is also what makes
  # right-click → Copy image copy a clean picture.
  #
  # Pressed in the editor (live mode), the eye ends the session too:
  # whatever was drawn is already captured for the burn by the hook
  # (which composes BEFORE pushing this, while the overlay still
  # exists), and the viewer lands on the clean picture. Un-hiding from
  # there goes to the burned copy, not back into the editor — "show me
  # the markup" is a look, and the pencil is how you ask to work.
  def handle_event("toggle_etchings", _params, socket) do
    if socket.assigns[:burn_mode] do
      {:noreply, assign(socket, :etchings_hidden, not socket.assigns[:etchings_hidden])}
    else
      {:noreply,
       socket
       |> assign(:burn_mode, true)
       |> assign(:etchings_hidden, true)
       |> assign(:auto_annotate, false)}
    end
  end

  def handle_event("toggle_viewer_sidebar", _params, socket) do
    collapsed = not socket.assigns[:sidebar_collapsed]
    persist_sidebar_collapsed(socket.assigns[:current_user], collapsed)
    {:noreply, assign(socket, :sidebar_collapsed, collapsed)}
  end

  # ──────────────────────────────────────────────────────────────
  # Rotation persistence
  # ──────────────────────────────────────────────────────────────

  # Fresco's opt-in server bridge: fires on every rotation change when the
  # canvas is mounted with `persist_rotation`. The rotation lives on the shared
  # file row (`metadata["rotation"]`) — it's the image's saved orientation for
  # every viewer, not a per-user preference — so it persists whenever the host
  # opted in (the browser popup and detail page, for any user). Seeds
  # `initial_rotation` on the next open.
  @impl true
  def handle_event("fresco:rotate", %{"rotation" => rotation}, socket) do
    file = socket.assigns[:file]

    if socket.assigns[:persist_rotation] and is_map(file) do
      {:noreply, persist_rotation(socket, file.file_uuid, normalize_rotation(rotation))}
    else
      {:noreply, socket}
    end
  end

  # Everything the sidebar needs off the file's own row, in one read at
  # viewer-open: the saved orientation (degrees) and the title/description
  # the "Title & description" section shows. A lightweight PK fetch —
  # negligible next to loading the image + annotations. Missing/garbage →
  # unrotated and blank. Never crashes the viewer.
  defp seed_file_row_state(socket, file_uuid) do
    row = Storage.get_file(file_uuid)

    meta =
      case row do
        %{metadata: meta} when is_map(meta) -> meta
        _ -> %{}
      end

    socket =
      socket
      |> assign(:file_writable, file_writable?(row, socket.assigns))
      |> assign(:file_row, file_row_info(row, socket.assigns[:details_path]))
      |> assign(:viewer_rotation, normalize_rotation(Map.get(meta, "rotation")))
      |> assign_exif(row)
      |> assign_media_meta(row, content_language())
      |> assign(:media_meta_status, nil)

    # Open from the start: a section nobody knows to open is a section nobody
    # fills in. (It is not rendered at all when it is empty and uneditable.)
    assign(socket, :media_details_open, true)
  rescue
    _ ->
      socket
      |> assign(:viewer_rotation, 0)
      |> assign(:file_row, nil)
      |> assign_media_meta(nil, nil)
      |> assign(:media_details_open, false)
      |> assign(:media_meta_status, nil)
  end

  # What the sidebar lists besides the file map: the row's state and last
  # change. Who uploaded it and its uuid are for the admin context only (the
  # `details_path` hosts) — a public lightbox shows a photo, not its owner.
  defp file_row_info(%Storage.File{} = row, details_path) do
    admin? = not is_nil(details_path)

    %{
      status: row.status,
      edited?: not is_nil(row.original_file_uuid),
      updated_at: row.updated_at,
      inserted_at: row.inserted_at,
      pages: if(row.mime_type == "application/pdf", do: (row.metadata || %{})["page_count"]),
      uploader: if(admin?, do: uploader_name(row.user_uuid)),
      uuid: if(admin?, do: row.uuid)
    }
  end

  defp file_row_info(_row, _details_path), do: nil

  defp uploader_name(nil), do: nil

  defp uploader_name(user_uuid) do
    case PhoenixKit.Config.get_repo().get(PhoenixKit.Config.get_users_module(), user_uuid) do
      nil -> nil
      user -> user.email
    end
  end

  # The row was changed after it was uploaded (a minute allows for the upload's
  # own processing writing to it).
  defp changed_since_upload?(%{
         updated_at: %DateTime{} = updated,
         inserted_at: %DateTime{} = ins
       }),
       do: DateTime.diff(updated, ins) > 60

  defp changed_since_upload?(_row), do: false

  defp status_label("trashed"), do: gettext("In the trash")
  defp status_label("processing"), do: gettext("Processing")
  defp status_label("failed"), do: gettext("Failed")
  defp status_label(other), do: other

  # The photo's recorded EXIF and position (`nil` EXIF: never read), and the
  # whole-dump view closed.
  defp assign_exif(socket, %Storage.File{} = row) do
    socket
    |> assign(:file_exif, (row.metadata || %{})["exif"])
    |> assign(:file_geo, {row.latitude, row.longitude})
    |> assign(:exif_tags, nil)
    |> assign(:exif_status, nil)
  end

  defp assign_exif(socket, _row) do
    socket
    |> assign(:file_exif, nil)
    |> assign(:file_geo, {nil, nil})
    |> assign(:exif_tags, nil)
    |> assign(:exif_status, nil)
  end

  # The language the text is read and saved in: the page's own. A
  # LiveComponent shares its LiveView's process, so the locale the
  # navigation hook put there is the page's — no host has to pass it.
  defp content_language,
    do: FileDetails.content_language(PhoenixKit.Utils.Multilang.current_locale())

  # `:media_meta` is what the section SHOWS (this language, falling back
  # like any reader); the form holds the language's OWN text, with the
  # primary language's as placeholders — never as values, or an untouched
  # save would store it as the translation.
  defp assign_media_meta(socket, %Storage.File{} = row, lang) do
    opts = [primary: PhoenixKit.Utils.Multilang.primary_language()]
    blank = fn details -> Map.new(details, fn {key, value} -> {key, value || ""} end) end

    tabs = PhoenixKit.Utils.Multilang.build_language_tabs()
    codes = if tabs == [], do: [lang], else: Enum.map(tabs, & &1.code)

    own = fn code -> row |> FileDetails.from_file(code, opts) |> Map.from_struct() |> blank.() end

    socket
    |> assign(:media_meta, blank.(FileDetails.for_locale(row, lang, opts)))
    |> assign(:media_meta_own, own.(lang))
    |> assign(:media_meta_placeholders, blank.(FileDetails.for_locale(row, nil, opts)))
    |> assign(:media_meta_lang, lang)
    |> assign(:media_meta_lang_name, FileDetails.language_name(lang))
    |> assign(:media_meta_langs, tabs)
    |> assign(:media_meta_values, Map.new(codes, &{&1, own.(&1)}))
    |> assign(:media_tags, file_tags(row))
  end

  defp assign_media_meta(socket, _row, _lang) do
    empty = %{title: "", alt: "", description: ""}

    socket
    |> assign(:media_meta, empty)
    |> assign(:media_meta_own, empty)
    |> assign(:media_meta_placeholders, empty)
    |> assign(:media_meta_lang, nil)
    |> assign(:media_meta_lang_name, nil)
    |> assign(:media_meta_langs, [])
    |> assign(:media_meta_values, %{})
    |> assign(:media_tags, [])
  end

  # The tags kept in the row's metadata; anything else there is not a tag.
  defp file_tags(%Storage.File{metadata: %{"tags" => tags}}) when is_list(tags),
    do: Enum.filter(tags, &is_binary/1)

  defp file_tags(_row), do: []

  # More tags than this on one file is a mistake, not a taxonomy.
  @max_tags 50

  # `tags` arrives as one comma-separated field; a form without it leaves them be.
  defp tags_metadata(%{"tags" => tags}) when is_binary(tags) do
    list = tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    [metadata: %{"tags" => Enum.take(list, @max_tags)}]
  end

  defp tags_metadata(_params), do: []

  # Whether THIS host offers the title/description editor. One rule, read
  # by both the template (which form to render) and the save handler
  # (whether to accept the write) — two copies would drift into a hidden
  # form the server still honours. The signal is the host's own opt-in,
  # like `persist_rotation`: a host that already hands the user a road to
  # the metadata editor (the detail page, the image editor) is a host
  # where editing here changes nothing about who may write what.
  defp can_edit_media_meta?(details_path, edit_target),
    do: details_path != nil or edit_target != nil

  # Carry the browser's boundaries into every write in its child viewer.
  defp file_writable?(%Storage.File{} = row, assigns) do
    Storage.within_scope?(row.folder_uuid, assigns[:write_scope]) and
      (is_nil(assigns[:own_files_only]) or row.user_uuid == assigns[:own_files_only]) and
      (is_nil(assigns[:write_library_uuid]) or
         row.library_uuid == assigns[:write_library_uuid]) and
      Storage.viewer_can_see_file?(assigns[:viewer_uuid], row)
  end

  defp file_writable?(_row, _assigns), do: false

  # A form field, or whatever a forged event put in its place.
  defp text_param(value) when is_binary(value), do: String.trim(value)
  defp text_param(_value), do: ""

  defp download_url(url) do
    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "") |> Map.put("dl", "1") |> URI.encode_query()
    URI.to_string(%{uri | query: query})
  end

  defp download_variants(urls) do
    urls
    |> Enum.filter(fn {name, url} -> name not in ["original", "dzi"] and is_binary(url) end)
    |> Enum.sort()
  end

  # Write `rotation` into the file's metadata JSONB, skipping the DB round-trip
  # when it hasn't changed (Fresco fires `rotate` on every change, including the
  # Reset-view snap back to the already-saved home rotation). A transient
  # status pill over the canvas confirms each actual save — the write is
  # otherwise invisible, indistinguishable from a view-only rotation — and
  # surfaces a failure instead of silently dropping the orientation. No-op
  # rotations stay silent. (A pill, not put_flash: component flash doesn't
  # reach the parent layout's flash group, and the pill also works in
  # viewer_only hosts.)
  defp persist_rotation(socket, file_uuid, rotation) do
    case Storage.get_file(file_uuid) do
      %Storage.File{} = file ->
        current = normalize_rotation(Map.get(file.metadata || %{}, "rotation"))

        # A file only LINKED into the host's scope is someone else's to
        # rotate (see `:write_scope`): it turns on screen and nothing is saved.
        if current == rotation or not file_writable?(file, socket.assigns) do
          assign(socket, :viewer_rotation, rotation)
        else
          # On the row as it is NOW: a title or tags saved since `file` was
          # read must survive the rotation.
          case Storage.update_file_metadata(file, &Map.put(&1, "rotation", rotation)) do
            {:ok, _updated} ->
              # Thumbnails render the saved orientation via a CSS transform
              # (MediaThumbnail.rotation_class/1), so a rotation changes what
              # every grid should show — same live-refresh rail the annotated
              # bake uses. Grid-only by design: the viewer this rotation came
              # from must not remount mid-interaction.
              Storage.broadcast_file_thumbnail_updated(file_uuid)

              socket
              |> assign(:viewer_rotation, rotation)
              |> show_rotation_status(:saved)

            {:error, _changeset} ->
              show_rotation_status(socket, :error)
          end
        end

      _ ->
        socket
    end
  rescue
    e ->
      Logger.warning("Failed to persist media rotation for #{file_uuid}: #{inspect(e)}")
      show_rotation_status(socket, :error)
  end

  # How long the save-status pill stays up before auto-hiding.
  @rotation_status_ms 2500

  # Show the pill and schedule its removal. The token invalidates earlier
  # timers, so a rapid rotate burst keeps the pill up for the full window
  # after the LAST save instead of vanishing when the first timer fires.
  defp show_rotation_status(socket, status) do
    token = (socket.assigns[:rotation_status_token] || 0) + 1

    Phoenix.LiveView.send_update_after(
      __MODULE__,
      [id: socket.assigns.id, action: :clear_rotation_status, token: token],
      @rotation_status_ms
    )

    socket
    |> assign(:rotation_status, status)
    |> assign(:rotation_status_token, token)
  end

  # Coerce a rotation to one of the four snapped angles Fresco supports; any
  # other/garbage value collapses to 0 so we never store a bogus orientation.
  defp normalize_rotation(deg) when is_integer(deg) do
    case Integer.mod(deg, 360) do
      n when n in [0, 90, 180, 270] -> n
      _ -> 0
    end
  end

  defp normalize_rotation(deg) when is_binary(deg) do
    case Integer.parse(deg) do
      {n, _} -> normalize_rotation(n)
      :error -> 0
    end
  end

  defp normalize_rotation(_), do: 0

  # ──────────────────────────────────────────────────────────────
  # Info sidebar collapse (see handle_event "toggle_viewer_sidebar")
  # ──────────────────────────────────────────────────────────────

  # Read off the row `viewer_user_prefs/1` hands over, which is where the
  # freshness comes from. Anything but a stored `true` means expanded.
  defp load_sidebar_collapsed(user) when is_map(user) do
    Auth.get_user_field(user, @viewer_info_collapsed_key) == true
  end

  defp load_sidebar_collapsed(_), do: false

  # ──────────────────────────────────────────────────────────────
  # Open-in-editor preference (see @viewer_open_annotating_key)
  # ──────────────────────────────────────────────────────────────

  @doc """
  Whether this user has chosen to open the media viewer straight into
  the annotation editor (Etcher armed, toolbar up) instead of on the
  burned picture.

  The shipped default is `false` — the viewer opens on the picture with
  its markup already in it, which is what most people came to look at.
  This per-user flag is for the people who open files to work on them:
  with it on, the editor is live the moment the popup is, no pencil
  press first. Toggled on the profile settings page ("Annotation
  tools"); anything but a stored `true` means the default.
  """
  def open_annotating?(user) when is_map(user) do
    Auth.get_user_field(user, @viewer_open_annotating_key) == true
  end

  def open_annotating?(_), do: false

  @doc false
  # The custom_fields key the settings page writes. One name, owned here.
  def open_annotating_key, do: @viewer_open_annotating_key

  # Apply the preference at viewer-open. Only where it means something:
  # an image (nothing else has an editor), with annotation rights — a
  # read-only viewer keeps the burned picture whatever the flag says.
  # `auto_annotate` is what makes the hook arm Etcher once the live
  # canvas is up, exactly as if the pencil had been pressed.
  defp maybe_open_annotating(socket, prefs, file) do
    if socket.assigns.can_annotate and image_file?(file) and open_annotating?(prefs) do
      socket
      |> assign(:burn_mode, false)
      |> assign(:auto_annotate, true)
    else
      socket
    end
  end

  @doc """
  Whether the viewer's info sidebar will be open for this user.

  Used by the media browser's instant stand-in to predict the layout it is
  standing in for — the sidebar is open by default, so a stand-in that paints
  the image over the full popup shrinks it a beat later when the real viewer
  mounts, which reads as a flash. Reads the same per-user flag the viewer
  itself loads; `nil` user (or a never-toggled one) means open, matching the
  viewer's default.

  Deliberately reads the user struct it is handed (usually the LiveView
  assign) rather than re-fetching the row: this is a prediction, and the
  stand-in's hook corrects itself from the layout the real viewer actually
  used, so a stale read costs one mispredicted frame at worst.
  """
  def sidebar_open?(user), do: not load_sidebar_collapsed(user)

  @doc """
  The picture's shape as a CSS `aspect-ratio` value, or `nil` for a file that
  has no shape to give.

  The stacked layout sizes the picture pane to this instead of to a share of
  the popup's height. A 1080×2840 window makes the popup 2556px tall and a
  landscape photograph needs about 480 of them: the rest was empty canvas
  above and below the picture, with the details panel pushed to the far
  bottom of a popup the picture had no use for. Sized to the picture, the
  pane asks for the height it needs, the panel sits directly under it, and
  the popup is as tall as the two of them together.

  Rotation is part of the shape. A quarter turn swaps the axes, so the pane
  has to turn with it or a sideways photograph gets a pane the wrong way
  round — taller than the picture and narrower than it needs. A half turn
  leaves the shape alone.

  `nil` for anything with no dimensions recorded — a PDF, an audio file, a
  picture whose probe failed — and the pane falls back to a fixed share of
  the popup, which is what every file used to get.
  """
  def pane_aspect(file, rotation \\ 0) when is_map(file) do
    with w when is_integer(w) <- positive_dimension(Map.get(file, :width)),
         h when is_integer(h) <- positive_dimension(Map.get(file, :height)) do
      if quarter_turn?(rotation), do: "#{h} / #{w}", else: "#{w} / #{h}"
    else
      _ -> nil
    end
  end

  @doc """
  The same shape, for a file nobody is looking at yet.

  Stepping prev/next inside the viewer repaints the instant stand-in with the
  neighbour's bitmap, and the popup is sized to the picture now — so a
  neighbour whose shape nobody announced would hand over by resizing the
  whole box. The browser reads these off the modal's dataset; rotation comes
  from the row, since no viewer has loaded that file's metadata yet.
  """
  def neighbor_pane_aspect(file) when is_map(file),
    do: pane_aspect(file, Map.get(file, :rotation))

  defp positive_dimension(n) when is_integer(n) and n > 0, do: n
  defp positive_dimension(_), do: nil

  defp quarter_turn?(deg), do: Integer.mod(normalize_rotation(deg), 180) == 90

  # Merge into a freshly-read copy so a concurrent custom_fields change
  # elsewhere isn't clobbered. No user → session-local only (the assign
  # still toggles; it just won't survive a remount).
  defp persist_sidebar_collapsed(%{uuid: uuid} = user, collapsed) do
    fresh = Auth.get_user(uuid) || user
    merged = Map.put(fresh.custom_fields || %{}, @viewer_info_collapsed_key, collapsed)

    # Internal sidebar state — not an admin-managed custom field.
    case Auth.update_user_custom_fields(fresh, merged, ensure_definitions: false) do
      {:ok, _updated} -> :ok
      {:error, _changeset} -> :ok
    end
  end

  defp persist_sidebar_collapsed(_, _), do: :ok

  # ──────────────────────────────────────────────────────────────
  # Annotation persistence + canvas blob
  # ──────────────────────────────────────────────────────────────

  # The file-only side effects of a shape change: (re)bake the annotated
  # thumbnail variant in the background (debounced) so the media grid
  # shows the markup, and reload the file's comment thread. A board has
  # neither a file nor a thread.
  defp after_shapes_changed(_socket, nil), do: :ok

  defp after_shapes_changed(socket, file_uuid) do
    Storage.AnnotationThumbnailJob.enqueue(file_uuid)
    refresh_file_comments(socket)
    :ok
  end

  # One shape from Etcher's bulk list against our last-known row: unchanged
  # ⇒ no write, known ⇒ UPDATE, new ⇒ INSERT anchored to the target.
  defp persist_one(_socket, a, current, _target) when not is_nil(current) do
    if annotation_unchanged?(a, current),
      do: :skip,
      else: Storage.EtcherAdapter.update(a["uuid"], persistable_attrs(a, current))
  end

  defp persist_one(socket, a, nil, {target_type, target_uuid}) do
    a
    |> persistable_attrs(nil)
    |> Map.put("target_type", target_type)
    |> Map.put("target_uuid", target_uuid)
    |> creator_attrs(socket)
    |> put_marker_author(socket)
    |> Storage.EtcherAdapter.create()
  end

  # `subject` is the file map OR a normalized board — `target_of/1` tells
  # them apart; the file-only side effects live in `after_shapes_changed/2`.
  defp sync_annotations(socket, subject, new_annotations) do
    {target_type, target_uuid} = target_of(subject)
    file_uuid = if target_type == "file", do: target_uuid

    current_by_uuid =
      Map.new(socket.assigns.viewer_annotations, fn a -> {to_string(a.uuid), a} end)

    new_by_uuid = Map.new(new_annotations, fn a -> {a["uuid"], a} end)

    new_in_batch =
      Enum.reject(new_annotations, fn a -> Map.has_key?(current_by_uuid, a["uuid"]) end)

    wrote? =
      Enum.reduce(new_annotations, false, fn a, wrote? ->
        current = Map.get(current_by_uuid, a["uuid"])

        case persist_one(socket, a, current, {target_type, target_uuid}) do
          :skip ->
            wrote?

          {:ok, _} ->
            true

          {:error, reason} ->
            Logger.warning(
              "[MediaCanvasViewer] annotation persist failed kind=#{inspect(a["kind"])} uuid=#{inspect(a["uuid"])}: #{inspect(reason)}"
            )

            wrote?
        end
      end)

    # Deletes — uuids in our state that aren't in Etcher's anymore.
    to_delete =
      Enum.reject(socket.assigns.viewer_annotations, fn a ->
        Map.has_key?(new_by_uuid, to_string(a.uuid))
      end)

    Enum.each(to_delete, fn a ->
      uuid = to_string(a.uuid)

      case Storage.EtcherAdapter.delete(uuid) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[MediaCanvasViewer] annotation delete failed uuid=#{inspect(uuid)}: #{inspect(reason)}"
          )
      end
    end)

    if wrote? or to_delete != [] do
      after_shapes_changed(socket, file_uuid)

      # A row was created / updated / deleted — reload from DB to pick up
      # fresh comment metadata + cascade changes (deleted-annotation
      # comments cascading out), then rebuild the canvas blob.
      refreshed = load_annotations_for_target(target_type, target_uuid)

      socket
      |> assign(:viewer_annotations, refreshed)
      |> assign(:viewer_canvas, build_canvas(subject, refreshed))
      |> push_metadata_patches(target_uuid, new_in_batch, refreshed)
    else
      # Etcher re-broadcast with no net change — skip the reload and
      # canvas rebuild entirely.
      socket
    end
  end

  # Etcher re-broadcasts the *entire* annotation list on every shape
  # mutation, so a file with N annotations would otherwise issue N
  # UPDATEs per interaction. An annotation is worth a DB write only when
  # Etcher-owned mutable state actually moved — geometry, style, kind,
  # the label text, or the label's layout keys. The label half is load-
  # bearing: this used to compare geometry/style/kind only ("titles are
  # edited through the composer"), so a label typed into Etcher's inline
  # editor — the ONLY way text/callout/dimension collect their text since
  # 0.12 — changed nothing the comparison looked at, the write was
  # skipped, and every label silently vanished on the next open.
  # Comparing against the last-known struct lets the untouched rows skip
  # their no-op UPDATE.
  #
  # `@etcher_label_meta_keys` — the metadata keys Etcher itself writes for a
  # label's layout: where a dragged label sits, its alignment, its remembered
  # colour. Persisted so a placed label doesn't snap back on reload. `title`
  # is NOT here: the text lives in the dedicated `title` column
  # (`load_annotations_for/1` surfaces it back as `metadata.title` for the
  # JS).
  @etcher_label_meta_keys ~w(title_box title_align title_offset title_color)

  # The keys `load_annotations_for/1` injects into metadata at load — the
  # comment preview and the column-sourced title. `viewer_annotations` holds
  # those CURATED maps, not schema rows, so anything persisting "the stored
  # metadata" must first subtract these or the derived preview gets baked
  # into the row (and a stale comment count outlives the comments it
  # counted). `comment_author` is deliberately absent: for markers it IS
  # stored metadata (the byline stamp), and dropping it on a marker drag
  # would erase who drew it.
  @load_injected_meta_keys ~w(title badge comment_count comment_created_at comment_text
                              comment_thumbnail_url comment_has_attachment)

  # Public (@doc false) with `persistable_attrs/2` so the unit suite can pin
  # the label round-trip — the bug class here (a metadata-only change judged
  # "unchanged", a curated map read as a schema struct) produced no error,
  # just labels that quietly vanished on the next open.
  @doc false
  def annotation_unchanged?(wire, current) do
    wire["geometry"] == current.geometry and
      wire["style"] == current.style and
      wire["kind"] == current.kind and
      wire_title(wire) == stored_title(current) and
      wire_label_metadata(wire) == Map.take(current.metadata || %{}, @etcher_label_meta_keys)
  end

  # What the wire annotation is allowed to persist: everything except raw
  # `metadata`, which is replaced by the curated merge — Etcher's label keys
  # from the wire over the stored row's other keys (marker author stamps and
  # anything else server-side code owns), minus the load-injected preview.
  # The label text goes to the `title` column.
  @doc false
  def persistable_attrs(wire, current) do
    stored_meta =
      ((current && current.metadata) || %{})
      |> Map.drop(@etcher_label_meta_keys)
      |> Map.drop(@load_injected_meta_keys)

    wire
    |> Map.put("metadata", Map.merge(stored_meta, wire_label_metadata(wire)))
    |> Map.put("title", wire_title(wire))
  end

  # The label text as the curated map carries it — `load_annotations_for/1`
  # surfaces the `title` column as `metadata.title` (there is no :title key
  # on these maps; reading one crashed the LV on every label commit).
  defp stored_title(%{metadata: %{"title" => title}}) when is_binary(title) do
    case String.trim(title) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp stored_title(_), do: nil

  # ── The Reply flow's master comment ───────────────────────────────────
  #
  # A shape's discussion hangs under one MASTER comment — the topic row.
  # It is created lazily, the first time anyone presses Reply on the
  # shape's tooltip: content is the shape's label (or its kind, for
  # unlabelled shapes), the author is the shape's creator when known
  # (falling back to the replier), and `inserted_at` is BACKDATED to the
  # shape's creation — the topic is as old as the shape, only the replies
  # are news. Marked `annotation_master` so the load side can exclude it
  # from discussion counts/previews and surface its uuid for threading.

  defp find_viewer_annotation(socket, uuid) do
    Enum.find(socket.assigns[:viewer_annotations] || [], fn a ->
      to_string(a.uuid) == to_string(uuid)
    end)
  end

  defp ensure_master_comment(socket, ann) do
    case ann do
      %{master_comment_uuid: master} when is_binary(master) ->
        {:ok, master}

      _ ->
        create_master_comment(socket, ann)
    end
  end

  defp create_master_comment(socket, ann) do
    with %{file_uuid: file_uuid} <- socket.assigns[:file],
         %{uuid: replier_uuid} <- socket.assigns[:current_user],
         true <- comments_installed?() do
      author_uuid = Map.get(ann, :creator_uuid) || replier_uuid

      # A labelled shape's master is BODILESS: the sidebar already renders
      # the annotation title as the thread's decoration heading, so putting
      # the label into the content too made every thread open by saying the
      # same thing twice. Only an unlabelled shape gets a content stand-in
      # (its kind), since its card would otherwise have no text at all.
      title = stored_title(ann)

      base_attrs = %{
        metadata: %{
          "annotation_uuid" => to_string(ann.uuid),
          "annotation_master" => true
        },
        inserted_at: Map.get(ann, :inserted_at)
      }

      bodiless_attrs = Map.merge(base_attrs, %{content: "", allow_empty_content: true})

      attrs =
        if title, do: bodiless_attrs, else: Map.put(base_attrs, :content, master_content(ann))

      case PhoenixKitComments.create_comment("file", file_uuid, author_uuid, attrs) do
        {:ok, comment} ->
          {:ok, to_string(comment.uuid)}

        # `allow_empty_content` isn't honored by every installed
        # phoenix_kit_comments release yet — an older version doesn't know
        # the key, casts it away, and its empty-body validator then rejects
        # the now-contentless comment. Retry once with the label as content
        # (the pre-fix behavior) so Reply still works against that version.
        {:error, :empty_comment} when title != nil ->
          retry_attrs = Map.put(base_attrs, :content, master_content(ann))

          case PhoenixKitComments.create_comment("file", file_uuid, author_uuid, retry_attrs) do
            {:ok, comment} -> {:ok, to_string(comment.uuid)}
            {:error, reason} -> log_master_comment_failure(ann, reason)
          end

        {:error, reason} ->
          log_master_comment_failure(ann, reason)
      end
    else
      _ -> :error
    end
  end

  defp log_master_comment_failure(ann, reason) do
    Logger.warning(
      "[MediaCanvasViewer] master comment create failed uuid=#{inspect(ann.uuid)}: #{inspect(reason)}"
    )

    :error
  end

  defp master_content(ann) do
    stored_title(ann) || String.capitalize(to_string(Map.get(ann, :kind) || "annotation"))
  end

  # Reply posted (or the popup dismissed after a post) — refresh so the
  # sidebar thread, tooltip preview, and on-shape badge pick up the new
  # discussion entry, and patch the shape in place so the badge updates
  # without a remount.
  defp close_reply_compose(socket) do
    annotation_uuid = socket.assigns[:replying_annotation_uuid]

    file_uuid =
      case socket.assigns[:file] do
        %{file_uuid: uuid} -> uuid
        _ -> nil
      end

    refresh_file_comments(socket)
    fresh = if file_uuid, do: load_annotations_for(file_uuid), else: []

    socket =
      socket
      |> assign(:replying_annotation_uuid, nil)
      |> assign(:reply_parent_uuid, nil)
      |> assign(:viewer_annotations, fresh)
      |> rebuild_viewer_canvas(fresh)

    case file_uuid &&
           Enum.find(fresh, fn a -> to_string(a.uuid) == to_string(annotation_uuid) end) do
      %{} = ann ->
        Phoenix.LiveView.push_event(socket, "etcher:patch-shape", %{
          fresco_id: "media-zoom-" <> file_uuid,
          uuid: ann.uuid,
          metadata: ann.metadata
        })

      _ ->
        socket
    end
  end

  defp comments_installed? do
    Code.ensure_loaded?(PhoenixKitComments) and
      function_exported?(PhoenixKitComments, :create_comment, 4)
  end

  # Reload + rebuild + patch EVERY shape's metadata in place. Patching all
  # (not a diff) is deliberate: metadata is cheap, N is small, and the one
  # shape that changed is exactly the one we can't cheaply identify from a
  # broadcast that names only the file.
  defp refresh_annotations(socket) do
    case socket.assigns[:file] do
      %{file_uuid: file_uuid} ->
        fresh = load_annotations_for(file_uuid)

        socket =
          socket
          |> assign(:viewer_annotations, fresh)
          |> rebuild_viewer_canvas(fresh)

        Enum.reduce(fresh, socket, fn ann, acc ->
          Phoenix.LiveView.push_event(acc, "etcher:patch-shape", %{
            fresco_id: "media-zoom-" <> file_uuid,
            uuid: ann.uuid,
            metadata: ann.metadata
          })
        end)

      _ ->
        socket
    end
  end

  defp wire_label_metadata(%{"metadata" => %{} = meta}),
    do: Map.take(meta, @etcher_label_meta_keys)

  defp wire_label_metadata(_), do: %{}

  # Blank collapses to nil so an emptied label clears the column instead of
  # storing "".
  defp wire_title(%{"metadata" => %{"title" => title}}) when is_binary(title) do
    case String.trim(title) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp wire_title(_), do: nil

  # For every annotation newly created in this batch, push an
  # `etcher:patch-shape` event with the freshly-loaded metadata
  # (comment_count: 0, comment_created_at, etc.). Etcher's
  # `_finalizeShape` creates shapes with no `metadata` field, so the
  # tooltip would fall back to the shape kind ("Rectangle") until the
  # next file open. This patch hydrates the in-DOM shape immediately
  # so the tooltip shows correct content even before the user posts a
  # title/comment via the AnnotationComposer.
  defp push_metadata_patches(socket, _file_uuid, [], _refreshed), do: socket

  defp push_metadata_patches(socket, file_uuid, new_in_batch, refreshed) do
    refreshed_by_uuid =
      Map.new(refreshed, fn a -> {to_string(a.uuid), a} end)

    Enum.reduce(new_in_batch, socket, fn raw, acc ->
      uuid = raw["uuid"]

      case Map.get(refreshed_by_uuid, uuid) do
        nil ->
          acc

        ann ->
          Phoenix.LiveView.push_event(acc, "etcher:patch-shape", %{
            fresco_id: "media-zoom-" <> file_uuid,
            uuid: ann.uuid,
            metadata: ann.metadata
          })
      end
    end)
  end

  # Build the `%Fresco.Canvas{}` struct the viewer renders. Wraps the
  # file's image as a single-image canvas at {0,0}, with the file's
  # annotations stuffed into `extensions.etcher` so Etcher hydrates
  # them via `handle.getExtension("etcher")` on mount. Returns nil
  # when there's no usable image url — gates the `<Fresco.canvas>`
  # render in the heex.
  # The board's markup: the same Fresco canvas + Etcher layer the image
  # branch renders, over an empty scene, with the connector tool left ON
  # (arrows between shapes are what a board is for) and nothing that
  # needs a file — no rotation, no zoom ladder, no sidebar, no composer.
  attr :board, :map, required: true
  attr :viewer_canvas, :any, required: true
  attr :etcher_colors, :list, default: nil
  attr :etcher_line_params, :map, required: true
  attr :can_annotate, :boolean, required: true

  defp board_canvas(assigns) do
    ~H"""
    <div class="flex h-full overflow-hidden">
      <div
        id={"pk-annotation-actions-" <> @board.target_uuid}
        phx-hook="EtcherTooltipActions"
        class="flex-1 relative flex items-center justify-center bg-base-200 overflow-hidden p-0 lg:p-2 min-h-[40vh] lg:min-h-0"
      >
        <%!-- Light, like the image viewer: a board is drawn on, and the
              paper does not change colour with the admin's theme. It is
              also what a burn of it is composed on. --%>
        <Fresco.canvas
          id={"media-zoom-" <> @board.target_uuid}
          canvas={@viewer_canvas}
          class="w-full h-full lg:rounded"
          theme={:light}
          infinite_canvas={true}
        />
        <%!-- panel_offset: same collision as the html.heex embed — the
              viewer chrome owns the top-right corner, so Etcher's style
              panel anchors below it (Etcher 0.13.2). --%>
        <Etcher.layer
          fresco_id={"media-zoom-" <> @board.target_uuid}
          colors={@etcher_colors}
          line_params={@etcher_line_params}
          panel_offset={%{top: 56}}
          toolbar={@can_annotate}
          nav_buttons={if @can_annotate, do: nil, else: [:visibility]}
          tools={
            if @can_annotate,
              do: [
                :grabber,
                :image,
                :rectangle,
                :circle,
                :polygon,
                :freehand,
                :marker,
                :callout,
                :text,
                :textbox,
                :dimension,
                :arrow,
                :line,
                :eraser
              ],
              else: []
          }
        />
      </div>
    </div>
    """
  end

  defp target_of(%{file_uuid: uuid}) when is_binary(uuid), do: {"file", uuid}
  defp target_of(%{target_type: type, target_uuid: uuid}), do: {type, uuid}

  defp build_canvas(%{file_uuid: _} = file, annotations),
    do: build_viewer_canvas(file, annotations, false)

  defp build_canvas(%{target_type: _} = board, annotations),
    do: build_board_canvas(board, annotations, false)

  # A read-only viewer's shapes are sent locked (Etcher `readonly`).
  defp locked?(socket), do: not socket.assigns.can_annotate

  # A board: the scene with NO images — Fresco keeps the extent from the
  # canvas itself and Etcher draws over the void. `infinite_canvas` lets
  # the user pan beyond the extent, which is what a whiteboard wants.
  defp build_board_canvas(board, annotations, locked?) do
    Fresco.Canvas.new(width: board.width, height: board.height, background: board.background)
    |> Fresco.Canvas.put_extension("etcher", %{
      "version" => "1",
      "annotations" => Enum.map(annotations, &etcher_annotation_for_wire(&1, locked?))
    })
  end

  @doc false
  # Does this file have a burned copy to open with? `burn_size` names the
  # variant it describes (`burned_large`, else `burned` — see
  # `MediaBrowser.burn_size/1`).
  def burned?(file) when is_map(file) do
    case Map.get(file, :burn_size) do
      %{variant: variant} -> is_binary(file.urls[variant])
      _ -> false
    end
  end

  def burned?(_), do: false

  # The canvas the viewer opens with: the picture with its markup already
  # in it, as one flat image and nothing else.
  #
  # Its own extent, not the picture's. A burn takes in ink drawn past the
  # picture's edges, so it is a different shape — laid out at the picture's
  # dimensions it would be squeezed, and the markup would sit somewhere it
  # was never drawn.
  #
  # No `etcher` extension on it: there is nothing to draw over a picture
  # that already has the drawing in it, and a second copy of every shape is
  # exactly what that would be.
  defp build_burn_canvas(file) when is_map(file) do
    with %{variant: variant, w: w, h: h} when w > 0 and h > 0 <- Map.get(file, :burn_size),
         src when is_binary(src) and src != "" <- file.urls[variant] do
      burn_canvas(src, w, h)
    else
      _ -> nil
    end
  end

  defp build_burn_canvas(_file), do: nil

  defp burn_canvas(src, w, h) do
    Fresco.Canvas.new(width: w, height: h)
    |> Fresco.Canvas.add_image(%{
      src: src,
      x: 0,
      y: 0,
      width: w,
      natural_width: w,
      natural_height: h
    })
  end

  # Zoom ladder for the picture canvases (the live layer and the eye's
  # plain view): medium → large, then for images over 4K we stream DZI
  # tiles of the original (only the visible area) instead of ever
  # loading the whole multi-MB original; for ≤4K images the full
  # original raster is the top of the ladder (no tiles). DZI tiles also
  # require the storage tile-generation setting (which is what
  # populates urls["dzi"]).
  #
  # The ladder tops out at `large`, not at the original. Looking at (or
  # drawing on) a picture needs a picture you can SEE, not every pixel
  # that was uploaded: a 5000px original is several MB to fetch and
  # decode before anything happens, and on a slow line that is the
  # whole experience of opening the viewer. Annotations are stored in
  # image coordinates and the canvas keeps the original's extent either
  # way, so which raster is showing changes nothing about where a shape
  # lands. Deep zoom past `large` still streams tiles where tile
  # generation is on; the full original stays a download.
  #
  # `small` is the FIRST rung, not an outsider. The canvas opens on it
  # (the bitmap the grid already painted), and Tessera assumes it is
  # showing sources[0] — so leaving it out meant Tessera believed a
  # 300px picture was the 800px one, and only swapped when the display
  # demanded more than 880: straight from `small` to `large`, with
  # `medium` never chosen on the way up. Listing it makes the ladder
  # true, so the climb is small → medium → large and each step is the
  # smallest file that covers the screen.
  #
  # Returns `{sources, dzi_url}` for `<Tessera.layer>`; render it only
  # when sources is non-empty.
  defp tessera_ladder(f) do
    over_4k = max(Map.get(f, :width) || 0, Map.get(f, :height) || 0) > 4096
    has_dzi = is_binary(f.urls["dzi"]) and f.urls["dzi"] != ""

    sources =
      [{f.urls["small"], 300}, {f.urls["medium"], 800}, {f.urls["large"], 1920}]
      |> Enum.filter(fn {url, _w} -> is_binary(url) and url != "" end)
      |> Enum.map(fn {url, width} -> %{url: url, width: width} end)

    {sources, if(over_4k and has_dzi, do: f.urls["dzi"], else: nil)}
  end

  # The eye's hidden state: the picture with nothing over it. The same
  # canvas the live layer uses, minus the "etcher" extension — no layer
  # mounts over this one, so the annotation payload would have no reader;
  # dropping it keeps every shape out of the DOM rather than merely
  # unrendered.
  defp plain_canvas(%Fresco.Canvas{} = canvas),
    do: %{canvas | extensions: Map.delete(canvas.extensions, "etcher")}

  defp plain_canvas(_), do: nil

  defp apply_burn_refresh(socket, file) do
    current = socket.assigns[:burn_version]
    stamp = burn_stamp(file)

    cond do
      # Editing. The burn on file is behind what is on screen anyway —
      # this session will render its own on the way out.
      not socket.assigns[:burn_mode] ->
        socket

      # Already showing it. The id below is what remounts the canvas, and
      # remounting it for the same picture is a flash for nothing.
      #
      # The two writers name that picture differently: this poke prefers
      # the drawing's fingerprint, and `burn_stored` (the editor that just
      # closed on THIS viewer) records the bytes' checksum. Either one
      # matching means it is the burn already on screen.
      stamp == current or showing_burn?(current, file) ->
        socket

      true ->
        case build_burn_canvas(file) do
          nil ->
            socket

          canvas ->
            socket
            |> assign(:burn_canvas, canvas)
            |> assign(:burn_version, stamp)
        end
    end
  end

  defp showing_burn?(current, file) when is_binary(current) and current != "" do
    current in burn_ids(file)
  end

  defp showing_burn?(_current, _file), do: false

  defp burn_ids(file) do
    Enum.filter([burn_fingerprint_id(file), burn_url_version(file)], &is_binary/1)
  end

  # What makes one burned copy a different one, for the canvas id that
  # decides whether Fresco remounts. The fingerprint is what the drawing
  # WAS, which is the honest answer when it is recorded; the URL's own
  # version (the stored bytes' checksum) stands in when it is not, so a
  # file burned before fingerprints were kept still refreshes.
  defp burn_stamp(file), do: burn_fingerprint_id(file) || burn_url_version(file)

  defp burn_fingerprint_id(file) do
    case Map.get(file, :burn_fingerprint) do
      fp when is_binary(fp) and fp != "" -> fp
      _ -> nil
    end
  end

  # `burn_size` names the variant the viewer opens with (`burned_large`,
  # else `burned`), so the stand-in reads that one's URL rather than
  # assuming which slot is in play.
  defp burn_url_version(file) do
    variant = Map.get(Map.get(file, :burn_size) || %{}, :variant)

    case Regex.run(~r/[?&]v=([a-f0-9]+)/, (variant && file.urls[variant]) || "") do
      [_, v] -> v
      _ -> nil
    end
  end

  defp build_viewer_canvas(nil, _annotations, _locked?), do: nil

  defp build_viewer_canvas(file, annotations, locked?) when is_map(file) do
    # Open on the variant the GRID was already showing, not a bigger one.
    #
    # The card behind this popup paints `small` (300px). Opening on `medium`
    # (800px) asked the browser for a URL it had never seen, so a click was
    # a fresh download before anything appeared at all — the whole reason
    # opening a picture felt slow, and worse the slower the connection. The
    # already-decoded bitmap was sitting in cache, unused.
    #
    # `small` is usually a cache hit and paints on the spot; Tessera then
    # swaps up to medium → large (→ DZI tiles past 4K) in the background,
    # so the soft first frame lasts about as long as the fetch that used to
    # be a blank one. `small` is deliberately NOT added to that ladder: a
    # rung it can settle on is a rung it might not climb off, and this one
    # is only ever meant to be the thing you see while the real one loads.
    #
    # The canvas keeps the full original dimensions either way — the src is
    # a texture stretched over that extent, and `put_natural_size` reads the
    # file row rather than the variant — so annotations stay aligned to the
    # pixel whichever rung is showing.
    src =
      file.urls["small"] || file.urls["medium"] || file.urls["large"] ||
        file.urls["original"]

    if is_binary(src) and src != "" do
      {width, height} = canvas_dimensions(file)

      Fresco.Canvas.new(width: width, height: height)
      |> Fresco.Canvas.add_image(put_natural_size(%{src: src, x: 0, y: 0, width: width}, file))
      |> Fresco.Canvas.put_extension("etcher", %{
        "version" => "1",
        "annotations" => Enum.map(annotations, &etcher_annotation_for_wire(&1, locked?))
      })
    end
  end

  # `width`/`height` are nullable on the files row — dimension extraction
  # can fail, and rows written before it existed never had them. The canvas
  # needs *some* extent, so an unknown size falls back to a neutral square.
  defp canvas_dimensions(file) do
    case pixel_dimensions(file) do
      {width, height} -> {width, height}
      nil -> {@placeholder_canvas_edge, @placeholder_canvas_edge}
    end
  end

  # Declare the intrinsic size ONLY when the row actually recorded it.
  #
  # Fresco turns `natural_width`/`natural_height` into an explicit
  # `height: Npx` on a bare <img> that carries no object-fit, so whatever
  # ratio we hand it is imposed on the bitmap. Feeding it a guess therefore
  # does not degrade gracefully — it visibly distorts the photo. The old
  # code defaulted both to 1000, so any file missing its dimensions was
  # forced into a 1:1 box and every non-square image opened squashed along
  # its longer axis.
  #
  # Omitting the pair instead leaves the <img> with a width and an auto
  # height, so the browser derives the ratio from the decoded bitmap, which
  # is right by construction. Fresco re-fits on the image's load event, so
  # the frame that paints before the bitmap arrives resolves itself.
  # Nothing changes for a file whose dimensions ARE known: Fresco computes
  # `width * natural_height / natural_width`, which is exactly `height`.
  defp put_natural_size(image, file) do
    case pixel_dimensions(file) do
      {width, height} -> Map.merge(image, %{natural_width: width, natural_height: height})
      nil -> image
    end
  end

  defp pixel_dimensions(file) do
    width = Map.get(file, :width)
    height = Map.get(file, :height)

    if is_number(width) and is_number(height) and width > 0 and height > 0 do
      {width, height}
    end
  end

  # The burn hook only makes sense on a picture. Videos, PDFs and the icon
  # fallback have no overlay to compose, and a hook there would still listen
  # for every Escape on the page.
  defp image_file?(%{file_type: "image"}), do: true
  defp image_file?(%{mime_type: "image/" <> _}), do: true
  defp image_file?(_), do: false

  # The `v` query on the original's signed URL — the content version the
  # viewer was rendered against. The burn posts it back so a rendering of a
  # picture that has since been replaced is refused. Absent when the URL
  # carries no version (the server then has nothing to compare).
  defp original_source_version(%{urls: urls}) when is_map(urls) do
    case urls["original"] do
      url when is_binary(url) ->
        case URI.parse(url) do
          %URI{query: query} when is_binary(query) -> URI.decode_query(query)["v"]
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp original_source_version(_), do: nil

  # Map an in-memory annotation (from `load_annotations_for/1`) to
  # the Etcher 0.3 wire shape (string-keyed map with uuid/kind/
  # geometry plus optional style/metadata).
  defp etcher_annotation_for_wire(a, locked?) do
    base = %{
      "uuid" => to_string(a.uuid),
      "kind" => a.kind,
      "geometry" => a.geometry
    }

    base = if locked?, do: Map.put(base, "readonly", true), else: base

    base =
      case Map.get(a, :style) do
        nil -> base
        style -> Map.put(base, "style", style)
      end

    case Map.get(a, :metadata) do
      nil -> base
      metadata -> Map.put(base, "metadata", metadata)
    end
  end

  # Read this user's saved Etcher palette fresh from the DB, falling back
  # to the default when nothing is stored (or there's no user). Fresh read
  # (not the parent-passed struct) keeps it correct on modal prev/next
  # after an in-session edit. Re-sanitize on read too (not just on write) so
  # data persisted before the write-side guard shipped, or written by any
  # other path, can't reach `<Etcher.layer colors={…}>` untrusted.
  # The user row the three viewer preferences are read out of. Fresh from
  # the DB rather than the parent-passed struct, which can be stale on modal
  # prev/next after an in-session edit — but fetched ONCE, where each of the
  # three used to fetch it for itself.
  defp viewer_user_prefs(%{uuid: uuid} = user), do: Auth.get_user(uuid) || user
  defp viewer_user_prefs(other), do: other

  defp load_user_colors(user) when is_map(user) do
    case sanitize_colors(Auth.get_user_field(user, @etcher_colors_key)) do
      [_ | _] = colors -> colors
      # Nothing saved (or a reset): nil, so Etcher seeds from its own
      # current presets — see the @etcher_colors_key comment for why no
      # copy of them lives here.
      [] -> nil
    end
  end

  defp load_user_colors(_), do: nil

  # Keep only color-shaped strings, trimmed, deduped, and capped — the input
  # is client-supplied. Returns `[]` when nothing valid remains so the caller
  # can ignore the update.
  defp sanitize_colors(colors) when is_list(colors) do
    colors
    |> Enum.filter(&(is_binary(&1) and Regex.match?(@etcher_color_format, &1)))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@max_etcher_colors)
  end

  defp sanitize_colors(_), do: []

  # This user's saved Etcher line params, falling back to the default when
  # nothing valid is stored (or there's no user). The row comes from
  # `viewer_user_prefs/1`, which is what makes it a fresh read. Re-sanitize
  # on read too (not just on write) so
  # data persisted before this guard shipped, or by any other path, can't reach
  # `<Etcher.layer line_params={…}>` untrusted.
  defp load_user_line_params(user) when is_map(user) do
    case sanitize_line_params(Auth.get_user_field(user, @etcher_line_params_key)) do
      %{} = params -> params
      nil -> @default_etcher_line_params
    end
  end

  defp load_user_line_params(_), do: @default_etcher_line_params

  # Line params arrive from the same untrusted client hook as the palette.
  # Keep only the known keys, clamped to Etcher's own ranges (width 1..40,
  # opacity 0..1, dash enum, font size 6..200), then merge over the default
  # so a partial or garbage payload still yields a usable map. Returns `nil`
  # when nothing valid survives so the caller can ignore the update rather
  # than wipe the saved ink.
  defp sanitize_line_params(params) when is_map(params) do
    clean =
      Enum.reduce(params, %{}, fn
        {"width", w}, acc when is_number(w) -> Map.put(acc, "width", clamp_number(w, 1, 40))
        {"opacity", o}, acc when is_number(o) -> Map.put(acc, "opacity", clamp_number(o, 0, 1))
        {"dash", d}, acc when d in @etcher_dash_values -> Map.put(acc, "dash", d)
        {"font_size", s}, acc when is_number(s) -> Map.put(acc, "font_size", clamp_font(s))
        _, acc -> acc
      end)

    # Merged into the DEFAULTS rather than into whatever was stored before,
    # which is what lets a cleared font size clear: Etcher omits the key
    # when the user unpins it, and an omitted key has to mean "back to
    # sizing labels by their box" rather than "leave the old one alone".
    if map_size(clean) == 0, do: nil, else: Map.merge(@default_etcher_line_params, clean)
  end

  defp sanitize_line_params(_), do: nil

  defp clamp_number(n, lo, hi), do: n |> max(lo) |> min(hi)

  # Rounded as well as clamped: the control only ever offers whole pixels,
  # and a stored 17.5 would come back as a size the user cannot type.
  defp clamp_font(n) do
    {lo, hi} = @etcher_font_size_range
    n |> clamp_number(lo, hi) |> round()
  end

  @doc """
  Loads annotations for a file into the curated map shape this component
  uses internally (uuid / kind / geometry / style / metadata with
  comment_* + title injected). Public so standalone-page hosts like
  `MediaDetail` can build their own decoration registry off the same
  shape without re-querying the schema by hand.
  """
  def load_annotations_for(file_uuid) do
    file_uuid
    |> Annotations.list_for_file_with_previews()
    |> Enum.map(&curate_row/1)
  end

  @doc """
  `load_annotations_for/1` for any target: a file goes through the
  comment-preview loader; any other target has no comment threads, so
  its rows carry the zero-comment shape (badge 0, no preview).
  """
  def load_annotations_for_target("file", file_uuid), do: load_annotations_for(file_uuid)

  def load_annotations_for_target(target_type, target_uuid) do
    target_type
    |> Annotations.list_for_target(target_uuid)
    |> Enum.map(fn a ->
      curate_row(%{annotation: a, first_comment: nil, comment_count: 0, master_comment_uuid: nil})
    end)
  end

  defp curate_row(row) do
    %{annotation: a, first_comment: fc, comment_count: count} = row

    # `metadata` flows through to Etcher's tooltip. The JS reads
    # `metadata.label` (consumer-set) plus the comment_* fields we
    # populate here for the auto-rendered preview.
    base_meta = a.metadata || %{}

    comment_meta =
      case fc do
        nil ->
          %{"comment_created_at" => format_date(a.inserted_at), "comment_count" => 0}

        %{} = c ->
          %{
            "comment_text" => truncate(c.content, 80),
            "comment_author" => c.author,
            "comment_thumbnail_url" => c.thumbnail_url,
            "comment_has_attachment" => Map.get(c, :has_attachment, false),
            "comment_count" => count,
            "comment_created_at" => format_date(a.inserted_at)
          }
      end

    # Surface the dedicated title column as `metadata.title` so the
    # JS overlay can render it inline. The column is the source of
    # truth; the metadata key is the JS-facing contract.
    title_meta = if a.title, do: %{"title" => a.title}, else: %{}

    # `badge` drives Etcher's on-shape count bubble (0.13): the number
    # of discussion entries, so a glance at the canvas shows which
    # shapes people are talking about. ALWAYS present, zero included:
    # `patchShape` merges metadata, so an omitted key would leave a
    # stale bubble on the shape after its last comment is deleted —
    # Etcher hides the bubble for 0 itself.
    badge_meta = %{"badge" => count}

    %{
      uuid: a.uuid,
      kind: a.kind,
      geometry: a.geometry,
      style: a.style,
      # For the Reply flow: the shape's creation moment (the master
      # comment is backdated to it), its creator (the master's author),
      # and the master's uuid when the thread already exists (nil =
      # created on first Reply).
      inserted_at: a.inserted_at,
      creator_uuid: a.creator_uuid,
      master_comment_uuid: Map.get(row, :master_comment_uuid),
      metadata:
        base_meta
        |> Map.merge(comment_meta)
        |> Map.merge(title_meta)
        |> Map.merge(badge_meta)
    }
  end

  defp creator_attrs(attrs, socket) do
    creator_uuid =
      case socket.assigns[:current_user] do
        %{uuid: uuid} when is_binary(uuid) -> uuid
        _ -> nil
      end

    Map.put(attrs, "creator_uuid", creator_uuid)
  end

  # Markers skip the composer, so they never collect a title/comment — but
  # the tooltip should still say who drew it and when. Stamp the author's
  # display name into the annotation's `metadata` server-side (trusted, from
  # the socket — not the untrusted wire payload, which the adapter strips
  # `creator_uuid` from anyway). The tooltip's header slot reads
  # `metadata.comment_author`; `comment_created_at` is derived from the row's
  # `inserted_at` in `load_annotations_for/1`. Persisting the name in
  # `metadata` (an adapter-writable field) keeps the tooltip identical on the
  # instant patch-shape push and after a reload. Non-markers are untouched.
  defp put_marker_author(%{"kind" => "marker"} = attrs, socket) do
    case current_user_display_name(socket) do
      name when is_binary(name) ->
        meta = Map.put(attrs["metadata"] || %{}, "comment_author", name)
        Map.put(attrs, "metadata", meta)

      _ ->
        attrs
    end
  end

  defp put_marker_author(attrs, _socket), do: attrs

  defp current_user_display_name(socket) do
    case socket.assigns[:current_user] do
      %{} = user -> user_display_name(user)
      _ -> nil
    end
  end

  # Mirror of `PhoenixKit.Annotations.author_display/1` (private there) so
  # marker bylines read the same as comment-author bylines: "First Last",
  # else first name, else the email local-part.
  defp user_display_name(%{first_name: fn_, last_name: ln})
       when is_binary(fn_) and is_binary(ln) and fn_ != "" and ln != "" do
    "#{fn_} #{ln}"
  end

  defp user_display_name(%{first_name: fn_}) when is_binary(fn_) and fn_ != "", do: fn_

  defp user_display_name(%{email: email}) when is_binary(email) do
    email |> String.split("@", parts: 2) |> hd()
  end

  defp user_display_name(_), do: nil

  defp rebuild_viewer_canvas(socket, annotations) do
    case socket.assigns[:file] do
      nil ->
        socket

      file ->
        assign(socket, :viewer_canvas, build_viewer_canvas(file, annotations, locked?(socket)))
    end
  end

  # Apply a title edit that came from the comments sidebar
  # (CommentsComponent's inline-edit). Writes the annotation row,
  # reloads `viewer_annotations` so the heex re-derives
  # `build_annotation_titles/1` for the comments component on the
  # next render, and pushes `etcher:patch-shape` so the shape
  # tooltip refreshes. No flash, no `composing_annotation_uuid`
  # reset — the user is not interacting with the composer here.
  defp apply_annotation_title_update(socket, annotation_uuid, title)
       when is_binary(annotation_uuid) do
    file_uuid =
      case socket.assigns[:file] do
        %{file_uuid: uuid} -> uuid
        _ -> nil
      end

    persist_annotation_title(annotation_uuid, normalize_annotation_title(title))

    fresh = if file_uuid, do: load_annotations_for(file_uuid), else: []

    socket =
      socket
      |> assign(:viewer_annotations, fresh)
      |> rebuild_viewer_canvas(fresh)

    case file_uuid && Enum.find(fresh, fn a -> a.uuid == annotation_uuid end) do
      %{} = ann ->
        Phoenix.LiveView.push_event(socket, "etcher:patch-shape", %{
          fresco_id: "media-zoom-" <> file_uuid,
          uuid: ann.uuid,
          metadata: ann.metadata
        })

      _ ->
        socket
    end
  end

  defp apply_annotation_title_update(socket, _, _), do: socket

  # Blank/whitespace-only titles collapse to nil (clears the column).
  defp normalize_annotation_title(str) when is_binary(str) do
    if String.trim(str) == "", do: nil, else: str
  end

  defp normalize_annotation_title(_), do: nil

  # Inline title edits intentionally show no flash (see above), but a failed
  # write would otherwise be indistinguishable from a no-op — log it so the
  # failure is diagnosable.
  defp persist_annotation_title(annotation_uuid, title_val) do
    case PhoenixKit.Annotations.update(annotation_uuid, %{title: title_val}) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to update annotation #{annotation_uuid} title from comments sidebar: #{inspect(reason)}"
        )
    end
  end

  @doc """
  Build the `comment_decorations` registry that `CommentsComponent`
  uses to render external labels above comments. The comments
  package speaks a generic `%{metadata_key => %{value => entry}}`
  vocabulary; we package annotation titles under the
  `"annotation_uuid"` metadata key (matching the back-reference
  comments already store via `metadata["annotation_uuid"]`).

  Source for the label: `load_annotations_for/1` projects the
  schema's `title` column into `metadata["title"]` (so Etcher's
  JS tooltip can read it as a single map). We read from the same
  place rather than bolt a top-level field onto the curated
  annotation map. Only entries with non-empty titles are
  included; an annotation without a title contributes nothing
  (and the comment renders without a label block).

  Public so standalone-page hosts (`MediaDetail`) can build the
  same registry against the annotations they loaded via
  `load_annotations_for/1`.
  """
  def build_comment_decorations(annotations) when is_list(annotations) do
    entries =
      Enum.reduce(annotations, %{}, fn a, acc ->
        title = a |> Map.get(:metadata, %{}) |> Map.get("title")

        if is_binary(title) and title != "" do
          Map.put(acc, to_string(a.uuid), %{
            label: title,
            on_save: :annotation_title_updated
          })
        else
          acc
        end
      end)

    if map_size(entries) == 0, do: %{}, else: %{"annotation_uuid" => entries}
  end

  def build_comment_decorations(_), do: %{}

  # Poke the file's CommentsComponent to reload after server-side
  # changes the component didn't drive itself (new annotation
  # comment, cascade-deleted annotation comments, etc.). Flipping
  # `loaded?` to false makes its `update/2` rerun `load_comments/1`.
  defp refresh_file_comments(socket) do
    with %{file_uuid: file_uuid} when is_binary(file_uuid) <- socket.assigns[:file],
         true <- Code.ensure_loaded?(PhoenixKitComments.Web.CommentsComponent) do
      Phoenix.LiveView.send_update(PhoenixKitComments.Web.CommentsComponent,
        id: "media-comments-" <> file_uuid,
        loaded?: false
      )
    end

    :ok
  end

  # ──────────────────────────────────────────────────────────────
  # Format helpers (duplicated from MediaBrowser — small and stable;
  # not worth a shared module yet)
  # ──────────────────────────────────────────────────────────────

  # Tooltip date format. The format string is gettext-wrapped so
  # locales can reorder components ("%d %b %Y" in en-GB / fr / de
  # etc.) without code changes. `strftime`'s month + day-name
  # expansion already resolves through `Calendar` translations.
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, gettext("%b %d, %Y"))
  defp format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, gettext("%b %d, %Y"))
  defp format_date(_), do: nil

  defp truncate(nil, _), do: nil
  defp truncate("", _), do: nil

  defp truncate(text, limit) when is_binary(text) do
    text = String.trim(text)

    if String.length(text) > limit do
      String.slice(text, 0, limit - 1) <> "…"
    else
      text
    end
  end

  defp format_file_size(nil), do: ""
  defp format_file_size(bytes), do: Format.bytes(bytes, base: 1000, decimals: 2)

  defp file_icon("image"), do: "hero-photo"
  defp file_icon("video"), do: "hero-play-circle"
  defp file_icon("audio"), do: "hero-musical-note"
  defp file_icon("pdf"), do: "hero-document-text"
  defp file_icon("document"), do: "hero-document"
  defp file_icon(_), do: "hero-document-arrow-down"

  # Known audio extensions — matched as a fallback because uploads often carry a
  # generic `application/octet-stream` mime (mp3 especially), which would
  # otherwise classify as a document and never show a player.
  @audio_extensions ~w(.mp3 .wav .ogg .oga .m4a .aac .flac .opus .weba .mid .midi)

  # One caller, `audio?(f)` in the cond that picks the player, where `f` is the
  # file the template has already dereferenced a dozen times over — so there is
  # no non-map to fall back for. The clause that used to be here was dead, and
  # dialyzer says so now that `pane_aspect/2` states the same thing in a guard.
  defp audio?(%{} = f) do
    (is_binary(f.mime_type) and String.starts_with?(f.mime_type, "audio/")) or
      f.file_type == "audio" or
      (is_binary(f.filename) and String.ends_with?(String.downcase(f.filename), @audio_extensions))
  end

  @doc """
  Runtime check for whether the optional `phoenix_kit_comments` package
  is installed AND enabled. Public so standalone-page hosts can gate
  their own embed of `CommentsComponent` the same way the sidebar does.
  """
  @dialyzer {:nowarn_function, comments_enabled?: 0}
  def comments_enabled? do
    Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?()
  rescue
    _ -> false
  end
end
