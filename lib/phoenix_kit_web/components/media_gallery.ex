defmodule PhoenixKitWeb.Components.MediaGallery do
  @moduledoc """
  A general-purpose LiveComponent for selecting, ordering, previewing and removing
  a set of images.

  Generalizes the gallery + picker pattern so any PhoenixKit consumer can embed it
  instead of re-implementing the plumbing. The component manages an ordered list of
  file UUIDs and reports changes to the parent LiveView.

  ## Usage

      <.live_component
        module={PhoenixKitWeb.Components.MediaGallery}
        id="my-gallery"
        selected={@image_uuids}
        phoenix_kit_current_user={@current_user}
      />

      # Receive changes in parent LiveView
      def handle_info({PhoenixKitWeb.Components.MediaGallery, "my-gallery", {:changed, uuids}}, socket) do
        {:noreply, assign(socket, :image_uuids, uuids)}
      end

  ## Attrs

  - `id` — required; used for element IDs and change notifications
  - `title` — optional heading above the gallery
  - `selected` — ordered list of file UUIDs (current selection); default `[]`
  - `mode` — `:single` or `:multiple` (default `:multiple`)
  - `cols` — grid columns for the thumbnail layout (default `4`). Either an
    integer 1..6, or a string of Tailwind grid-column classes for a responsive
    grid (e.g. `"grid-cols-4 lg:grid-cols-6 2xl:grid-cols-8"`). Plumbed straight
    through to `<.draggable_list>`.
  - `featured_first` — when `true`, the first item in `:selected` renders a
    "Featured" badge in the top-left corner. Matches the
    `phoenix_kit_posts` post-creation convention where the first image is the
    featured one and drag-reordering changes the feature. Default `false` so
    existing consumers aren't surprised.
  - `scope_folder_id` — folder scope passed to the picker
  - `phoenix_kit_current_user` — required for upload in the picker
  - `readonly` — when `true`, hides the pick button, remove buttons, and DnD;
    preview (lightbox) still works; default `false`
  - `max_count` — integer upper bound on the number of selected images for
    `:multiple` mode; `nil` means unlimited. For `:single` mode the limit is
    always 1 (implied by `mode`). When the limit is reached, the "Add" tile is
    hidden entirely (not just disabled) and `apply_selection` refuses to exceed it.

  ## Change notifications — required host wiring (silent failure otherwise)

  This is a `LiveComponent`, so it has no `handle_info` of its own: after
  any change (pick / remove / reorder) it sends a **process message to the
  host LiveView** via `send/2`:

      {PhoenixKitWeb.Components.MediaGallery, id, {:changed, ordered_uuids}}

  The host MUST handle this (see the Usage example above) and persist
  `ordered_uuids` — it is a *controlled* component: it renders whatever the
  host passes back as `:selected`. Forget the handler and the user's
  picks/reorders are silently dropped (no crash, no warning). Each host
  stores the selection differently (its own field/assoc), so there is
  intentionally no `use ...Embed` macro — the handling is yours to write.

  ## Reorder event contract

  The thumbnail grid uses the canonical `<.draggable_list>` primitive
  (`PhoenixKitWeb.Components.Core.DraggableList`), which fires the
  `"reorder_images"` event with payload `%{"ordered_ids" => uuids}`.

  Because `MediaGallery` is a LiveComponent, the grid is rendered with
  `target={"#\#{@id}"}` so the `SortableGrid` hook routes the event via
  `pushEventTo` to this component's own `handle_event/3` — not the host
  LiveView. Each gallery's `id` is unique, so multiple galleries on the same
  page never cross-deliver reorder events.
  """
  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitWeb.Live.Components.MediaSelectorModal

  import PhoenixKit.Modules.Shared.Components.ImageSet

  @impl true
  def update(%{media_viewer_closed: true}, socket) do
    {:ok, assign(socket, :preview_uuid, nil)}
  end

  def update(%{media_selector_closed: true}, socket) do
    {:ok, assign(socket, :show_picker, false)}
  end

  def update(%{media_selected: uuids} = _assigns, socket) do
    uuids = uuids || []
    # Guard: if component hasn't been fully initialised yet these are nil-safe defaults.
    current = socket.assigns[:selected] || []
    mode = socket.assigns[:mode] || :multiple
    max_count = socket.assigns[:max_count]
    new_selected = apply_selection(current, uuids, mode, max_count)

    socket =
      socket
      |> assign_new(:show_picker, fn -> false end)
      |> assign(:selected, new_selected)
      |> load_files()
      |> assign(:show_picker, false)

    notify_parent(socket)
    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:selected, fn -> [] end)
      |> assign_new(:mode, fn -> :multiple end)
      |> assign_new(:cols, fn -> 4 end)
      |> assign_new(:featured_first, fn -> false end)
      |> assign_new(:scope_folder_id, fn -> nil end)
      |> assign_new(:phoenix_kit_current_user, fn -> nil end)
      |> assign_new(:readonly, fn -> false end)
      |> assign_new(:max_count, fn -> nil end)
      |> assign_new(:title, fn -> nil end)
      |> assign_new(:show_picker, fn -> false end)
      |> assign_new(:preview_uuid, fn -> nil end)
      |> assign_new(:files, fn -> [] end)
      |> assign_new(:variants_map, fn -> %{} end)
      |> assign_new(:rotations_map, fn -> %{} end)
      |> load_files()

    {:ok, socket}
  end

  @impl true
  def handle_event("open_picker", _params, socket) do
    {:noreply, assign(socket, :show_picker, true)}
  end

  def handle_event("remove_image", %{"uuid" => uuid}, socket) do
    new_selected = Enum.reject(socket.assigns.selected, &(&1 == uuid))
    socket = socket |> assign(:selected, new_selected) |> load_files()
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("preview_image", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, :preview_uuid, uuid)}
  end

  # Reorder event from <.draggable_list>: payload uses `ordered_ids` and the
  # event is routed to this component by the SortableGrid hook via
  # `pushEventTo` (the grid is rendered with `target={"##{@id}"}`).
  def handle_event("reorder_images", %{"ordered_ids" => ids}, socket) do
    current = socket.assigns.selected
    new_selected = Enum.filter(ids, &(&1 in current))
    # Append any current uuids that weren't in the payload (defensive; the
    # hook should always include every visible item).
    leftovers = Enum.reject(current, &(&1 in ids))
    new_selected = new_selected ++ leftovers

    socket = socket |> assign(:selected, new_selected) |> load_files()
    notify_parent(socket)
    {:noreply, socket}
  end

  # ── Private helpers ────────────────────────────────────────────────────

  defp load_files(socket) do
    selected = socket.assigns.selected

    # Skip the DB round-trip when the selection list hasn't changed.
    if selected == socket.assigns[:selected_loaded] do
      socket
    else
      do_load_files(socket, selected)
    end
  end

  defp do_load_files(socket, []) do
    assign(socket, files: [], variants_map: %{}, rotations_map: %{}, selected_loaded: [])
  end

  defp do_load_files(socket, selected) do
    files = Storage.get_files(selected)
    variants_map = Storage.list_image_set_variants_for_files(selected)

    assign(socket,
      files: files,
      variants_map: variants_map,
      rotations_map: rotations_map(files),
      selected_loaded: selected
    )
  rescue
    # Defensive degradation at the UI boundary — if Storage can't be reached
    # (DB outage, missing connection, sandbox unavailable in tests, cast on a
    # malformed UUID), render an empty gallery instead of crashing the
    # LiveView. The cases we explicitly anticipate: DBConnection.ConnectionError
    # (network/pool), Ecto.Query.CastError (bad UUID in the list), and
    # DBConnection.OwnershipError (Ecto.Adapters.SQL.Sandbox in tests that
    # exercise update/handle_event paths without checking out a connection).
    e in [
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Ecto.Query.CastError
    ] ->
      Logger.warning("MediaGallery: could not load files — #{Exception.message(e)}")
      assign(socket, files: [], variants_map: %{}, rotations_map: %{}, selected_loaded: nil)
  end

  # uuid => saved orientation, for the thumbnails' CSS transform. The grid
  # iterates uuids (not file structs), so it needs the lookup; keeps gallery
  # thumbnails the same way up as the media grid and the lightbox canvas.
  defp rotations_map(files) do
    Map.new(files, fn file -> {file.uuid, Map.get(file.metadata || %{}, "rotation")} end)
  end

  defp apply_selection(_current, uuids, :single, _max_count) do
    case uuids do
      [uuid | _] -> [uuid]
      [] -> []
    end
  end

  defp apply_selection(_current, uuids, _multiple, nil), do: uuids

  defp apply_selection(_current, uuids, _multiple, max_count)
       when is_integer(max_count) and max_count > 0 do
    Enum.take(uuids, max_count)
  end

  defp apply_selection(_current, uuids, _multiple, _max_count), do: uuids

  # Returns true when the current selection has reached its limit:
  # - :single mode → limit is always 1
  # - :multiple with a positive max_count → limit is max_count
  # - :multiple with nil or 0 max_count → unlimited (always false)
  defp selection_at_limit?(selected, :single, _max_count), do: selected != []

  defp selection_at_limit?(selected, _multiple, max_count)
       when is_integer(max_count) and max_count > 0 do
    length(selected) >= max_count
  end

  defp selection_at_limit?(_selected, _mode, _max_count), do: false

  defp notify_parent(socket) do
    parent = self()
    id = socket.assigns.id
    selected = socket.assigns.selected
    send(parent, {PhoenixKitWeb.Components.MediaGallery, id, {:changed, selected}})
  end
end
