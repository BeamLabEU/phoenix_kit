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

  ## Optional assigns

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

  # Whether the info sidebar (filename / Download / metadata / comments) is
  # collapsed to give the viewer the full popup width. Per-user, one value
  # across every viewer — stored in `custom_fields` ("user meta") like the
  # Etcher palette, so it survives prev/next remounts, reopen, and reload.
  @viewer_info_collapsed_key "media_viewer_info_collapsed"

  # ──────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:viewer_canvas, nil)
     |> assign(:viewer_annotations, [])
     |> assign(:composing_annotation_uuid, nil)
     |> assign(:etcher_colors, @default_etcher_colors)
     |> assign(:etcher_line_params, @default_etcher_line_params)
     |> assign(:viewer_only, false)
     |> assign(:viewer_rotation, 0)
     |> assign(:persist_rotation, false)
     |> assign(:rotation_status, nil)
     |> assign(:rotation_status_token, 0)
     |> assign(:sidebar_collapsed, false)
     |> assign(:details_path, nil)}
  end

  @impl true
  def update(%{action: :annotation_composer_posted} = assigns, socket) do
    {:ok, finalize_annotation_compose(socket, assigns[:annotation_uuid], assigns[:title])}
  end

  def update(%{action: :annotation_composer_cancelled} = assigns, socket) do
    {:ok, rollback_annotation_compose(socket, assigns[:annotation_uuid])}
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

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:file, file)
      |> assign(:current_user, assigns[:current_user])
      |> assign(:parent_id, assigns[:parent_id])
      |> assign(:has_prev, assigns[:has_prev] || false)
      |> assign(:has_next, assigns[:has_next] || false)
      |> assign(:viewer_only, assigns[:viewer_only] || false)
      # Opt-in: only admin-context hosts persist a rotation back to the shared
      # file row (see handle_event "fresco:rotate"). Public hosts still seed
      # `initial_rotation` below so everyone sees the saved orientation.
      |> assign(:persist_rotation, assigns[:persist_rotation] || false)
      |> assign(:details_path, assigns[:details_path])

    # First mount (or file changed via re-mount): hydrate annotations
    # + canvas. Because the id encodes the file uuid, the parent's
    # prev/next destroys this LC and mounts a fresh one, so this
    # branch effectively only runs at mount time.
    socket =
      if socket.assigns[:viewer_canvas] == nil and is_map(file) do
        annotations = load_annotations_for(file.file_uuid)

        socket
        |> assign(:viewer_annotations, annotations)
        |> assign(:viewer_canvas, build_viewer_canvas(file, annotations))
        # Seed the saved rotation so the image paints already-rotated on open
        # (no flash of unrotated → rotated). Read from the file's metadata row.
        |> assign(:viewer_rotation, load_saved_rotation(file.file_uuid))
        # Read fresh from the DB (not the parent-passed struct) so the
        # palette is correct even on modal prev/next after an in-session
        # edit, where the parent's `current_user` may be stale.
        |> assign(:etcher_colors, load_user_colors(assigns[:current_user]))
        |> assign(:etcher_line_params, load_user_line_params(assigns[:current_user]))
        |> assign(:sidebar_collapsed, load_sidebar_collapsed(assigns[:current_user]))
      else
        socket
      end

    {:ok, socket}
  end

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
    case socket.assigns[:file] do
      nil -> {:noreply, socket}
      file -> {:noreply, sync_annotations(socket, file, new_annotations)}
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

      case Auth.update_user_custom_fields(fresh, merged) do
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

      case Auth.update_user_custom_fields(fresh, merged) do
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
  # Undo/redo, drags, color picks all bypass this — they go through
  # `annotations-changed` for persistence but don't re-open the
  # composer. Text shapes get Etcher's inline editor and skip the
  # popup. Markers are pure marking for now — they still persist (via
  # `annotations-changed`) but skip the composer too, so highlighting
  # doesn't prompt for a title/comment; it's just a line. If the
  # composer is already open mid-compose, keep its target — a second
  # quick draw shouldn't ambush an in-flight title/comment.
  def handle_event("etcher:shape-drawn", %{"uuid" => uuid, "kind" => kind}, socket) do
    socket =
      cond do
        kind in ["text", "marker"] ->
          socket

        is_binary(socket.assigns[:composing_annotation_uuid]) ->
          socket

        true ->
          assign(socket, :composing_annotation_uuid, uuid)
      end

    {:noreply, socket}
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
  # every viewer, not a per-user preference — so only persist when the host
  # opted in (admin contexts). Seeds `initial_rotation` on the next open.
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

    case Auth.update_user_custom_fields(fresh, merged) do
      {:ok, _updated} -> :ok
      {:error, _changeset} -> :ok
    end
  end

  defp persist_sidebar_collapsed(_, _), do: :ok

  # ──────────────────────────────────────────────────────────────
  # Annotation persistence + canvas blob
  # ──────────────────────────────────────────────────────────────

  defp sync_annotations(socket, file, new_annotations) do
    file_uuid = file.file_uuid

    current_by_uuid =
      Map.new(socket.assigns.viewer_annotations, fn a -> {to_string(a.uuid), a} end)

    new_by_uuid = Map.new(new_annotations, fn a -> {a["uuid"], a} end)

    new_in_batch =
      Enum.reject(new_annotations, fn a -> Map.has_key?(current_by_uuid, a["uuid"]) end)

    wrote? =
      Enum.reduce(new_annotations, false, fn a, wrote? ->
        uuid = a["uuid"]
        current = Map.get(current_by_uuid, uuid)

        result =
          cond do
            current && annotation_unchanged?(a, current) ->
              :skip

            current ->
              Storage.EtcherAdapter.update(uuid, a)

            true ->
              attrs =
                a
                |> Map.put("target_type", "file")
                |> Map.put("target_uuid", file_uuid)
                |> creator_attrs(socket)
                |> put_marker_author(socket)

              Storage.EtcherAdapter.create(attrs)
          end

        case result do
          :skip ->
            wrote?

          {:ok, _} ->
            true

          {:error, reason} ->
            Logger.warning(
              "[MediaCanvasViewer] annotation persist failed kind=#{inspect(a["kind"])} uuid=#{inspect(uuid)}: #{inspect(reason)}"
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
      # Shapes changed — (re)bake the annotated thumbnail variant in the
      # background (debounced) so the media grid shows the markup.
      Storage.AnnotationThumbnailJob.enqueue(file_uuid)

      # A row was created / updated / deleted — reload from DB to pick up
      # fresh comment metadata + cascade changes (deleted-annotation
      # comments cascading out), then rebuild the canvas blob.
      refreshed = load_annotations_for(file_uuid)
      refresh_file_comments(socket)

      socket
      |> assign(:viewer_annotations, refreshed)
      |> assign(:viewer_canvas, build_viewer_canvas(file, refreshed))
      |> push_metadata_patches(file_uuid, new_in_batch, refreshed)
    else
      # Etcher re-broadcast with no net change — skip the reload and
      # canvas rebuild entirely.
      socket
    end
  end

  # Etcher re-broadcasts the *entire* annotation list on every shape
  # mutation, so a file with N annotations would otherwise issue N
  # UPDATEs per interaction. An annotation is worth a DB write only when
  # Etcher-owned mutable state actually moved — geometry, style or kind.
  # (title / metadata are edited through the composer, not via
  # annotations-changed.) Comparing against the last-known struct lets
  # the untouched rows skip their no-op UPDATE.
  defp annotation_unchanged?(wire, current) do
    wire["geometry"] == current.geometry and
      wire["style"] == current.style and
      wire["kind"] == current.kind
  end

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
  defp build_viewer_canvas(nil, _annotations), do: nil

  defp build_viewer_canvas(file, annotations) when is_map(file) do
    # Open on the cheap medium variant; Tessera swaps up to large (and DZI
    # tiles for >4K images) as the user zooms. The canvas keeps the full
    # original dimensions so the coordinate space matches the DZI pyramid.
    src = file.urls["medium"] || file.urls["large"] || file.urls["original"]

    if is_binary(src) and src != "" do
      width = Map.get(file, :width) || 1000
      height = Map.get(file, :height) || 1000

      Fresco.Canvas.new(width: width, height: height)
      |> Fresco.Canvas.add_image(%{
        src: src,
        x: 0,
        y: 0,
        width: width,
        natural_width: width,
        natural_height: height
      })
      |> Fresco.Canvas.put_extension("etcher", %{
        "version" => "1",
        "annotations" => Enum.map(annotations, &etcher_annotation_for_wire/1)
      })
    end
  end

  # Map an in-memory annotation (from `load_annotations_for/1`) to
  # the Etcher 0.3 wire shape (string-keyed map with uuid/kind/
  # geometry plus optional style/metadata).
  defp etcher_annotation_for_wire(a) do
    base = %{
      "uuid" => to_string(a.uuid),
      "kind" => a.kind,
      "geometry" => a.geometry
    }

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
  # Keep only the three known keys, clamped to Etcher's own ranges (width
  # 1..40, opacity 0..1, dash enum), then merge over the default so a partial
  # or garbage payload still yields a usable map. Returns `nil` when nothing
  # valid survives so the caller can ignore the update rather than wipe the
  # saved ink.
  defp sanitize_line_params(params) when is_map(params) do
    clean =
      Enum.reduce(params, %{}, fn
        {"width", w}, acc when is_number(w) -> Map.put(acc, "width", clamp_number(w, 1, 40))
        {"opacity", o}, acc when is_number(o) -> Map.put(acc, "opacity", clamp_number(o, 0, 1))
        {"dash", d}, acc when d in @etcher_dash_values -> Map.put(acc, "dash", d)
        _, acc -> acc
      end)

    if map_size(clean) == 0, do: nil, else: Map.merge(@default_etcher_line_params, clean)
  end

  defp sanitize_line_params(_), do: nil

  defp clamp_number(n, lo, hi), do: n |> max(lo) |> min(hi)

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
    |> Enum.map(fn %{annotation: a, first_comment: fc, comment_count: count} ->
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

      %{
        uuid: a.uuid,
        kind: a.kind,
        geometry: a.geometry,
        style: a.style,
        metadata: base_meta |> Map.merge(comment_meta) |> Map.merge(title_meta)
      }
    end)
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

  # ──────────────────────────────────────────────────────────────
  # Composer Post / Cancel — driven by AnnotationComposer's
  # send_update with `action: :annotation_composer_posted/_cancelled`
  # ──────────────────────────────────────────────────────────────

  # Post path: comment was created, annotation is solidified.
  # Reload annotations so the tooltip's comment_* fields refresh,
  # poke the file's CommentsComponent so the freshly-posted comment
  # appears in the sidebar without a page reload, and push the
  # updated metadata directly to Etcher's in-DOM shape via the
  # patch-shape bridge (Fresco's `phx-update="ignore"` blocks a
  # canvas-extensions rebuild from reaching the client).
  defp finalize_annotation_compose(socket, annotation_uuid, title) do
    file_uuid =
      case socket.assigns[:file] do
        %{file_uuid: uuid} -> uuid
        _ -> nil
      end

    if annotation_uuid do
      title_val =
        case title do
          nil -> nil
          str when is_binary(str) -> if String.trim(str) == "", do: nil, else: str
          _ -> nil
        end

      _ = PhoenixKit.Annotations.update(annotation_uuid, %{title: title_val})
    end

    refresh_file_comments(socket)
    fresh = if file_uuid, do: load_annotations_for(file_uuid), else: []

    socket =
      socket
      |> assign(:composing_annotation_uuid, nil)
      |> assign(:viewer_annotations, fresh)
      |> rebuild_viewer_canvas(fresh)
      |> put_flash(:info, gettext("Annotation saved"))

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

  defp rebuild_viewer_canvas(socket, annotations) do
    case socket.assigns[:file] do
      nil -> socket
      file -> assign(socket, :viewer_canvas, build_viewer_canvas(file, annotations))
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

  # Cancel path: drop the just-drawn shape so the canvas doesn't
  # carry an untitled placeholder. The `etcher:delete-shape` JS
  # bridge calls `layer.deleteShape(uuid)` — that removes the shape
  # from Etcher's local state + DOM, pushes the delete onto Etcher's
  # undo stack (Cmd+Z restores), and fires `annotations-changed`,
  # which sync_annotations picks up to delete the DB row + cascade
  # the comment hard-delete.
  defp rollback_annotation_compose(socket, annotation_uuid) do
    socket = assign(socket, :composing_annotation_uuid, nil)

    case {annotation_uuid, socket.assigns[:file]} do
      {uuid, %{file_uuid: file_uuid}}
      when is_binary(uuid) and is_binary(file_uuid) ->
        Phoenix.LiveView.push_event(socket, "etcher:delete-shape", %{
          fresco_id: "media-zoom-" <> file_uuid,
          uuid: uuid
        })

      _ ->
        socket
    end
  end

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
