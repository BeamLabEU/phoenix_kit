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
    * `:details_path` (default `nil`) — when set, the sidebar shows an
      "Open details page" button navigating to this path. Admin-context
      hosts (`MediaBrowser` with `admin={true}`) pass the file's
      `/admin/media/:uuid` page; public hosts leave it off.
  """

  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Annotations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Format

  # Etcher's toolbar color slots are a single palette shared across every
  # Fresco viewer this user opens — stored in their `custom_fields`
  # ("user meta") under this key, not per-file like annotations. The
  # default is used until the user saves a palette of their own.
  @etcher_colors_key "etcher_colors"
  @default_etcher_colors ["#fca5a5", "#fdba74", "#fde68a", "#86efac", "#93c5fd"]

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
     |> assign(:viewer_annotations, [])
     |> assign(:replying_annotation_uuid, nil)
     |> assign(:reply_parent_uuid, nil)
     |> assign(:etcher_colors, @default_etcher_colors)
     |> assign(:etcher_line_params, @default_etcher_line_params)
     |> assign(:viewer_only, false)
     |> assign(:can_annotate, true)
     |> assign(:viewer_rotation, 0)
     |> assign(:persist_rotation, false)
     |> assign(:rotation_status, nil)
     |> assign(:rotation_status_token, 0)
     |> assign(:sidebar_collapsed, false)
     |> assign(:details_path, nil)}
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
          # Seed the saved rotation so the image paints already-rotated on open
          # (no flash of unrotated → rotated). Read from the file's metadata row.
          |> assign(:viewer_rotation, load_saved_rotation(file.file_uuid))
          # Read fresh from the DB (not the parent-passed struct) so the
          # palette is correct even on modal prev/next after an in-session
          # edit, where the parent's `current_user` may be stale.
          |> assign(:etcher_colors, load_user_colors(assigns[:current_user]))
          |> assign(:etcher_line_params, load_user_line_params(assigns[:current_user]))
          |> assign(:sidebar_collapsed, load_sidebar_collapsed(assigns[:current_user]))

        socket.assigns[:viewer_canvas] == nil and is_map(board) ->
          annotations = load_annotations_for_target(board.target_type, board.target_uuid)

          socket
          |> assign(:viewer_annotations, annotations)
          |> assign(:viewer_canvas, build_board_canvas(board, annotations, locked?(socket)))
          |> assign(:viewer_rotation, 0)
          |> assign(:etcher_colors, load_user_colors(assigns[:current_user]))
          |> assign(:etcher_line_params, load_user_line_params(assigns[:current_user]))
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

  # The image's saved orientation (degrees), read from the file row's metadata.
  # A lightweight PK fetch at viewer-open — negligible next to loading the image
  # + annotations. Missing/garbage → 0 (unrotated). Never crashes the viewer.
  defp load_saved_rotation(file_uuid) do
    case Storage.get_file(file_uuid) do
      %{metadata: meta} when is_map(meta) -> normalize_rotation(Map.get(meta, "rotation"))
      _ -> 0
    end
  rescue
    _ -> 0
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

        if current == rotation do
          assign(socket, :viewer_rotation, rotation)
        else
          merged = Map.put(file.metadata || %{}, "rotation", rotation)

          case Storage.update_file(file, %{metadata: merged}) do
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

  # Fresh read (not the parent-passed struct), matching the Etcher palette
  # helpers — keeps the value correct on modal prev/next after an
  # in-session toggle. Anything but a stored `true` means expanded.
  defp load_sidebar_collapsed(%{uuid: uuid} = user) do
    fresh = Auth.get_user(uuid) || user
    Auth.get_user_field(fresh, @viewer_info_collapsed_key) == true
  end

  defp load_sidebar_collapsed(_), do: false

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
  attr :etcher_colors, :list, required: true
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
        <Fresco.canvas
          id={"media-zoom-" <> @board.target_uuid}
          canvas={@viewer_canvas}
          class="w-full h-full lg:rounded"
          theme={:inherit}
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
                :dimension,
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

  defp build_viewer_canvas(nil, _annotations, _locked?), do: nil

  defp build_viewer_canvas(file, annotations, locked?) when is_map(file) do
    # Open on the cheap medium variant; Tessera swaps up to large (and DZI
    # tiles for >4K images) as the user zooms. The canvas keeps the full
    # original dimensions so the coordinate space matches the DZI pyramid.
    src = file.urls["medium"] || file.urls["large"] || file.urls["original"]

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
  defp load_user_colors(%{uuid: uuid} = user) do
    fresh = Auth.get_user(uuid) || user

    case sanitize_colors(Auth.get_user_field(fresh, @etcher_colors_key)) do
      [_ | _] = colors -> colors
      [] -> @default_etcher_colors
    end
  end

  defp load_user_colors(_), do: @default_etcher_colors

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

  # Read this user's saved Etcher line params fresh from the DB, falling back
  # to the default when nothing valid is stored (or there's no user). Fresh
  # read (not the parent-passed struct) keeps it correct on modal prev/next
  # after an in-session edit. Re-sanitize on read too (not just on write) so
  # data persisted before this guard shipped, or by any other path, can't reach
  # `<Etcher.layer line_params={…}>` untrusted.
  defp load_user_line_params(%{uuid: uuid} = user) do
    fresh = Auth.get_user(uuid) || user

    case sanitize_line_params(Auth.get_user_field(fresh, @etcher_line_params_key)) do
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

  defp audio?(%{} = f) do
    (is_binary(f.mime_type) and String.starts_with?(f.mime_type, "audio/")) or
      f.file_type == "audio" or
      (is_binary(f.filename) and String.ends_with?(String.downcase(f.filename), @audio_extensions))
  end

  defp audio?(_), do: false

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
