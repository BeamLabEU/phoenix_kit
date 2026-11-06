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
    "Featured" badge in the bottom-left corner. Matches the
    `phoenix_kit_posts` post-creation convention where the first image is the
    featured one and drag-reordering changes the feature. Default `false` so
    existing consumers aren't surprised.
  - `scope_folder_id` — folder scope passed to the picker
  - `group_by_folder` — passed to the picker: `true` lists a scope that holds
    subfolders grouped by folder, under one heading each (see
    `MediaSelectorModal`); default `false`
  - `folder_labels` — passed to the picker: `%{folder_uuid => name}` shown in
    its folder headings instead of the stored folder names; default `%{}`
  - `picker_size` — the picker's `size`: `:default` or `:full` (the whole
    viewport, more files a page); default `:default`
  - `phoenix_kit_current_user` — required for upload in the picker
  - `readonly` — when `true`, hides the pick button, the tile menu, and DnD;
    preview (lightbox) still works; the server refuses pick, remove, trash and
    reorder events too; default `false`
  - `removal_guard` — the module asked before "Move to trash" (see "Tile
    actions"); `nil` takes the configured one, `false` goes without; default `nil`
  - `phoenix_kit_current_scope` — the scope of the person acting, handed to the
    removal guard; optional. A passed scope is used as given when the gallery
    acts, so the host keeps it current; without it one is built from
    `phoenix_kit_current_user` at the moment of each action
  - `external_picker` — when `true`, the "Add" tile asks the host to pick
    instead of opening the built-in `MediaSelectorModal` (which is then never
    rendered); see "External picker" below. Default `false`
  - `max_count` — integer upper bound on the number of selected images for
    `:multiple` mode; `nil` means unlimited. For `:single` mode the limit is
    always 1 (implied by `mode`). When the limit is reached, the "Add" tile is
    hidden entirely (not just disabled) and `apply_selection` refuses to exceed it.

  ## Tile actions

  Each tile has the preview (eye) button in its top-left corner and a ⋮ menu in
  its top-right corner. Both are shown on hover on a mouse screen and always on
  a touch screen (`pointer-coarse`), and on keyboard focus. The menu holds:

  - **Remove from selection** — takes the file out of the list (the file itself
    stays in the library) and reports `{:changed, uuids}`.
  - **Move to trash** — sends the file to the media trash, and takes it out of
    the list the same way. Shown only to a person who may change that file
    (`Libraries.can?(scope, file, :edit)`: its uploader, an Owner/Admin, a
    `media.view_all` holder), and only for a file that is in the selection.

  A readonly gallery shows the eye and no menu, and refuses both events.

  ### How "Move to trash" reuses the media browser's removal guard

  The gallery does not copy the browser's removal flow and does not make the
  host write one. It keeps its own small version of it, built from the same
  parts the browser uses: `Storage.removal_plan/2` says whether the file would
  disappear, `MediaBrowser.Removal` asks the host's
  `PhoenixKit.Modules.Storage.RemovalGuard` module (the configured one, or the
  `removal_guard` attribute) where the file is in use, and the browser's
  `RemovalModal` draws the dialog inside the gallery, so it looks and reads
  the same (and Escape closes it). The dialog always asks first, as the menu
  sits next to the harmless "Remove from selection":

  - not in use — "Move 1 file to trash?" with the name; the confirmation
    trashes the file;
  - in use — the places are listed, nothing is removed, and when the guard
    offers a release (the "unpin everywhere" button) pressing it releases the
    file and asks again;
  - the guard failed — "Could not check the files", nothing is removed.

  The confirmation re-reads the file, the plan and the guard's answer and
  trashes only what the dialog showed. On success the file is dropped from the
  selection and `{:changed, uuids}` is sent, so the host stores the shorter
  list as for any remove. The host needs no extra wiring for the dialog.

  The host must **persist** that `{:changed, uuids}` (as for every change): a
  trashed file is gone from the gallery's list, but the host's stored list
  still names it until the host saves the shorter one. A guard that reads only
  saved state does not see the gallery's current selection as a use, and an
  abandoned form leaves a reference to a trashed file. Store the list when the
  message arrives, or make the guard count the unsaved selection as a use.

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

  ## External picker

  With `external_picker={true}` the host supplies its own picker. Clicking
  "Add" sends the host LiveView (via `send/2`, like `{:changed, …}`):

      {PhoenixKitWeb.Components.MediaGallery, id,
       {:open_picker, %{selected: uuids, mode: :single | :multiple, max_count: integer | nil}}}

  The host hands the choice back with `send_update/2`. `media_selected` is the
  complete new selection, not an addition: it replaces `selected`, is limited
  by `mode` and `max_count` the same way as the built-in picker's, and the
  gallery then reports it as `{:changed, uuids}` like any other change. Not
  answering (the person cancelled) leaves the gallery as it was. Thumbnails,
  reordering, removal and the lightbox work as without the option; uploads
  are the host picker's business. A `readonly` gallery shows no "Add" tile and
  refuses `open_picker` on the server, so the host is never asked.

  - The host is not asked while the "Add" tile is hidden either — the
    selection is at `max_count`, or a `:single` gallery already holds a file
    — and a forged `open_picker` then is refused on the server.
  - Make the host's `handle_info` idempotent: every click sends a request, so
    a double click delivers two `{:open_picker, …}` messages.
  - Pass `media_selected` uuids without repeats; the gallery does not
    deduplicate the list.
  - Return image files only. The built-in picker is locked to images; the
    gallery does not filter what `media_selected` names, and a PDF or a video
    renders as a broken thumbnail.
  - Build the reply from the selection the host holds *now*, not from
    `request.selected`: that is a snapshot taken at the click, and a remove or
    reorder made while a non-modal host picker was open would be reverted by
    a reply built from it.

      <.live_component
        module={PhoenixKitWeb.Components.MediaGallery}
        id="my-gallery"
        selected={@image_uuids}
        external_picker={true}
      />

      def handle_info(
            {PhoenixKitWeb.Components.MediaGallery, "my-gallery", {:open_picker, request}},
            socket
          ) do
        # Open the host's picker; `request.selected` is the selection at the click.
        {:noreply, assign(socket, :picker_request, request)}
      end

      # Later, when the person confirms in the host's picker:
      send_update(PhoenixKitWeb.Components.MediaGallery, id: "my-gallery", media_selected: uuids)

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
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Components.MediaBrowser.Removal
  alias PhoenixKitWeb.Components.MediaBrowser.RemovalModal
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
      |> assign_new(:group_by_folder, fn -> false end)
      |> assign_new(:picker_size, fn -> :default end)
      |> assign_new(:folder_labels, fn -> %{} end)
      |> assign_new(:phoenix_kit_current_user, fn -> nil end)
      |> assign_new(:readonly, fn -> false end)
      |> assign_new(:external_picker, fn -> false end)
      |> assign_new(:max_count, fn -> nil end)
      |> assign_new(:removal_guard, fn -> nil end)
      |> assign_new(:phoenix_kit_current_scope, fn -> nil end)
      |> assign_scope()
      |> assign_new(:removal_pending, fn -> nil end)
      |> assign_new(:trashable, fn -> MapSet.new() end)
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
  # A readonly gallery renders no Add tile, remove buttons or drag handle;
  # refuse a forged event too. Preview stays available.
  def handle_event(event, _params, %{assigns: %{readonly: true}} = socket)
      when event in ~w(open_picker remove_image reorder_images trash_image removal_confirm removal_release) do
    {:noreply, socket}
  end

  def handle_event("open_picker", _params, %{assigns: %{external_picker: true}} = socket) do
    %{selected: selected, mode: mode, max_count: max_count} = socket.assigns

    # The "Add" tile is hidden at the limit; a forged click asks the host nothing.
    unless selection_at_limit?(selected, mode, max_count) do
      notify_parent(
        socket,
        {:open_picker, %{selected: selected, mode: mode, max_count: max_count}}
      )
    end

    {:noreply, socket}
  end

  def handle_event("open_picker", _params, socket) do
    {:noreply, assign(socket, :show_picker, true)}
  end

  def handle_event("remove_image", %{"uuid" => uuid}, socket) do
    new_selected = Enum.reject(socket.assigns.selected, &(&1 == uuid))
    socket = socket |> assign(:selected, new_selected) |> load_files()
    notify_parent(socket)
    {:noreply, socket}
  end

  # "Move to trash" from the tile menu: the removal guard is asked first and the
  # dialog shown (see the moduledoc's "Tile actions"); nothing is removed here.
  def handle_event("trash_image", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    {:noreply, decide_removal(socket, uuid, :fresh)}
  end

  def handle_event("removal_confirm", %{"token" => token}, socket) do
    case socket.assigns.removal_pending do
      %{token: ^token, uuid: uuid, failed?: false} = pending ->
        {:noreply, decide_removal(socket, uuid, {:confirm, pending})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("removal_release", %{"token" => token}, socket) do
    case socket.assigns.removal_pending do
      %{token: ^token, uuid: uuid, release_label: label} = pending when is_binary(label) ->
        {:noreply, release_removal(socket, uuid, pending)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("removal_cancel", %{"token" => token}, socket) do
    case socket.assigns.removal_pending do
      %{token: ^token} -> {:noreply, assign(socket, :removal_pending, nil)}
      _ -> {:noreply, socket}
    end
  end

  # A malformed event (no uuid, no token): nothing to answer.
  def handle_event(event, _params, socket)
      when event in ~w(trash_image removal_confirm removal_release removal_cancel),
      do: {:noreply, socket}

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
    assign(socket,
      files: [],
      variants_map: %{},
      rotations_map: %{},
      trashable: MapSet.new(),
      selected_loaded: []
    )
  end

  defp do_load_files(socket, selected) do
    files = Storage.get_files(selected)
    variants_map = Storage.list_image_set_variants_for_files(selected)

    assign(socket,
      files: files,
      variants_map: variants_map,
      rotations_map: rotations_map(files),
      trashable: trashable(socket, files),
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

      assign(socket,
        files: [],
        variants_map: %{},
        rotations_map: %{},
        trashable: MapSet.new(),
        selected_loaded: nil
      )
  end

  # The scope that draws the menu is built once per change of who the person is
  # (the scope the host hands in, else one made from the user) and kept in the
  # assigns: building one reads the person's roles and permissions. When it
  # changes, the menu's `trashable` set is judged again for the files shown.
  # Actions never read it: they decide with `acting_scope/1`.
  defp assign_scope(socket) do
    assigns = socket.assigns
    source = {assigns.phoenix_kit_current_scope, assigns.phoenix_kit_current_user}

    if assigns[:removal_scope_source] == source do
      socket
    else
      scope =
        case assigns.phoenix_kit_current_scope do
          %Scope{} = scope -> scope
          _ -> Scope.for_user(assigns.phoenix_kit_current_user)
        end

      socket
      |> assign(removal_scope: scope, removal_scope_source: source)
      |> assign_trashable()
    end
  end

  defp assign_trashable(%{assigns: %{files: files}} = socket),
    do: assign(socket, :trashable, trashable(socket, files))

  defp assign_trashable(socket), do: socket

  # The uuids of the files the person may send to the trash from the tile menu.
  defp trashable(socket, files) do
    case socket.assigns[:removal_scope] do
      nil -> MapSet.new()
      scope -> for file <- files, can_trash?(scope, file), into: MapSet.new(), do: file.uuid
    end
  end

  defp can_trash?(scope, file), do: Libraries.can?(scope, file, :edit)

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

  # ── "Move to trash" through the removal guard ──────────────────────────

  # `mode` is where the call came from: `:fresh` (the menu item),
  # `{:confirm, pending}` (the dialog's button) or `{:reask, pending}` (the
  # guard released the file). Only a confirmation removes anything, and only
  # what the dialog showed.
  defp decide_removal(socket, uuid, mode) do
    case removal_analysis(socket, uuid) do
      {:ok, analysis} -> removal_decide(socket, analysis, mode)
      :nothing -> assign(socket, :removal_pending, nil)
    end
  end

  # What trashing `uuid` would remove, from the plan the operation itself
  # follows (`Storage.removal_plan/2`). `:nothing` for a uuid that is not in the
  # selection, a file the person may not change, or one that is gone, already in
  # the trash or managed: any uuid can be sent from a console.
  defp removal_analysis(socket, uuid) do
    with true <- uuid in socket.assigns.selected,
         %Storage.File{} = file <- Storage.get_file(uuid),
         true <- can_trash?(acting_scope(socket), file),
         plan = Storage.removal_plan(:remove_file, {file, nil}),
         files when files != [] <- Enum.uniq(plan.trash ++ plan.delete) do
      {:ok, %{file: file, files: files, name: file.original_file_name || file.file_name}}
    else
      _ -> :nothing
    end
  end

  defp removal_ctx(socket),
    do: Removal.ctx(%{phoenix_kit_current_scope: acting_scope(socket)}, :trash_file, nil)

  # The scope an action is decided with. The cached `removal_scope` only drives
  # the menu; a user's rights can change while the page stays open, so when the
  # host passed no scope one is built again from the user at the moment of acting.
  defp acting_scope(%{assigns: %{phoenix_kit_current_scope: %Scope{} = scope}}), do: scope
  defp acting_scope(socket), do: Scope.for_user(socket.assigns.phoenix_kit_current_user)

  defp removal_decide(socket, analysis, mode) do
    ctx = removal_ctx(socket)
    module = Removal.guard(socket.assigns)

    case removal_places(module, analysis.files, ctx) do
      :error ->
        assign(socket, :removal_pending, removal_failed(analysis))

      {:ok, places} ->
        held = places |> Enum.map(& &1.file_uuid) |> Enum.uniq()
        free = analysis.files -- held

        case mode do
          {:confirm, shown} when held == [] and free != [] ->
            if same_removal?(shown, analysis, free),
              do: removal_execute(socket, analysis, shown),
              else: show_removal(socket, module, ctx, analysis, places, free, held, :changed)

          {:confirm, _shown} ->
            show_removal(socket, module, ctx, analysis, places, free, held, :changed)

          :changed ->
            show_removal(socket, module, ctx, analysis, places, free, held, :changed)

          _fresh_or_reasked ->
            show_removal(socket, module, ctx, analysis, places, free, held, nil)
        end
    end
  end

  # No guard: nothing is in use that the library can see, the dialog still asks.
  defp removal_places(nil, _files, _ctx), do: {:ok, []}
  defp removal_places(module, files, ctx), do: Removal.places(module, files, ctx)

  defp same_removal?(shown, analysis, free),
    do:
      Enum.sort(shown.files) == Enum.sort(analysis.files) and
        Enum.sort(shown.free) == Enum.sort(free)

  defp show_removal(socket, module, ctx, analysis, places, free, held, why) do
    error =
      if why == :changed, do: gettext("The files changed. Check the list and confirm again.")

    pending = %{
      removal_failed(analysis)
      | failed?: false,
        files: analysis.files,
        free: free,
        places: places,
        names: %{analysis.file.uuid => analysis.name},
        free_names: if(analysis.file.uuid in free, do: [analysis.name], else: []),
        release_label: if(module && held != [], do: Removal.release_label(module, ctx)),
        error: error
    }

    assign(socket, :removal_pending, pending)
  end

  defp removal_failed(analysis) do
    %{
      token: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      uuid: analysis.file.uuid,
      failed?: true,
      kind: :trash,
      skip?: false,
      folders: 0,
      selected_file_count: 0,
      folder_uuids: [],
      files: analysis.files,
      free: [],
      places: [],
      names: %{},
      free_names: [],
      free_hidden: 0,
      release_label: nil,
      error: nil
    }
  end

  # The confirmed removal: trashes the file, takes it out of the selection and
  # tells the host. The file is read and judged again by `removal_analysis/2`
  # just before this.
  defp removal_execute(socket, analysis, pending) do
    case Storage.remove_file_from_folder(analysis.file, nil) do
      {:ok, :trashed, _file} ->
        new_selected = Enum.reject(socket.assigns.selected, &(&1 == analysis.file.uuid))
        socket = socket |> assign(:removal_pending, nil) |> assign(:selected, new_selected)
        socket = load_files(socket)
        notify_parent(socket)
        socket

      _ ->
        assign(socket, :removal_pending, %{pending | error: gettext("Failed to move file")})
    end
  end

  # The release is the one step that changes host data, so it is judged again
  # like a confirmation: the file must still be in the selection, the person
  # must still be allowed, and the plan must be what the dialog showed. A file
  # that is no longer a candidate closes the dialog; a plan that changed
  # redraws it, and nothing is released.
  defp release_removal(socket, uuid, pending) do
    case removal_analysis(socket, uuid) do
      :nothing ->
        assign(socket, :removal_pending, nil)

      {:ok, analysis} ->
        if Enum.sort(analysis.files) == Enum.sort(pending.files),
          do: release_held(socket, analysis, pending),
          else: removal_decide(socket, analysis, :changed)
    end
  end

  defp release_held(socket, analysis, pending) do
    module = Removal.guard(socket.assigns)
    held = pending.places |> Enum.map(& &1.file_uuid) |> Enum.uniq()

    result =
      if module, do: Removal.release(module, held, removal_ctx(socket)), else: {:error, nil}

    case result do
      :ok ->
        decide_removal(socket, analysis.file.uuid, {:reask, pending})

      {:error, message} ->
        assign(socket, :removal_pending, %{pending | error: message || :generic})
    end
  end

  defp notify_parent(socket), do: notify_parent(socket, {:changed, socket.assigns.selected})

  defp notify_parent(socket, message) do
    send(self(), {PhoenixKitWeb.Components.MediaGallery, socket.assigns.id, message})
  end
end
