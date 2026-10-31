defmodule PhoenixKitWeb.Components.MediaBrowser do
  alias PhoenixKit.Utils.Pagination

  # What the toolbar's sort, type and shape accept: the events and the URL both
  # check against these.
  @valid_sorts ~w(newest oldest taken_oldest taken_newest name_asc name_desc largest smallest)
  @valid_file_types ~w(all image video document audio archive other)
  @valid_shapes ~w(all wide tall)

  @moduledoc """
  MediaBrowser LiveComponent — embeddable media management UI.

  Provides a full media browser with folder navigation, file upload, search,
  and selection tools. Operates in two modes:

  - **Uncontrolled** (default): all navigation state is owned internally.
    No URL sync.
  - **Controlled** (opt-in): when `on_navigate` is set to a truthy value,
    navigation events (`navigate_folder`, `search`, `clear_search`, `set_page`)
    emit `{PhoenixKitWeb.Components.MediaBrowser, id, {:navigate, params}}`
    to the parent LiveView process instead of mutating local state. The parent
    must call `push_patch` and feed URL params back via `send_update` with a
    `:nav_params` key.

  ## Enabling uploads

  The fastest path is the `Embed` helper — one `use` line gives you
  uploads, the validate-channel stub, and the message delegator:

      defmodule MyAppWeb.MediaPage do
        use MyAppWeb, :live_view
        use PhoenixKitWeb.Components.MediaBrowser.Embed
      end

  Manual setup (if you prefer explicit wiring) is three calls:

      def mount(_params, _session, socket) do
        {:ok, PhoenixKitWeb.Components.MediaBrowser.setup_uploads(socket)}
      end

      def handle_event("validate", _params, socket), do: {:noreply, socket}

      def handle_info({__MODULE__, _, _} = msg, socket) do
        PhoenixKitWeb.Components.MediaBrowser.handle_parent_info(msg, socket)
      end

  ## Usage (uncontrolled)

      <.live_component
        module={PhoenixKitWeb.Components.MediaBrowser}
        id="media-browser"
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />

  ## Picking into a typed slot

  `only_file_type` restricts the browser to one kind for its whole lifetime —
  the listing is filtered to it, the type-filter control is hidden, and an
  off-type upload is refused, so the other kinds are simply not reachable:

      <.live_component
        module={PhoenixKitWeb.Components.MediaBrowser}
        id="audio-picker"
        picker
        pick_mode={:single}
        only_file_type="audio"
        parent_uploads={@uploads}
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />

  Use it wherever the selection fills a typed field. Offering everything and
  validating afterwards works, but it lets someone choose a PNG for an audio
  slot and only find out on the rejection — and if a consumer forgets that
  re-check, the PNG lands in the field and renders as a dead `<audio>`.

  Values: `image`, `video`, `document`, `audio`, `archive`, `other`.

  ## Picker

  `picker` turns the browser into a window for choosing files — the folder
  tree, upload into the open folder, search and sort stay; what is chosen goes
  back to the host:

      <.live_component
        module={PhoenixKitWeb.Components.MediaBrowser}
        id="slot-picker"
        picker
        pick_mode={:multiple}
        max_select={4}
        selected={@slot_file_uuids}
        scope_folder_id={@order_folder_uuid}
        folder_labels={%{@kitchen_folder_uuid => "Kitchen"}}
        folder_actions={false}
        only_file_type="image"
        parent_uploads={@uploads}
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />

  - `picker` (default `false`) — a click on a file picks it and opens no
    viewer; folders are browsed, never picked. The view is always the grid
    (no view switch), and the picker writes none of the user's view or
    folder-tree preferences. Bulk select (Select, box select, Shift-click,
    long press) is off: the pick is its own ordered list. The toolbar shows
    the count with Confirm and Cancel.
    Set it when the browser is mounted: the view, the tree and the upload
    registration are made then, so turning it on or off on a mounted browser
    leaves it half one and half the other. Mount another browser instead.
  - `pick_mode` — `:multiple` (default) keeps the files in the order they were
    picked, a second click takes one out; `:single` replaces the pick on every
    click, and a double click picks and confirms.
  - `max_select` — the most files `:multiple` takes (`nil`, the default, is no
    limit). A click past it is refused and the toolbar says so.
  - `selected` — the pick the browser opens with, in order. Read on the
    first mount only: a later render of the host (an upload tick, any changed
    assign) leaves the working pick alone. Replace it with
    `send_update(MediaBrowser, id: id, picker_reset: uuids)`. Both keep what
    a click could pick (below), at most `max_select` of it (one in
    `:single`); anything else is dropped without a word, and Confirm returns
    the list without it — a slot's file outside the scope, in the trash or of
    another type leaves the slot when the person confirms.
  - `notify` — `{module, id}` of a host LiveComponent. Confirm sends it
    `send_update(module, id: id, picked: uuids)`, Cancel
    `picked: :cancelled`, and a change of the upload state
    `picker_uploading: boolean`. Without `notify` the host LiveView process
    gets THREE messages, and must match all three (or have a catch-all
    `handle_info`): `{MediaBrowser, id, {:picked, uuids}}`,
    `{MediaBrowser, id, :pick_cancelled}` and
    `{MediaBrowser, id, {:picker_uploading, boolean}}` — the last one with every
    upload, whether or not the host cares. ⚠️ A host that funnels every
    `{MediaBrowser, _, _}` message into `handle_parent_info/2` must match them
    before it, as with `{:set_featured, _}`: the delegate only logs them. A
    Confirm or Cancel pressed again with nothing changed is reported once, so
    a host that keeps the picker mounted between openings (hidden, not
    removed) sends `picker_reset` when it opens it again — otherwise a
    Confirm of the same pick reports nothing.
  - `folder_labels` — `%{folder_uuid => label}`: the label is shown instead of
    the folder's name in the tree, the breadcrumbs, the title and the folder
    tiles. Display only; nothing is renamed.
  - `folder_actions` (default `true`) — `false` takes away New folder,
    renaming and every other folder edit (header, description, colour,
    cover), moving files and folders, trashing and deleting folders, the
    sidebar's Trash link and drag moves: hidden AND refused on the server.
    Dropping files from the computer still uploads. A file moved to the Trash
    from such a browser cannot be brought back from it (the Trash view and
    Restore are folder actions here). Outside a picker the file cards stay
    draggable for the selection gestures (long press, Shift-click, box
    select), but no folder, tree node or Trash takes a move, and folders are
    never selected. The content area stays a drop target, for files dropped
    from the computer; a move dropped there is refused on the server.

  A picker's file menu keeps Download and Move to Trash. Rotate, Edit image,
  the featured toggle and deleting for good (the Trash view's Delete, Empty
  Trash) are hidden and refused: the files are someone's, opened to be chosen
  from.

  Every pick is checked on the server, whatever the click named: a file of
  this library the viewer may see, live (not in the trash), inside the scope
  folder (homed there or linked into it) and of `only_file_type`. Confirm
  leaves out a picked file that has been trashed or deleted since. A file
  uploaded in the picker picks itself, under the same check — the store
  answers with the row it kept, and a duplicate of an earlier upload is that
  row, in the trash or of another type: `:single` replaces the pick,
  `:multiple` adds it while there is room under `max_select`.

  While an upload is on its way (a transfer, or a file waiting to be stored)
  Confirm and Cancel are disabled with a note, and refused, and the host is
  told (`picker_uploading`) so it can keep its own close control from
  dropping the upload.

  A file's tile has an eye: it opens the viewer on that file and changes
  nothing in the pick (nor does closing the viewer). Previous / next step
  through the files loaded on the page of the open folder. The viewer's
  Select / Deselect picks or unpicks the file shown, under the same rules
  and server check as a click (`:single` replaces; Deselect empties it);
  Select is disabled while `:multiple` is at `max_select`. The viewer writes
  nothing to the file — no rotation saved, no annotations, no title or
  description, no image editor, no featured toggle, refused on the server as
  under `readonly` — but offers Move to trash for a live file (not under
  `readonly`; `folder_actions: false` does not take it away, it is an action
  on a file). A file removed that way leaves the pick.

  Escape closes the viewer and nothing else: the pick stays and the picker
  stays open. The viewer opens in the browser's top layer (a `popover`), so
  a host modal whose box is transformed (daisyUI's `.modal-box` is) cannot
  clip it, and while it is open its Escape is cancelled for the page, so a
  host `<dialog>` — core `<.modal>`, or any dialog with the `PkDialog` hook —
  stays open: hosts of those need nothing. A host that closes its modal on
  Escape by its own key listener (`phx-window-keydown`, a script) must skip
  an Escape whose `defaultPrevented` is set, or it closes with the viewer.

  A picker is usually a second browser on its page, so its DOM ids carry its
  `id` (`<id>-media-browser-sidebar`, `<id>-folder-drop-upload-form`, …).
  Without `picker` the ids are the ones they have always been — hosts, tests
  and scripts select them by name — so two browsers that are not pickers on
  one page still share them, as before.

  A picker uploads through an upload of its own, `:media_picker_files`, which
  `setup_uploads/1` (and so `Embed`) registers next to `:media_files` with the
  same limits. A page has one file input per upload: sharing `:media_files`
  would give a picker opened beside another browser a second input with the
  same id, the other browser's transfers in its list, and its uploads copied
  into the other browser's folder too. A picker's upload goes to the pickers
  only, any other upload to the other browsers only. A host that calls
  `allow_upload` itself instead of `setup_uploads/1` adds
  `:media_picker_files` with the same options (`progress:
  &MediaBrowser.parent_progress/3`) for a picker beside another browser;
  without it the picker uses `:media_files`, which is fine while it is the
  only browser on the page. `only_file_type` is held for either upload.

  ## Removal guard

  A file can be in use where the media library cannot see — an order's
  attachment, a page's picture. `config :phoenix_kit, :file_removal_guard,
  MyApp.FileRemovalGuard` names a module (the
  `PhoenixKit.Modules.Storage.RemovalGuard` behaviour) that every media
  browser asks before a file disappears, the Media page of the core included:

  - `removal_guard` — overrides the configured module for one browser; `false`
    goes without. With no module configured, nothing here applies: the browser
    acts and confirms as it always did.
  - `phoenix_kit_current_scope` — the scope of the person acting, handed to the
    guard as `ctx.scope`. A host that narrows rights to the person's active role
    passes the narrowed scope; without it the scope is built from
    `phoenix_kit_current_user`.

  The events that can remove a file — `trash_file` (tile, menu, viewer, the drag
  onto Trash), `delete_file`, `delete_selected` (folders in it too),
  `trash_folder`, `delete_folder` and `empty_trash` — are stopped before their
  handlers. `Storage.removal_plan/2`, the reading the operations themselves
  decide by, says which files would be trashed or deleted; a file only unlinked
  from a folder or re-homed to another that holds it is not asked about. The
  module is asked where the others are in use, and a **server dialog** (inside
  the browser, above an open viewer, Escape closes it and not the viewer or the
  picker) asks the person:

  - no place: "Move 3 files to trash?" / "Delete 3 files for good?" with the
    names, then the action runs;
  - places: "Cannot delete: the file is in use", with the places (links open in
    a new tab; a place with no label is "not available to you"). When the module
    has `release/2` and `release_label/1` gives this person a text, a button with
    it frees the files, the module is asked again, and the confirmation follows;
  - **Empty trash** and deleting a selection of files in the Trash view skip the
    files that are in use (they stay in the trash): "2 deleted, 1 kept: in use".

  The browser's own `data-confirm` for these actions is dropped while a guard is
  configured (it would be a second question). A folder is confirmed in the
  dialog even when no file goes with it. The confirmation runs the same event
  again through every gate (readonly, `viewer_uuid`, `own_files_only`, the shown
  library) and from a fresh plan: if the files, or what is in use, changed since
  the dialog was drawn, the dialog is drawn again instead of removing. A guard
  that raises, exits or answers a shape that is not the contract removes
  nothing (the log names the module and the exception, no request data).

  **Not covered**, by design: the daily `Storage.prune_trash/1`, the host's own
  background jobs, the API and the console, and "Delete all orphaned" (an orphan
  is in no folder).

  ## Taking a browser off the page

  The page routes every finished upload to each browser that registered on
  mount. A host that stops rendering one (a closed modal, another tab) calls
  `unregister_browser/1` with its id, or uploads keep being routed — and
  copied — to it. With no browser registered an upload is not deleted: it
  stays in the user's upload inbox and shows under "Upload problems", with
  Retry, in the next browser opened.

  ## Usage (controlled — URL-sync driven by parent)

      <.live_component
        module={PhoenixKitWeb.Components.MediaBrowser}
        id="media-browser"
        phoenix_kit_current_user={@phoenix_kit_current_user}
        on_navigate={true}
      />

  The parent LiveView must implement:

      def handle_info({PhoenixKitWeb.Components.MediaBrowser, "media-browser",
                       {:navigate, params}}, socket) do
        # push_patch to update URL, handle_params will send_update back
      end

  `params` carries `:file` — the uuid of the file open in the modal viewer, or
  `nil` when it is closed. Put it in the URL and hand it back in `:nav_params`
  and a refresh, or the browser's Back button, reopens or closes the viewer.
  A host that leaves the key out of `:nav_params` altogether keeps the viewer
  local to the component; only an explicit `file: nil` closes it.

  ## Required attributes

  - `id` — unique DOM id (required by LiveComponent)

  ## Optional attributes

  - `phoenix_kit_current_user` — logged-in user struct (for upload attribution)
  - `scope_folder_id` — constrain the browser to a virtual root folder
  - `on_navigate` — when truthy, enables controlled mode (URL-sync via parent)
  - `admin` — clicking a file always opens the in-place modal viewer
    (image / video / PDF / icon + metadata + Download + prev/next
    navigation). When `true`, the viewer sidebar additionally shows an
    "Open details page" button linking to `/admin/media/:uuid`, and
    rotations made in the viewer persist to the file row. Bulk-select is
    still reachable via the toolbar's Select button — once `select_mode`
    is on, clicks toggle selection instead of opening the modal.
  - `readonly` (default `false`) — embed the browser for viewing only.
    Every write-capable affordance is hidden — the upload zone and
    drag-drop upload input, the toolbar's Add Media / Select / New folder
    controls (including the stacks-view "+" tile and the sidebar's own
    "+"/rename/drag affordances), every folder and file kebab menu item
    except Download, and every `data-draggable-*` / `data-drop-*` drag
    attribute. Navigation, search, sorting, the modal viewer, and
    downloads keep working. When `featured` is also set, the featured
    tile's star still renders (display only) but the other tiles' star
    toggles and the kebab's Set/Unset featured item do not.

    The hidden markup is a courtesy, not the boundary: every mutating
    `handle_event` clause (upload, rename, move, trash, new folder,
    bulk-select entry, rotate, featured toggle, open the image editor)
    refuses outright when `readonly` is set, because *the event is still
    reachable from a console* — same reasoning as the `only_file_type`
    lock on `set_file_filter`. The same applies one level down, inside
    the modal viewer's `MediaCanvasViewer`: readonly passes
    `can_annotate={false}` (Etcher shapes lock), `edit_target={nil}` AND
    `details_path={nil}` (title/alt/description save refuses only when
    BOTH are nil), and `persist_rotation={false}`.

    A browser showing a managed library (`library_uuid`, see
    `PhoenixKit.Modules.Storage.Libraries.managed?/1`) is `readonly` whatever
    the host passed.

    Typical use: embedding the browser on a page where the viewer should
    only look, not touch —

        <.live_component
          module={PhoenixKitWeb.Components.MediaBrowser}
          id="order-files-viewonly"
          scope_folder_id={@order.storage_folder_uuid}
          readonly
        />
  - `featured` — `nil` (default, feature off) or `%{uuid: uuid | nil,
    label: String.t() | nil}` naming the host's own featured-image
    pointer. `label` is the star badge's tooltip; falls back to gettext
    "Featured image" when nil/absent. When set, image tiles/rows gain a
    "Set as featured" / "Unset featured" kebab item (grid, list and
    stack views) and a star toggle in the top-left corner of every image
    tile (grid and stack views): a solid star on the matching tile
    (`data-role="featured-badge"`, a click clears it), an outline star on
    the others (`data-role="featured-toggle"`, a click moves the pointer
    there). In select mode, the trash, or `readonly`, only the matching
    tile shows its star, as a plain badge. The modal viewer's sidebar (for
    image files) shows the same toggle. The browser never persists anything itself:
    choosing or clearing a featured image sends
    `{__MODULE__, id, {:set_featured, uuid | nil}}` to the host
    process — the `{MediaBrowser, id, payload}` channel `{:navigate, _}`
    already uses — and optimistically moves the badge locally.
    ⚠️ A host that funnels every `{MediaBrowser, _, _}` message into
    `handle_parent_info/2` **must match `{:set_featured, _}` before it**:
    that function handles only its own two internal messages and ends in
    a catch-all, so the choice is swallowed silently — no crash, no log,
    the star flips in the UI and nothing is ever persisted. The host persists the choice and, if the write is
    rejected or the pointer changes elsewhere, corrects it with a later
    `featured` assign (e.g. via `send_update`).
  """
  use PhoenixKitWeb, :live_component

  # A component's flash never reaches the page — LiveView keeps it to the
  # component — and this browser said everything with `put_flash`: every
  # delete, move, restore, rename and their failures went unseen. Its
  # `put_flash` also hands the message to the host LiveView
  # (`parent_flash/3`, put by `handle_parent_info/2`, which every host gets
  # from `MediaBrowser.Embed`). The component keeps its own copy as well, as
  # it always did, for anything that reads the component's state.
  import Phoenix.LiveView, except: [put_flash: 3]

  require Logger

  import Ecto.Query

  # The template and the helpers it draws with live in `MediaBrowser.View`
  # (media_browser/view.ex): split off so neither module is slow to compile
  # on its own. `render/1` calls the view as a plain function, so LiveView's
  # change tracking is exactly what it was with a colocated template.
  # Called by module, never imported: an import would make this module wait
  # for the view to finish compiling instead of compiling beside it.
  alias PhoenixKitWeb.Components.MediaBrowser.Helpers
  alias PhoenixKitWeb.Components.MediaBrowser.Removal
  alias PhoenixKitWeb.Components.MediaBrowser.View

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.ImageEditing
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.UploadInbox
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Modules.Storage.VariantSets
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.TreeQuery
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitWeb.Components.Core.MediaThumbnail

  # Grid/list view preference is persisted per-user in `custom_fields`
  # ("user meta") so the server renders the correct mode on first paint —
  # no grid→list flash while the client restores a localStorage value
  # after connect.
  @media_view_mode_key "media_view_mode"

  # The parent's upload a picker renders and watches (see `setup_uploads/1`).
  @picker_upload :media_picker_files

  # Sidebar folder-tree state, also persisted server-side in user meta and
  # rendered on first paint — same reasoning as the view mode above: restoring
  # the expanded folders from localStorage only after connect made the tree
  # render fully collapsed and then jump to its open positions.
  @media_expanded_folders_key "media_expanded_folders"
  @media_sidebar_collapsed_key "media_sidebar_collapsed"

  # ──────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────

  # Comment activity on a file (relayed by the Embed macro from the
  # `{:comments_updated, ...}` process message). When the open viewer shows
  # that file, poke its canvas component to reload annotations — the
  # tooltip's "N comments" and the on-shape badge are derived from the
  # comment table and would otherwise stay stale until the next open.
  def render(assigns), do: View.browser(assigns)

  @doc false
  defdelegate upload_problems(assigns), to: Helpers
  @doc false
  defdelegate viewer_component_id(f), to: Helpers
  @doc false
  defdelegate viewer_component_id(f, assigns), to: Helpers
  @doc false
  defdelegate image_editor_id(browser_id, file_uuid), to: Helpers
  @doc false
  defdelegate panorama?(file), to: Helpers
  @doc false
  defdelegate viewer_open_url(file), to: Helpers

  def update(%{file_comments_changed: %{resource_uuid: file_uuid}}, socket) do
    case socket.assigns[:viewer_file] do
      %{file_uuid: ^file_uuid} = f ->
        send_update(PhoenixKitWeb.Components.MediaCanvasViewer,
          id: viewer_component_id(f, socket.assigns),
          action: :refresh_annotations
        )

      _ ->
        :ok
    end

    {:ok, socket}
  end

  # The viewer's "Edit image" button. Unreachable under readonly from the
  # client (the button itself is already gone — see edit_target in the
  # heex), but guarded here too for defense-in-depth, same as every other
  # write path.
  def update(%{open_image_editor: _uuid}, %{assigns: %{readonly: true}} = socket) do
    {:ok, socket}
  end

  def update(%{open_image_editor: file_uuid}, socket) do
    {:ok, open_image_editor(socket, file_uuid)}
  end

  # A file was trashed elsewhere (another tab, another browser instance). It
  # drops out of this browser's lists only if this one is NOT showing the
  # Trash view — a Trash view is where it now belongs, but re-inserting it
  # there mid-page would need re-paging, so it is picked up on the view's
  # next load instead.
  def update(%{file_trashed: file_uuid}, socket) do
    {:ok, drop_files_unless(socket, [file_uuid], socket.assigns[:filter_trash])}
  end

  # The bulk shapes: every file one folder operation swept up, handled as one
  # update — one pass over each list and one render, not one per file.
  def update(%{files_trashed: file_uuids}, socket) do
    {:ok, drop_files_unless(socket, file_uuids, socket.assigns[:filter_trash])}
  end

  def update(%{files_restored: file_uuids}, socket) do
    {:ok, drop_files_unless(socket, file_uuids, !socket.assigns[:filter_trash])}
  end

  def update(%{files_deleted: file_uuids}, socket) do
    {:ok, remove_files_from_lists(socket, file_uuids)}
  end

  # A file was restored out of trash elsewhere. Symmetric to `file_trashed`
  # above: it drops out only if this browser IS showing the Trash view
  # (where it no longer belongs).
  def update(%{file_restored: file_uuid}, socket) do
    {:ok, drop_files_unless(socket, [file_uuid], !socket.assigns[:filter_trash])}
  end

  # A file was permanently deleted elsewhere — gone from every view.
  def update(%{file_deleted: file_uuid}, socket) do
    {:ok, remove_files_from_lists(socket, [file_uuid])}
  end

  # The inbox poll (see `schedule_inbox_poll/1`).
  def update(%{action: :refresh_inbox_problems}, socket) do
    {:ok, socket |> assign(:inbox_poll_scheduled, false) |> refresh_inbox_problems()}
  end

  def update(assigns, socket) do
    shown_library = socket.assigns[:library_uuid]

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:scope_folder_id, fn -> nil end)
      # The storage library shown (`Storage.Libraries`). nil lists every
      # library that is not private.
      |> assign_new(:library_uuid, fn -> nil end)
      |> assign_new(:admin, fn -> false end)
      |> assign_new(:can_manage_storage, fn -> false end)
      # When true, every write path is hidden AND refused server-side —
      # upload, rename, move, trash, new folder, bulk-select, rotate,
      # featured toggle, image editor. Navigation, the viewer and downloads
      # stay live. See the moduledoc's `readonly` attribute.
      |> assign_new(:readonly, fn -> false end)
      # A user uuid: every write may touch only files that user uploaded
      # (a user library's contributor). Folders stay shared. nil: no limit.
      |> assign_new(:own_files_only, fn -> nil end)
      # A user uuid: the browser shows this viewer only what is theirs in the
      # site library it is showing (`Storage` `:viewer_uuid`): the files they
      # uploaded, the folders they created or that hold their files, those
      # folders' ancestors. Every event that names a file or folder of someone
      # else is refused, and so is changing a folder they did not create. nil: no
      # limit (every other host). `Live.Users.Media` sets it for a holder of
      # `media` without `media.view_all`.
      |> assign_new(:viewer_uuid, fn -> nil end)
      # Restricts the browser to ONE file type for its whole lifetime: the
      # listing is filtered to it, the type-filter control is hidden, and an
      # off-type upload is refused, so there is no way to reach the other
      # kinds — including by uploading one. For pickers that fill a
      # typed slot — an audio field, an image field — where offering
      # everything means the only thing standing between a PNG and an
      # <audio> tag is the consumer remembering to re-check afterwards.
      # nil (default) leaves the toolbar in charge, starting at "all".
      |> assign_new(:only_file_type, fn -> nil end)
      # `nil` (default) keeps the featured-image UI off entirely. A map
      # turns it on; `notify_featured/2` rewrites `:uuid` in place on
      # every toggle so the badge/kebab reflect the choice immediately,
      # ahead of the host's own write landing.
      |> assign_new(:featured, fn -> nil end)
      |> assign_new(:viewer_file, fn -> nil end)
      # The list the open viewer's prev/next steps through — the page's
      # files, or an expanded stack's own (see `locate_file/2`).
      |> assign_new(:viewer_siblings, fn -> [] end)
      # When true, the browser fills its parent's width + height (flex-1)
      # instead of the default fixed-height card. Used by the full-page
      # admin media view; modal/gallery embeds keep the bounded default.
      |> assign_new(:fill_height, fn -> false end)
      # Gallery mode: swipe, drag or trackpad-scroll between pictures in the
      # viewer, the next one sliding in beside the current (Fresco.gallery).
      # Off by default while it settles; the full-page media view turns it on.
      |> assign_new(:gallery_mode, fn -> false end)
      |> assign_new(:upload_in_flight, fn -> false end)
      |> assign_new(:upload_problems_session, fn -> [] end)
      # The picker (see the moduledoc's "Picker"). `picked` is the working
      # pick, an ordered list of file uuids; `selected` is only where it
      # starts (first mount) — the host's later renders never reach it.
      |> assign_new(:picker, fn -> false end)
      |> assign_new(:pick_mode, fn -> :multiple end)
      |> assign_new(:max_select, fn -> nil end)
      |> assign_new(:selected, fn -> [] end)
      |> assign_new(:notify, fn -> nil end)
      |> assign_new(:folder_labels, fn -> %{} end)
      |> assign_new(:folder_actions, fn -> true end)
      # The removal guard (see the moduledoc's "Removal guard"): `nil` takes
      # the module configured for every browser, a module overrides it,
      # `false` goes without. `removal_pending` is the dialog's state.
      |> assign_new(:removal_guard, fn -> nil end)
      |> assign_new(:phoenix_kit_current_scope, fn -> nil end)
      |> assign_new(:removal_pending, fn -> nil end)
      |> normalize_picker_attrs()
      |> assign_removal_guarded()
      |> assign_upload_name()
      |> assign_new(:picked, fn -> [] end)
      |> assign_new(:pick_limit_hit, fn -> false end)
      |> assign_new(:picker_uploading, fn -> false end)
      |> close_upload_on_start()
      |> harvest_rejected_uploads()
      |> force_managed_readonly()

    socket = maybe_switch_library(socket, shown_library)

    socket =
      cond do
        not Map.has_key?(socket.assigns, :uploaded_files) ->
          socket = init_socket(socket)

          # Register this component id with the parent so it can route uploads here
          send(self(), {__MODULE__, :register_component, socket.assigns.id})

          socket = put_pick(socket, start_pick(socket, socket.assigns.selected))

          # Apply initial params if provided (avoids flash of root before correct view)
          if Map.has_key?(assigns, :initial_params),
            do: apply_nav_params(socket, assigns.initial_params),
            else: socket

        Map.has_key?(assigns, :picker_reset) ->
          put_pick(socket, start_pick(socket, assigns.picker_reset))

        Map.get(assigns, :action) == :picker_idle_check ->
          settle_picker_idle(socket)

        true ->
          update_from_message(socket, assigns)
      end

    {:ok, socket |> maybe_register_picker() |> sync_picker_uploading()}
  end

  defp update_from_message(socket, assigns) do
    cond do
      Map.has_key?(assigns, :nav_params) ->
        apply_nav_params(socket, socket.assigns.nav_params)

      Map.has_key?(assigns, :pending_upload) ->
        receive_pending_upload(socket, assigns.pending_upload)

      Map.get(assigns, :action) == :drain_upload_queue ->
        drain_upload_queue(socket)

      # Background processing finished (see attach_file_event_forwarding/1).
      Map.has_key?(assigns, :file_processed) ->
        notify_image_editor(socket, assigns.file_processed)
        refresh_processed_file(socket, assigns.file_processed)

      # Annotated thumbnail (re)baked, or a burn stored — refresh the grid
      # row only. The open viewer must NOT be swapped: the annotator is
      # usually still working in it, and a viewer_file swap changes the
      # canvas-viewer LC id (it encodes the variant count), remounting the
      # canvas mid-edit.
      #
      # The canvas component is poked separately, because a BURN is the one
      # thing an open viewer should follow: someone on another device just
      # replaced the picture it is showing. It decides whether to take it —
      # only that component knows whether the editor is open (see
      # `MediaCanvasViewer.update/2`, `burn_refreshed`).
      Map.has_key?(assigns, :thumbnail_updated) ->
        socket = refresh_processed_file(socket, assigns.thumbnail_updated, viewer: false)
        poke_viewer_burn(socket, assigns.thumbnail_updated)
        socket

      # The header-image picker (MediaSelectorModal) reports back here via
      # `notify: {__MODULE__, id}`: a confirmed selection sets the cover or logo
      # (per `@image_picker_target`); a close just dismisses the picker.
      Map.has_key?(assigns, :media_selected) ->
        set_image_from_selection(socket, assigns.media_selected)

      Map.has_key?(assigns, :media_selector_closed) ->
        assign(socket, :selecting_cover, false)

      Map.get(assigns, :action) == :commit_upload_batch ->
        commit_upload_batch(socket)

      true ->
        socket
    end
  end

  # A managed library (`Libraries.managed?/1`) is browsed read-only whoever
  # opens it and whatever the host passed: every write path below refuses
  # under `readonly`, and the context refuses again. Asked again only when the
  # library on screen changes.
  defp force_managed_readonly(socket) do
    library = socket.assigns[:library_uuid]

    managed? =
      case socket.assigns[:managed_library] do
        {^library, managed?} -> managed?
        _ -> Libraries.managed?(library)
      end

    socket = assign(socket, :managed_library, {library, managed?})
    if managed?, do: assign(socket, :readonly, true), else: socket
  end

  # ──────────────────────────────────────────────────────────────
  # Picker (see the moduledoc's "Picker")
  # ──────────────────────────────────────────────────────────────

  defp normalize_picker_attrs(socket) do
    pick_mode = if socket.assigns.pick_mode in [:single, "single"], do: :single, else: :multiple

    max_select =
      case socket.assigns.max_select do
        n when is_integer(n) and n > 0 -> n
        _ -> nil
      end

    socket
    |> assign(:picker, socket.assigns.picker == true)
    |> assign(:folder_actions, socket.assigns.folder_actions != false)
    |> assign(:pick_mode, pick_mode)
    |> assign(:max_select, max_select)
  end

  # The parent's upload this browser renders and watches: a picker's own
  # (see `setup_uploads/1`), or the shared one — also for a picker whose host
  # allowed only that.
  defp assign_upload_name(socket) do
    name =
      if socket.assigns.picker and
           is_map_key(socket.assigns[:parent_uploads] || %{}, @picker_upload),
         do: @picker_upload,
         else: :media_files

    assign(socket, :upload_name, name)
  end

  # A browser on the picker's own upload takes only that upload's files (see
  # `setup_uploads/1`); a picker on `:media_files` (a host that allowed only
  # that) is routed like any other browser. Registered once, whenever the
  # picker's upload first reaches it — a host may hand `parent_uploads` down
  # after the first render.
  defp maybe_register_picker(socket) do
    if socket.assigns.upload_name == @picker_upload and socket.assigns[:registered_picker] != true do
      send(self(), {__MODULE__, :register_picker, socket.assigns.id})
      assign(socket, :registered_picker, true)
    else
      socket
    end
  end

  # The pick a picker opens with (`selected`) or is reset to (`picker_reset`):
  # what a click could pick (`pickable?/2`) — anything else is dropped without
  # a word — each once, in the host's order, one in `:single` and at most
  # `max_select` in `:multiple`.
  defp start_pick(%{assigns: %{picker: true}} = socket, uuids) when is_list(uuids) do
    uuids = uuids |> Enum.filter(&uuid_string?/1) |> Enum.uniq()

    limit =
      case socket.assigns do
        %{pick_mode: :single} -> 1
        %{max_select: max} when is_integer(max) -> max
        _ -> :infinity
      end

    picked = pickable_uuids(socket, uuids)
    if limit == :infinity, do: picked, else: Enum.take(picked, limit)
  end

  defp start_pick(_socket, _uuids), do: []

  # Every change of the pick goes through here: a Confirm reported before it
  # no longer stands for what is picked (see `report_once/2`).
  defp put_pick(socket, uuids) do
    socket
    |> assign(:picked, uuids)
    |> assign(:pick_limit_hit, false)
    |> assign(:pick_reported, nil)
  end

  # A uuid in its 36-character text form. `Ecto.UUID.cast/1` alone would also
  # take any 16-byte string as a raw uuid.
  defp uuid_string?(value),
    do: is_binary(value) and byte_size(value) == 36 and UUIDUtils.valid?(value)

  # A click on a file. `:multiple` takes a picked file back out; `:single`
  # keeps it (a file dialog does not unselect on a second click). Adding is
  # for a file this picker could have listed only.
  defp pick(socket, file_uuid) do
    %{picked: picked, pick_mode: pick_mode} = socket.assigns

    cond do
      file_uuid in picked and pick_mode == :multiple ->
        put_pick(socket, List.delete(picked, file_uuid))

      file_uuid in picked ->
        socket

      pickable?(socket, file_uuid) ->
        add_pick(socket, file_uuid)

      true ->
        # The value is the client's: only the fact is logged.
        Logger.warning(
          "MediaBrowser id=#{socket.assigns.id}: pick refused — not a file this picker lists"
        )

        socket
    end
  end

  # `:single` replaces the pick; `:multiple` appends while there is room under
  # `max_select`, and says so when there is not.
  defp add_pick(socket, file_uuid) do
    %{picked: picked, pick_mode: pick_mode, max_select: max} = socket.assigns

    cond do
      pick_mode == :single ->
        put_pick(socket, [file_uuid])

      file_uuid in picked ->
        socket

      is_integer(max) and length(picked) >= max ->
        assign(socket, :pick_limit_hit, true)

      true ->
        put_pick(socket, picked ++ [file_uuid])
    end
  end

  # What the picker could have listed, whatever page, search or filter is on
  # screen: a live file of this library that the viewer may see, of the
  # locked type, homed inside the scope folder or linked into it.
  defp pickable?(socket, file_uuid) do
    uuid_string?(file_uuid) and pickable_uuids(socket, [file_uuid]) != []
  end

  # Read in bulk while preserving the host's order. Opening or confirming a
  # large pick must not query the file and scope subtree once per entry.
  defp pickable_uuids(socket, uuids) do
    allowed =
      uuids
      |> load_by_uuid(Storage.File)
      |> shown_only(socket)
      |> Enum.filter(fn file ->
        not file.system_managed and file.status != "trashed" and
          socket.assigns[:only_file_type] in [nil, file.file_type]
      end)
      |> in_pick_scope(scope_folder_id(socket))
      |> MapSet.new(& &1.uuid)

    Enum.filter(uuids, &MapSet.member?(allowed, &1))
  end

  defp in_pick_scope([], _scope), do: []
  defp in_pick_scope(files, nil), do: files

  defp in_pick_scope(files, scope) do
    subtree = TreeQuery.subtree_uuids(Storage.Folder, [scope])
    uuids = Enum.map(files, & &1.uuid)

    linked =
      PhoenixKit.Config.get_repo().all(
        from(fl in Storage.FolderLink,
          where: fl.file_uuid in ^uuids and fl.folder_uuid in ^subtree,
          select: fl.file_uuid
        )
      )

    linked = MapSet.new(linked)
    subtree = MapSet.new(subtree)

    Enum.filter(
      files,
      &(MapSet.member?(subtree, &1.folder_uuid) or MapSet.member?(linked, &1.uuid))
    )
  end

  # An upload made in the picker picks itself (see `buffer_pending_upload/3`)
  # — when a click could pick it. The store answers with the row it kept, and
  # that may not be what the upload claimed: the type is the bytes' (an
  # "image" that is not one), and a duplicate of an earlier upload is that
  # earlier row, in the trash or of another type.
  defp pick_upload(%{assigns: %{picker: true}} = socket, {:ok, %{file_uuid: uuid}}) do
    uuid = to_string(uuid)

    if pickable?(socket, uuid) do
      add_pick(socket, uuid)
    else
      Logger.warning(
        "MediaBrowser id=#{socket.assigns.id}: uploaded file #{uuid} not picked — " <>
          "not a file this picker lists"
      )

      socket
    end
  end

  defp pick_upload(socket, _result), do: socket

  # Check the whole boundary again: a live file may have moved to another
  # library or outside the scoped folder since it was picked.
  defp confirm_pick(socket) do
    uuids = pickable_uuids(socket, socket.assigns.picked)

    socket
    |> assign(:picked, uuids)
    |> report_once({:picked, uuids})
  end

  # Confirm or Cancel pressed again with nothing changed in between (a double
  # press, a slow host) reports nothing new, so the host hears it once.
  defp report_once(socket, message) do
    if socket.assigns[:pick_reported] == message do
      socket
    else
      socket
      |> assign(:pick_reported, message)
      |> notify_picker_host(message)
    end
  end

  defp notify_picker_host(socket, message) do
    case socket.assigns[:notify] do
      {module, id} -> send_update(module, [{:id, id} | picker_update(message)])
      _ -> send(self(), {__MODULE__, socket.assigns.id, message})
    end

    socket
  end

  defp picker_update({:picked, uuids}), do: [picked: uuids]
  defp picker_update(:pick_cancelled), do: [picked: :cancelled]
  defp picker_update({:picker_uploading, uploading?}), do: [picker_uploading: uploading?]

  # Confirm and Cancel wait while an upload is on its way: a transfer the
  # page is receiving, or a received file not yet stored (queued, being
  # stored, or stored and waiting for its batch).
  defp upload_in_progress?(socket) do
    a = socket.assigns

    match?(%{entries: [_ | _]}, a[:parent_uploads][a[:upload_name] || :media_files]) or
      a[:upload_processing] != nil or
      (a[:upload_process_queue] || []) != [] or
      (a[:pending_batch] || []) != []
  end

  defp picker_busy?(socket), do: socket.assigns.picker_uploading or upload_in_progress?(socket)

  # Tells the host when the picker starts and stops waiting for an upload.
  # The stop is reported a moment late, once it holds: between a transfer
  # ending and the page handing the file to this browser there is a render
  # with nothing in flight, and reporting it would let the host close the
  # picker on the upload it is about to receive.
  @picker_idle_ms 300

  defp sync_picker_uploading(%{assigns: %{picker: true}} = socket) do
    busy? = upload_in_progress?(socket)

    cond do
      busy? and not socket.assigns.picker_uploading ->
        socket
        |> assign(:picker_uploading, true)
        |> notify_picker_host({:picker_uploading, true})

      not busy? and socket.assigns.picker_uploading and
          socket.assigns[:picker_idle_check] != true ->
        Phoenix.LiveView.send_update_after(
          __MODULE__,
          [id: socket.assigns.id, action: :picker_idle_check],
          @picker_idle_ms
        )

        assign(socket, :picker_idle_check, true)

      true ->
        socket
    end
  end

  defp sync_picker_uploading(socket), do: socket

  defp settle_picker_idle(socket) do
    socket = assign(socket, :picker_idle_check, false)

    if socket.assigns.picker and socket.assigns.picker_uploading and
         not upload_in_progress?(socket) do
      socket
      |> assign(:picker_uploading, false)
      |> notify_picker_host({:picker_uploading, false})
    else
      socket
    end
  end

  # The upload drawer's job ends the moment files are accepted: transfers
  # are auto_upload, and their progress renders as the same inline rows the
  # drag-drop path uses — so a drawer left open past that point only spends
  # vertical space over the grid the uploads are about to land in. The
  # parent re-renders on every transfer tick and pushes fresh
  # parent_uploads here; the render where in-flight entries FIRST appear
  # closes the drawer. Transition-triggered, not state-triggered, so a
  # user who deliberately reopens the drawer mid-upload (to add more
  # files) is not fighting a panel that snaps shut on every tick.
  defp close_upload_on_start(socket) do
    name = socket.assigns.upload_name

    active =
      case socket.assigns[:parent_uploads] do
        %{^name => %{entries: [_ | _]}} -> true
        _ -> false
      end

    started = active and not socket.assigns.upload_in_flight
    socket = assign(socket, :upload_in_flight, active)

    if started and socket.assigns[:show_upload] do
      assign(socket, :show_upload, false)
    else
      socket
    end
  end

  defp inbox_problems(socket) do
    case {socket.assigns[:readonly], socket.assigns[:phoenix_kit_current_user]} do
      {readonly, %{uuid: user_uuid}} when readonly != true ->
        user_uuid
        |> UploadInbox.list()
        |> Enum.filter(&item_for_this_library?(&1, socket))
        |> Enum.map(fn item ->
          interrupted? = item.status == "interrupted"

          %{
            key: "inbox-" <> item.id,
            kind: if(interrupted?, do: :interrupted, else: :server),
            client_name: item.client_name,
            client_size: item.client_size,
            client_type: item.client_type,
            reason:
              if(interrupted?,
                do:
                  gettext(
                    "Saving was interrupted before it finished — the page was closed or refreshed."
                  ),
                else: item.error || gettext("The server could not save it.")
              ),
            retry: true,
            inbox: {user_uuid, item.id}
          }
        end)

      _ ->
        []
    end
  end

  # An upload belongs to the library it was dropped on: a panel lists only
  # those (and the ones not yet claimed), so a Retry cannot carry a private
  # library's file into another.
  defp item_for_this_library?(%{dest: nil}, _socket), do: true

  defp item_for_this_library?(%{dest: %{library_uuid: library}}, socket),
    do: library == library_key(socket)

  defp library_key(socket) do
    case socket.assigns[:library_uuid] do
      nil -> nil
      uuid -> to_string(uuid)
    end
  end

  # Where an upload dropped here belongs: this library, and the folder that is
  # open (or the browser's scope).
  defp upload_destination(socket) do
    folder = current_folder_uuid(socket) || scope_folder_id(socket)

    %{
      library_uuid: library_key(socket),
      folder_uuid: folder && to_string(folder)
    }
  end

  # The browser that takes an inbox upload writes down where it belongs and that
  # it is working on it (see `UploadInbox.claim/4`). A readonly browser takes
  # nothing.
  defp claim_inbox_item(socket, path) do
    with false <- socket.assigns.readonly == true,
         {user_uuid, id} <- UploadInbox.locate(path) do
      UploadInbox.claim(user_uuid, id, upload_destination(socket))
    end

    socket
  end

  # The folder a stored upload goes into: the one recorded when it was dropped,
  # or the open folder for an upload with no record (no user, no inbox).
  defp placement_folder(socket, path) do
    with {user_uuid, id} <- UploadInbox.locate(path),
         %{dest: %{folder_uuid: folder}} <- UploadInbox.get(user_uuid, id) do
      existing_folder_uuid(folder)
    else
      _ -> current_folder_uuid(socket)
    end
  end

  defp existing_folder_uuid(nil), do: nil

  defp existing_folder_uuid(uuid) do
    case Storage.get_folder(uuid) do
      %{uuid: found} -> found
      _ -> nil
    end
  end

  defp receive_pending_upload(socket, {path, _entry} = pending) do
    socket
    |> claim_inbox_item(path)
    |> enqueue_pending_upload(pending)
  end

  defp refresh_inbox_problems(socket) do
    socket = assign(socket, :upload_inbox_problems, inbox_problems(socket))
    schedule_inbox_poll(socket)
  end

  # While an upload is in somebody's hands — another page, a tab that has not
  # finished — look again, so what a refresh or a crash left behind shows up
  # without the page being reloaded.
  @inbox_poll_ms 10_000
  defp schedule_inbox_poll(socket) do
    with %{uuid: user_uuid} <- socket.assigns[:phoenix_kit_current_user],
         false <- socket.assigns[:inbox_poll_scheduled] == true,
         false <- socket.assigns[:readonly] == true,
         true <- UploadInbox.waiting?(user_uuid) do
      Phoenix.LiveView.send_update_after(
        __MODULE__,
        [id: socket.assigns.id, action: :refresh_inbox_problems],
        @inbox_poll_ms
      )

      assign(socket, :inbox_poll_scheduled, true)
    else
      _ -> socket
    end
  end

  defp add_upload_problem(socket, attrs) do
    problem =
      %{retry: Map.has_key?(attrs, :path)}
      |> Map.merge(attrs)
      |> Map.put(:key, "s-" <> Integer.to_string(System.unique_integer([:positive])))

    assign(socket, :upload_problems_session, [problem | socket.assigns.upload_problems_session])
  end

  defp retry_upload_problems(socket, pick) do
    {retry, keep} = Enum.split_with(upload_problems(socket.assigns), &(pick.(&1) and &1.retry))
    {browser, kept} = Enum.split_with(retry, &(&1.kind == :browser))

    socket =
      Enum.reduce(kept, socket, fn problem, acc ->
        case retry_bytes(acc, problem) do
          {:ok, path} -> enqueue_pending_upload(acc, {path, retry_entry(problem)})
          :error -> acc
        end
      end)

    socket =
      if browser == [] do
        socket
      else
        push_event(
          socket,
          "phoenix_kit:upload-resume",
          Map.merge(resume_target(socket), %{keys: Enum.map(browser, & &1.client_key)})
        )
      end

    set_upload_problems(socket, keep)
  end

  # Kept bytes for a retry: the inbox item (refreshed so it no longer reads
  # as interrupted while it is back in the queue), or the held temp file.
  # Taking an inbox item is `claim/4`: it keeps the destination the upload was
  # dropped on, and refuses one another tab has taken since this panel was drawn.
  defp retry_bytes(socket, %{inbox: {user_uuid, id}}) do
    case UploadInbox.claim(user_uuid, id, upload_destination(socket)) do
      {:ok, _item} -> UploadInbox.path(user_uuid, id)
      _ -> :error
    end
  end

  defp retry_bytes(_socket, %{path: path}) do
    if File.exists?(path), do: {:ok, path}, else: :error
  end

  defp retry_bytes(_socket, _problem), do: :error

  # The drain and the store read an upload entry's client fields; a retry
  # has those from the problem it came from.
  defp retry_entry(problem) do
    %{
      uuid: Ecto.UUID.generate(),
      client_name: problem.client_name,
      client_type: problem[:client_type],
      client_size: problem.client_size || 0,
      client_last_modified: nil
    }
  end

  defp discard_upload_problems(socket, pick) do
    {gone, keep} = Enum.split_with(upload_problems(socket.assigns), pick)

    Enum.each(gone, fn
      %{inbox: {user_uuid, id}} -> UploadInbox.discard(user_uuid, id)
      %{path: path} -> File.rm(path)
      _ -> :ok
    end)

    socket =
      case for(%{kind: :browser, client_key: key} <- gone, do: key) do
        [] ->
          socket

        keys ->
          push_event(
            socket,
            "phoenix_kit:upload-discard",
            Map.merge(resume_target(socket), %{keys: keys})
          )
      end

    set_upload_problems(socket, keep)
  end

  defp set_upload_problems(socket, problems) do
    {inbox, session} = Enum.split_with(problems, &Map.has_key?(&1, :inbox))

    socket
    |> assign(:upload_inbox_problems, inbox)
    |> assign(:upload_problems_session, Enum.reverse(session))
  end

  # Uploads land here one message at a time from handle_parent_info, but the
  # transfer row is already gone — the parent consumed the entry the moment the
  # transfer finished. Processing synchronously inside update/2 would therefore
  # leave nothing on screen while the server stores the file. Queue it instead
  # and drain via send_update_after, so a render showing the "Processing on
  # server…" rows always lands before (and between) the actual stores.
  defp enqueue_pending_upload(socket, {path, entry}) do
    queue = (socket.assigns[:upload_process_queue] || []) ++ [{path, entry}]

    socket
    |> assign(:upload_process_queue, queue)
    |> schedule_upload_drain()
  end

  defp schedule_upload_drain(socket) do
    if socket.assigns[:upload_drain_scheduled] do
      socket
    else
      Phoenix.LiveView.send_update_after(
        __MODULE__,
        [id: socket.assigns.id, action: :drain_upload_queue],
        0
      )

      assign(socket, :upload_drain_scheduled, true)
    end
  end

  # Two-phase on purpose: an assign made in the same update/2 that does the
  # work only renders AFTER the work, so the first cycle merely surfaces the
  # file as in-flight (`:upload_processing`) and re-schedules; the second
  # cycle finds it staged and runs the store while its spinner row is already
  # painted. One file per cycle keeps multi-file drops progressive.
  defp drain_upload_queue(socket) do
    socket = assign(socket, :upload_drain_scheduled, false)

    case {socket.assigns[:upload_processing], socket.assigns[:upload_process_queue] || []} do
      {nil, []} ->
        socket

      {nil, [next | rest]} ->
        socket
        |> assign(:upload_processing, next)
        |> assign(:upload_process_queue, rest)
        |> schedule_upload_drain()

      {{path, entry}, _queued} ->
        socket
        |> assign(:upload_processing, nil)
        |> process_pending_upload({path, entry})
        |> then(fn s ->
          if (s.assigns[:upload_process_queue] || []) == [] do
            s
          else
            schedule_upload_drain(s)
          end
        end)
    end
  end

  # Processes one entry and buffers the result. A single reload + flash is
  # committed from commit_upload_batch/1 once the batch debounce window closes,
  # so dropping N files produces one page reload instead of N.
  defp process_pending_upload(socket, {path, entry}) do
    cond do
      # `pending_upload` is broadcast to every registered MediaBrowser
      # instance on the page (see handle_parent_info/2), not just the one
      # whose upload input was used — so a readonly browser co-located with
      # a writable one (or any host with its own live_file_input elsewhere)
      # would otherwise get files written into its scope regardless of
      # `readonly`. The refusal belongs here, same as off_type_upload? below.
      socket.assigns.readonly ->
        # Every browser on the page has its own copy (own inbox item), so
        # this one's is this browser's to let go of.
        drop_upload_bytes(path, UploadInbox.locate(path))
        log_readonly_blocked(socket, "process_pending_upload")

      off_type_upload?(socket, entry) ->
        # A locked browser filters its listing, so an off-type file would be
        # stored and then be invisible in the very browser that accepted it —
        # "I uploaded it and it vanished". The parent's `accept: :any` is shared
        # by every browser on the page and can't express the lock, so the refusal
        # belongs here, where the component's own assigns are in scope.
        # A component's put_flash never reaches the page, so this refusal used
        # to be silent too; it is a named row in the problems panel now.
        reason = off_type_upload_error(socket.assigns.only_file_type)

        case UploadInbox.locate(path) do
          # A kept upload (a Retry clicked in a browser that only takes another
          # kind of file) is not this browser's to destroy: it stays, marked
          # with why, for the browser that can take it — or for Discard.
          {user_uuid, id} ->
            UploadInbox.fail(user_uuid, id, reason)
            assign(socket, :upload_inbox_problems, inbox_problems(socket))

          nil ->
            File.rm(path)

            add_upload_problem(socket, %{
              kind: :rejected,
              client_name: entry.client_name,
              client_size: entry.client_size,
              reason: reason,
              retry: false
            })
        end

      true ->
        buffer_pending_upload(socket, path, entry)
    end
  end

  defp off_type_upload?(%{assigns: %{only_file_type: type}}, entry) when is_binary(type) do
    Storage.determine_file_type(entry.client_type, entry.client_name) != type
  end

  defp off_type_upload?(_socket, _entry), do: false

  defp off_type_upload_error("image"), do: gettext("Only image files can be added here.")
  defp off_type_upload_error("video"), do: gettext("Only video files can be added here.")
  defp off_type_upload_error("audio"), do: gettext("Only audio files can be added here.")
  defp off_type_upload_error(_), do: gettext("Only the allowed file types can be added here.")

  defp buffer_pending_upload(socket, path, entry) do
    result = safe_process_single_upload(socket, path, entry)
    socket = settle_upload(socket, path, entry, result)

    batch = [result | socket.assigns[:pending_batch] || []]

    new_uuids =
      case result do
        {:ok, %{file_uuid: uuid}} -> [uuid | socket.assigns.last_uploaded_file_uuids]
        _ -> socket.assigns.last_uploaded_file_uuids
      end

    socket =
      socket
      |> assign(:pending_batch, batch)
      |> assign(:last_uploaded_file_uuids, new_uuids)
      |> pick_upload(result)

    if socket.assigns[:batch_scheduled] do
      socket
    else
      Phoenix.LiveView.send_update_after(
        __MODULE__,
        [id: socket.assigns.id, action: :commit_upload_batch],
        250
      )

      assign(socket, :batch_scheduled, true)
    end
  end

  # Hand the open viewer the file as it is NOW, when it is the file that
  # changed. Re-read rather than reusing the grid's copy: the grid may not
  # be rendering this row at all (a viewer opened from a search, a deep
  # link), and `fresh_file/3` returns nothing in that case.
  defp poke_viewer_burn(socket, file_uuid) do
    with %{file_uuid: ^file_uuid} = viewer <- socket.assigns[:viewer_file],
         %Storage.File{} = file <- Storage.get_file(file_uuid),
         fresh when is_map(fresh) <- enrich_files([file]) |> List.first() do
      send_update(PhoenixKitWeb.Components.MediaCanvasViewer,
        id: viewer_component_id(viewer, socket.assigns),
        burn_refreshed: fresh
      )
    else
      _ -> :ok
    end
  end

  # A background job finished for `file_uuid` — fresh dimensions, variants,
  # status, or a rebaked annotated thumbnail just landed. If the file is on
  # the current page or open in the modal viewer, swap in a freshly-enriched
  # map so thumbnails and the correctly-proportioned canvas appear without a
  # manual reload. (The viewer's canvas-viewer LC id encodes dims + variant
  # count, so the swap remounts it with the real canvas instead of the
  # 1000x1000 placeholder.) `viewer: false` limits the swap to the grid row —
  # used for thumbnail-only updates, where remounting an open viewer would
  # kick the annotator out mid-edit. Files not in view are skipped — their
  # next load reads fresh rows anyway.
  defp refresh_processed_file(socket, file_uuid, opts \\ []) do
    viewer = socket.assigns[:viewer_file]

    viewing? =
      Keyword.get(opts, :viewer, true) and is_map(viewer) and viewer.file_uuid == file_uuid

    case fresh_file(socket, file_uuid, viewing?) do
      nil -> socket
      fresh -> swap_file(socket, file_uuid, fresh, viewing?)
    end
  end

  # Re-enrich from the DB, but only when the file is actually on screen —
  # anything else re-reads fresh rows on its next load anyway.
  defp fresh_file(socket, file_uuid, viewing?) do
    if viewing? or rendered?(socket, file_uuid) do
      case Storage.get_file(file_uuid) do
        %Storage.File{} = file -> enrich_files([file]) |> List.first()
        _ -> nil
      end
    end
  end

  defp swap_file(socket, file_uuid, fresh, viewing?) do
    swap = fn f -> if f.file_uuid == file_uuid, do: fresh, else: f end

    socket
    |> assign(:uploaded_files, Enum.map(socket.assigns.uploaded_files, swap))
    |> assign(
      :stack_files,
      Map.new(socket.assigns[:stack_files] || %{}, fn {uuid, files} ->
        {uuid, Enum.map(files, swap)}
      end)
    )
    |> assign(
      :stack_previews,
      Map.new(socket.assigns[:stack_previews] || %{}, fn {uuid, entry} ->
        {uuid, Map.update(entry, :previews, [], &Enum.map(&1, swap))}
      end)
    )
    |> assign(:viewer_siblings, Enum.map(socket.assigns[:viewer_siblings] || [], swap))
    |> then(&if(viewing?, do: assign(&1, :viewer_file, fresh), else: &1))
  end

  # Drops `file_uuids` from every rendered list (see `remove_files_from_lists/2`)
  # unless `still_visible?` — used for the trashed/restored events, whose
  # effect on this browser depends on whether it is currently showing the
  # Trash view or the active view.
  defp drop_files_unless(socket, file_uuids, still_visible?) do
    if still_visible?, do: socket, else: remove_files_from_lists(socket, file_uuids)
  end

  # Removes files that no longer belong on screen (trashed while viewing
  # active files, restored while viewing trash, or permanently deleted) from
  # every list the browser paints from — same set `swap_file/4` rewrites,
  # but rejecting the entries instead of replacing them in place — and from
  # the bulk selection, whose counter and "N item(s) deleted" would otherwise
  # still count a file no longer shown. Closes the viewer if it was open on
  # one of them, since there is nothing left to show.
  defp remove_files_from_lists(socket, file_uuids) do
    gone = MapSet.new(file_uuids)
    reject = fn list -> Enum.reject(list, &MapSet.member?(gone, &1.file_uuid)) end

    socket
    |> assign(:uploaded_files, reject.(socket.assigns.uploaded_files))
    |> assign(
      :stack_files,
      Map.new(socket.assigns[:stack_files] || %{}, fn {uuid, files} ->
        {uuid, reject.(files)}
      end)
    )
    |> assign(
      :stack_previews,
      Map.new(socket.assigns[:stack_previews] || %{}, fn {uuid, entry} ->
        {uuid, Map.update(entry, :previews, [], reject)}
      end)
    )
    |> assign(:viewer_siblings, reject.(socket.assigns[:viewer_siblings] || []))
    |> assign(
      :selected_files,
      MapSet.difference(socket.assigns[:selected_files] || MapSet.new(), gone)
    )
    |> assign(:picked, Enum.reject(socket.assigns[:picked] || [], &MapSet.member?(gone, &1)))
    |> then(fn socket ->
      viewer = socket.assigns[:viewer_file]

      if is_map(viewer) and MapSet.member?(gone, viewer.file_uuid),
        do: open_viewer(socket, nil),
        else: socket
    end)
  end

  # Every list the browser paints file thumbnails from: the current page's
  # (`uploaded_files`), each expanded stack's (`stack_files`), and each
  # collapsed pile's fanned previews (`stack_previews`). A refresh has to
  # consider — and rewrite — all three, or an update lands on some
  # thumbnails and not others: the pile is built once per stacks render, so
  # skipping it left it showing a stale orientation forever while the grid
  # and viewer moved on.
  #
  # Distinct from `locate_file/2`, which is about *clicking*: a pile preview
  # isn't clickable and its 4-file list must never become the viewer's
  # prev/next siblings.
  defp rendered?(socket, file_uuid) do
    lists =
      [socket.assigns.uploaded_files] ++
        Map.values(socket.assigns[:stack_files] || %{}) ++
        Enum.map(Map.values(socket.assigns[:stack_previews] || %{}), &Map.get(&1, :previews, []))

    Enum.any?(lists, fn list -> Enum.any?(list, fn f -> f.file_uuid == file_uuid end) end)
  end

  defp commit_upload_batch(socket) do
    if socket.assigns[:upload_processing] != nil or
         (socket.assigns[:upload_process_queue] || []) != [] do
      # Files are still draining — committing now would flash a partial count
      # and reload mid-batch. Check again after the current file finishes.
      Phoenix.LiveView.send_update_after(
        __MODULE__,
        [id: socket.assigns.id, action: :commit_upload_batch],
        250
      )

      socket
    else
      batch = socket.assigns[:pending_batch] || []
      {flash_type, flash_msg} = build_upload_flash_message(Enum.reverse(batch))

      socket
      |> assign(:pending_batch, [])
      |> assign(:batch_scheduled, false)
      |> assign(:upload_inbox_problems, inbox_problems(socket))
      |> reload_current_page()
      |> parent_flash(flash_type, flash_msg)
    end
  end

  # See the `import` at the top: the browser's flash goes to the host too.
  defp put_flash(socket, kind, message) do
    socket
    |> Phoenix.LiveView.put_flash(kind, message)
    |> parent_flash(kind, message)
  end

  # A component's `put_flash` never reaches the page layout. The parent
  # LiveView puts this one (`handle_parent_info/2`).
  defp parent_flash(socket, kind, message) do
    send(self(), {__MODULE__, socket.assigns.id, {:flash, kind, message}})
    socket
  end

  # Sets the open folder's cover (background) or logo (icon) — per
  # `@image_picker_target` — to a file chosen in the media picker (an existing
  # folder image or one just uploaded into it via the picker).
  defp set_image_from_selection(socket, uuids) do
    target = socket.assigns[:image_picker_target] || "cover"
    attr = if target == "logo", do: :logo_file_uuid, else: :cover_file_uuid
    folder_uuid = socket.assigns[:editing_folder_header]
    file_uuid = uuids |> List.wrap() |> List.first()
    socket = assign(socket, :selecting_cover, false)
    folder = is_binary(folder_uuid) && loaded_folder(socket, folder_uuid)

    cond do
      not is_binary(file_uuid) or !folder ->
        socket

      # `media_selected` arrives by `update/2`, past the `handle_event` gates:
      # the file gets the viewer's here. Not `fetch_viewable_file/2` — the
      # picker also lists files linked into the folder from elsewhere, and a
      # cover is an image whatever type the browser is locked to. "Inside the
      # folder" is held by the modal (`selectable?`/`scope_files_by_folder`).
      not pickable_file?(socket, file_uuid) ->
        Logger.warning(
          "MediaBrowser id=#{socket.assigns.id}: cover/logo pick refused — " <>
            "#{file_uuid} is not a file this viewer may see in this library"
        )

        parent_flash(socket, :error, gettext("Failed to set the image"))

      true ->
        apply_image(socket, folder, attr, file_uuid)
    end
  end

  defp pickable_file?(socket, file_uuid) do
    with true <- UUIDUtils.valid?(file_uuid),
         %Storage.File{system_managed: false} = file <- Storage.get_file(file_uuid),
         true <- file.status != "trashed",
         true <- in_browser_library?(socket, file) do
      Storage.viewer_can_see_file?(socket.assigns[:viewer_uuid], file)
    else
      _ -> false
    end
  end

  defp apply_image(socket, folder, attr, file_uuid) do
    case Storage.update_folder(folder, %{attr => file_uuid}, scope_folder_id(socket)) do
      {:ok, updated} ->
        socket
        |> maybe_refresh_current_folder(updated, folder.uuid)
        |> reload_current_page()

      error ->
        Logger.warning(
          "MediaBrowser id=#{socket.assigns.id}: cover/logo not set for " <>
            "#{file_uuid}: #{inspect(error)}"
        )

        parent_flash(socket, :error, gettext("Failed to set the image"))
    end
  end

  # Keeps the in-folder header in sync after a header change — refreshes the
  # current folder struct + cover/logo URLs when the edited folder is open.
  defp maybe_refresh_current_folder(socket, updated, folder_uuid) do
    if socket.assigns[:current_folder] &&
         to_string(socket.assigns.current_folder.uuid) == to_string(folder_uuid) do
      # Editor-time path (infrequent): load both URLs unconditionally so the
      # Edit-header previews stay correct even with the show toggles off.
      cover = folder_image_data(updated.cover_file_uuid)
      logo = folder_image_data(updated.logo_file_uuid)

      socket
      |> assign(:current_folder, updated)
      |> assign(:folder_cover_url, cover.url)
      |> assign(:folder_cover_rotation, cover.rotation)
      |> assign(:folder_logo_url, logo.url)
      |> assign(:folder_logo_rotation, logo.rotation)
    else
      socket
    end
  end

  # Update a folder-header field (size / toggles / cover-or-logo clear) and
  # refresh the open folder's header. No listing reload needed — header changes
  # don't affect the file grid (the cover/logo stay as folder assets).
  defp update_header_field(socket, folder_uuid, attrs) do
    folder = loaded_folder(socket, folder_uuid)
    scope = scope_folder_id(socket)

    case folder && Storage.update_folder(folder, attrs, scope) do
      {:ok, updated} ->
        {:noreply, maybe_refresh_current_folder(socket, updated, folder_uuid)}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update the header"))}
    end
  end

  defp header_option_field("title"), do: :header_show_title
  defp header_option_field("icon"), do: :header_show_icon
  defp header_option_field("creator"), do: :header_show_creator
  defp header_option_field("date"), do: :header_show_date
  defp header_option_field("file_count"), do: :header_show_file_count
  defp header_option_field("description"), do: :header_show_description
  defp header_option_field("background"), do: :header_show_background
  defp header_option_field(_), do: nil

  defp apply_nav_params(socket, params) do
    {socket, changed?} = apply_view_options(socket, params)

    # Opening / stepping / closing the modal viewer patches only `file` into
    # the URL; the listing the params describe is the one already on screen.
    # Skip the folder/search/count queries in that case — the full reload
    # below is for landing on a URL whose listing this socket has not
    # loaded (first mount, refresh, back/forward across folders).
    if not changed? and nav_matches_current?(socket, params) do
      sync_viewer_from_params(socket, params)
    else
      apply_nav_listing(socket, params) |> sync_viewer_from_params(params)
    end
  end

  # The toolbar's type, sort and shape as the URL names them. Authoritative only
  # when the host SENDS them (the `file` rule below): a hand-wired host that
  # predates them keeps the browser's own. A value not on the whitelist is the
  # default, and a browser locked to one type ignores `type`.
  defp apply_view_options(socket, params) do
    [
      {:file_type_filter, :type, @valid_file_types, "all"},
      {:sort_by, :sort, @valid_sorts, "newest"},
      {:shape_filter, :shape, @valid_shapes, "all"}
    ]
    |> Enum.reduce({socket, false}, fn {assign_key, nav_key, valid, default}, {sock, changed?} ->
      cond do
        not Map.has_key?(params, nav_key) ->
          {sock, changed?}

        assign_key == :file_type_filter and sock.assigns[:only_file_type] ->
          {sock, changed?}

        true ->
          value = if params[nav_key] in valid, do: params[nav_key], else: default

          if sock.assigns[assign_key] == value,
            do: {sock, changed?},
            else: {assign(sock, assign_key, value), true}
      end
    end)
  end

  defp nav_matches_current?(socket, params) do
    a = socket.assigns

    {current_folder_uuid(socket), a.search_query, a.current_page, a.filter_orphaned, a.file_view} ==
      {params[:folder], params[:q] || "", params[:page] || 1, params[:filter_orphaned] || false,
       params[:view]}
  end

  # The `file` URL param is the modal viewer's state: a refresh lands back
  # in the viewer on that file instead of at root with the modal gone. The
  # param is authoritative in both directions — `file: nil` closes (that is
  # what makes the browser's Back button close the viewer it opened).
  #
  # Authoritative only when the host SENDS it. A host that wired controlled
  # mode by hand before `file` existed hands back nav params with no such key;
  # reading that as "close" shut the viewer on the echo of the very click that
  # opened it. No key means the host does not track the viewer, so the viewer
  # stays local.
  defp sync_viewer_from_params(socket, params) do
    if Map.has_key?(params, :file) do
      {socket, echo} = pop_viewer_echo(socket, params[:file])
      if echo == :superseded, do: socket, else: apply_viewer_param(socket, params[:file])
    else
      assign(socket, :viewer_nav_echoes, [])
    end
  end

  # Every viewer change this component emits comes back as a nav-params echo.
  # Held ArrowRight emits B then C before B's echo returns; applying that echo
  # as a command dragged the viewer back to B (a full remount, and a step
  # taken in between started from the wrong file) until C's echo fixed it.
  # An echo of our own emit is skipped while a NEWER emit is still in flight.
  # The newest one is applied like any outside value — a no-op when nothing
  # else happened, and the correction when something did. A value we did not
  # emit (Back/Forward, a hand-edited URL) drops the queue and applies.
  defp pop_viewer_echo(socket, uuid) do
    case socket.assigns[:viewer_nav_echoes] || [] do
      [^uuid, _newer | _] = [_ | rest] -> {assign(socket, :viewer_nav_echoes, rest), :superseded}
      [^uuid] -> {assign(socket, :viewer_nav_echoes, []), :current}
      _ -> {assign(socket, :viewer_nav_echoes, []), :external}
    end
  end

  defp apply_viewer_param(socket, uuid) do
    current = socket.assigns[:viewer_file]

    cond do
      is_nil(uuid) ->
        if current, do: open_viewer(socket, nil), else: socket

      is_map(current) and current.file_uuid == uuid ->
        socket

      true ->
        case locate_file(socket, uuid) do
          {file, siblings} ->
            open_viewer(socket, file, siblings)

          nil ->
            # Not in the loaded listing (another page, a collapsed stack, a
            # hand-edited link): fetch it directly. Siblings collapse to the
            # file itself, so prev/next bound at it rather than stepping a
            # list the file is not in.
            case fetch_viewable_file(socket, uuid) do
              %Storage.File{} = file ->
                enriched = enrich_files([file]) |> List.first()
                open_viewer(socket, enriched, [enriched])

              nil ->
                socket
            end
        end
    end
  end

  # The URL is user-editable, so a `file` that missed the loaded listing
  # gets the same gates the listing itself applies: a well-formed uuid (a
  # malformed one raises in the cast and crash-loops the mount), the
  # browser's scope folder, never a system-managed tile chunk, and the
  # `only_file_type` lock. Anything else leaves the viewer closed.
  defp fetch_viewable_file(socket, uuid) do
    with true <- UUIDUtils.valid?(uuid),
         %Storage.File{system_managed: false} = file <- Storage.get_file(uuid),
         true <- Storage.within_scope?(file.folder_uuid, scope_folder_id(socket)),
         true <- in_browser_library?(socket, file),
         true <- Storage.viewer_can_see_file?(socket.assigns[:viewer_uuid], file),
         true <- socket.assigns[:only_file_type] in [nil, file.file_type] do
      file
    else
      _ -> nil
    end
  end

  # A browser that shows one library opens only that library's files: a `file`
  # param naming a file of another library (a user's private one included) is
  # not opened by a hand-edited link any more than it is listed.
  defp in_browser_library?(socket, file) do
    case socket.assigns[:library_uuid] do
      nil -> Libraries.user_or_hidden_among([file.library_uuid]) == []
      library_uuid -> to_string(file.library_uuid) == to_string(library_uuid)
    end
  end

  defp apply_nav_listing(socket, params) do
    q = params[:q] || ""
    page = params[:page] || 1
    filter_orphaned = params[:filter_orphaned] || false
    file_view = params[:view]
    scope = scope_folder_id(socket)
    per_page = socket.assigns.per_page

    {current_folder, breadcrumbs, folders, scoped_fallback?} =
      resolve_folder(params[:folder], scope, lib_opts(socket))

    actual_uuid = current_folder && current_folder.uuid

    {files, total_count} =
      load_nav_files(
        scope,
        page,
        per_page,
        q,
        actual_uuid,
        filter_orphaned,
        file_view,
        list_extra(socket)
      )

    orphaned_count =
      if filter_orphaned,
        do: total_count,
        else: Storage.count_orphaned_files(scope, lib_opts(socket))

    socket
    |> assign(:current_folder, current_folder)
    # Seed header media for the folder whose hero shows here. The scope folder
    # qualifies only at the effective root (see `header_folder_target/6`) — not
    # under all-files / orphaned / search, where its metadata would disagree
    # with the `<h2>` title. `filter_trash` is always false on the nav path
    # (reset at the end of `apply_nav_params`), so the trash arm can't trip here.
    |> assign_folder_header_media(
      Helpers.header_folder_target(
        current_folder,
        file_view,
        filter_orphaned,
        q,
        false,
        socket.assigns[:scope_folder]
      )
    )
    |> assign(:breadcrumbs, breadcrumbs)
    # The "all" view and the orphaned view are flat file listings — no folder
    # cards. A name search keeps the file results but ALSO surfaces folders
    # whose name matches (same scope as the file search). (The sidebar folder
    # tree is unaffected; only the grid's folder cards here.)
    |> assign(
      :folders,
      cond do
        file_view == "all" or filter_orphaned -> []
        q != "" -> Storage.search_folders(q, actual_uuid, scope, lib_opts(socket))
        true -> folders
      end
    )
    |> assign(:search_query, q)
    |> assign(:current_page, page)
    |> assign(:filter_orphaned, filter_orphaned)
    |> assign(:filter_trash, false)
    |> assign(:file_view, file_view)
    |> assign(:orphaned_count, orphaned_count)
    # Badge counts the trash of the folder being navigated to (its subtree),
    # matching the scope the Trash view will use — read from the local
    # `current_folder`, since the pre-pipe socket still holds the old one.
    |> assign(
      :trash_count,
      full_trash_count(folder_or_scope(current_folder, scope), lib_opts(socket))
    )
    |> assign(:uploaded_files, files)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, Pagination.total_pages(total_count, per_page))
    |> then(
      &if(scoped_fallback?,
        do: put_flash(&1, :info, gettext("Folder not accessible — showing root")),
        else: &1
      )
    )
    |> auto_expand_breadcrumbs(breadcrumbs)
    |> reset_stacks()
  end

  defp resolve_folder(folder_uuid, scope, lib) do
    if folder_uuid in [nil, ""] do
      {nil, [], Storage.list_folders(nil, scope, lib), false}
    else
      folder = Storage.get_folder(folder_uuid)

      if folder && Storage.within_scope?(folder.uuid, scope) && in_shown_library?(folder, lib) do
        bc = Storage.folder_breadcrumbs(folder.uuid, scope)
        flds = Storage.list_folders(folder.uuid, scope, lib)
        {folder, bc, flds, false}
      else
        # Folder not found, outside scope, or in another library than the one
        # shown — fall back to scope root.
        {nil, [], Storage.list_folders(nil, scope, lib), not is_nil(folder_uuid)}
      end
    end
  end

  # A folder (or file) of another library is not opened in, or shown by,
  # this one. With no library named, what a site listing leaves out (user and
  # private libraries, `Libraries.exclude_user_libraries/1`) is not shown.
  # A restricted viewer (`:viewer_uuid` among the options) also opens only a
  # folder they may see (`Storage.viewer_folder_uuids/2`).
  defp in_shown_library?(folder_or_file, opts) do
    in_library? =
      case opts[:library_uuid] do
        nil -> Libraries.user_or_hidden_among([folder_or_file.library_uuid]) == []
        library_uuid -> to_string(folder_or_file.library_uuid) == to_string(library_uuid)
      end

    in_library? and viewer_sees_folder_or_file?(folder_or_file, opts)
  end

  defp viewer_sees_folder_or_file?(item, opts) do
    case opts[:viewer_uuid] do
      nil ->
        true

      viewer_uuid ->
        case item do
          %Storage.Folder{} ->
            Storage.viewer_can_see_folder?(viewer_uuid, item.uuid, opts[:library_uuid])

          _file ->
            Storage.viewer_can_see_file?(viewer_uuid, item)
        end
    end
  end

  defp load_nav_files(scope, page, per_page, q, actual_uuid, filter_orphaned, file_view, extra) do
    cond do
      filter_orphaned ->
        load_orphaned_files(page, per_page, Keyword.take(extra, [:library_uuid, :viewer_uuid]))

      file_view == "all" ->
        load_all_view_files(scope, page, per_page, q, extra)

      true ->
        load_scoped_files(scope, page, per_page, actual_uuid, q, extra)
    end
  end

  # Sort + file-type filter opts from the toolbar, for the listing query.
  # The setting is free-text in the DB — a non-numeric value must degrade to
  # the default, not crash every media surface at mount (String.to_integer).
  defp max_upload_size_mb do
    case Integer.parse(Settings.get_setting_cached("storage_max_upload_size_mb", "500")) do
      {n, _} when n > 0 -> n
      _ -> 500
    end
  end

  defp list_extra(socket) do
    [
      sort: socket.assigns[:sort_by] || "newest",
      file_type: socket.assigns[:file_type_filter] || "all",
      shape: socket.assigns[:shape_filter] || "all"
    ] ++ lib_opts(socket)
  end

  # Another library than the one on screen: nothing listed belongs to it —
  # start over at its root. Not on the first mount, which initialises anyway.
  defp maybe_switch_library(socket, shown_library) do
    if Map.has_key?(socket.assigns, :uploaded_files) and
         socket.assigns.library_uuid != shown_library,
       do: socket |> init_socket() |> apply_nav_listing(%{}),
       else: socket
  end

  # The storage library this browser shows, as listing options. nil (the
  # default, and every host that names none) is every library that is not
  # private — the site's libraries, which is what the listing was before
  # user libraries. A user library is passed by uuid.
  defp lib_opts(socket) do
    library =
      case socket.assigns[:library_uuid] do
        nil -> []
        library_uuid -> [library_uuid: library_uuid]
      end

    # A restricted viewer's filter rides with the library on every read.
    case socket.assigns[:viewer_uuid] do
      nil -> library
      viewer_uuid -> [{:viewer_uuid, viewer_uuid} | library]
    end
  end

  defp init_socket(socket) do
    scope = scope_folder_id(socket)
    scope_folder = if scope, do: Storage.get_folder(scope)
    scope_invalid = not is_nil(scope) and is_nil(scope_folder)

    has_buckets = Storage.buckets_available?()

    scope_name = if scope_folder, do: scope_folder.name, else: "Root"

    socket
    |> maybe_allow_upload(has_buckets)
    |> assign(:has_buckets, has_buckets)
    |> assign(:scope_invalid, scope_invalid)
    |> assign(:scope_folder_name, scope_name)
    # The scope folder itself (when scoped). It's the effective root of the
    # browser, so its header customizations (description/logo/background/
    # creation info) render at the scoped root even though `current_folder`
    # stays nil there. nil when unscoped.
    |> assign(:scope_folder, scope_folder)
    |> assign(:show_upload, false)
    |> assign(:show_search, false)
    |> assign(:last_uploaded_file_uuids, [])
    |> assign(:pending_batch, [])
    |> assign(:batch_scheduled, false)
    |> assign(:upload_process_queue, [])
    |> assign(:upload_processing, nil)
    # Session-only problems (rejected before transfer, held temp files, cut
    # transfers the browser reported); the inbox's are read from disk.
    |> assign_new(:upload_problems_session, fn -> [] end)
    |> assign(:upload_inbox_problems, inbox_problems(socket))
    |> assign(:inbox_poll_scheduled, false)
    |> schedule_inbox_poll()
    |> assign(:upload_drain_scheduled, false)
    |> assign(:filter_orphaned, false)
    |> assign(:filter_trash, false)
    |> assign(:trash_count, full_trash_count(scope_folder_id(socket), lib_opts(socket)))
    |> assign(:file_view, nil)
    |> assign(
      :orphaned_count,
      if(scope_invalid, do: 0, else: Storage.count_orphaned_files(scope, lib_opts(socket)))
    )
    |> assign(:current_folder, nil)
    # Seed the header media from the scope folder (effective root) so the
    # scoped-root header shows its customizations even when no initial_params
    # are passed (apply_nav_params doesn't run on mount in that case).
    |> assign_folder_header_media(scope_folder)
    # The header-image media picker (MediaSelectorModal): open flag + which
    # image it sets ("cover" background or "logo" icon).
    |> assign(:selecting_cover, false)
    |> assign(:image_picker_target, "cover")
    |> assign(:breadcrumbs, [])
    |> assign(
      :folders,
      if(scope_invalid, do: [], else: Storage.list_folders(nil, scope, lib_opts(socket)))
    )
    |> assign(
      :folder_tree,
      if(scope_invalid, do: [], else: Storage.list_folder_tree(scope, lib_opts(socket)))
    )
    # A picker keeps its tree to itself: it neither reads nor writes the
    # user's saved tree (see `persist_tree_state/1`).
    |> assign(
      :sidebar_collapsed,
      not socket.assigns.picker and
        load_user_sidebar_collapsed(socket.assigns[:phoenix_kit_current_user])
    )
    |> assign(:sidebar_rev, 0)
    |> assign(
      :expanded_folders,
      if(socket.assigns.picker,
        do: MapSet.new(),
        else: load_user_expanded_folders(socket.assigns[:phoenix_kit_current_user])
      )
    )
    |> assign(:renaming_folder, nil)
    |> assign(:renaming_source, nil)
    |> assign(:renaming_text, "")
    |> assign(:editing_folder_description, nil)
    |> assign(:folder_description_text, "")
    # In-folder header editor (edits the current folder's name + description
    # together; distinct from the grid/list card description-only editors).
    |> assign(:editing_folder_header, nil)
    |> assign(:folder_header_name, "")
    |> assign(:folder_header_description, "")
    # A picker always shows the grid, whatever the user chose elsewhere.
    |> assign(
      :view_mode,
      if(socket.assigns.picker,
        do: "grid",
        else: load_user_view_mode(socket.assigns[:phoenix_kit_current_user])
      )
    )
    # Toolbar sort + file-type filter (socket state, applied to the listing).
    |> assign(:sort_by, "newest")
    # `only_file_type` locks this to one kind for the whole session — see the
    # attr docs on update/2. Absent, the toolbar owns it and starts at "all".
    |> assign(:file_type_filter, socket.assigns[:only_file_type] || "all")
    # Picture shape (`Storage.Shape`): "all", "wide" (a panorama) or "tall".
    |> assign(:shape_filter, "all")
    |> assign(:search_query, "")
    |> assign(:select_mode, false)
    |> assign(:selected_files, MapSet.new())
    |> assign(:selected_folders, MapSet.new())
    # Stacks view: which folder stacks are expanded inline, a per-folder
    # {previews, count} map for the collapsed pile thumbnails, and the loaded
    # files for each expanded stack. Populated only while view_mode is "stacks".
    # `expanded_stacks` is an ordered list (most-recently-opened first) so the
    # sections render newest-at-top in open order, not folder order.
    |> assign(:expanded_stacks, [])
    |> assign(:stack_previews, %{})
    |> assign(:stack_files, %{})
    # The one stack that should animate open (the just-clicked one). Restored
    # stacks (refresh / navigate-back) leave it nil so they appear instantly —
    # the fly-out only plays on an explicit open click.
    |> assign(:just_opened_stack, nil)
    |> assign(:show_move_modal, false)
    # New-folder modal: the typed name plus the default placeholder
    # ("untitled" / "untitled N") shown when left blank.
    |> assign(:show_new_folder_modal, false)
    |> assign(:new_folder_name, "")
    |> assign(:new_folder_placeholder, "")
    # Expand state for the Move modal's directory tree (separate from the
    # sidebar's :expanded_folders so drilling one doesn't move the other).
    # Starts collapsed → top-level folders only, drill in via the chevrons.
    |> assign(:move_expanded, MapSet.new())
    |> assign(:current_page, 1)
    |> assign(:per_page, 50)
    |> then(fn s ->
      if scope_invalid,
        do: assign(s, uploaded_files: [], total_count: 0, total_pages: 0),
        else: reload_current_page(s)
    end)
  end

  # ──────────────────────────────────────────────────────────────
  # Upload
  # ──────────────────────────────────────────────────────────────

  @doc """
  Handles the upload setup message from the MediaBrowser component.

  Parent LiveViews embedding MediaBrowser should add this to their `handle_info`:

      def handle_info({PhoenixKitWeb.Components.MediaBrowser, _id, :setup_uploads}, socket) do
        {:noreply, PhoenixKitWeb.Components.MediaBrowser.setup_uploads(socket)}
      end

  Or use the catch-all delegator:

      def handle_info({PhoenixKitWeb.Components.MediaBrowser, _, _} = msg, socket) do
        PhoenixKitWeb.Components.MediaBrowser.handle_parent_info(msg, socket)
      end
  """
  def setup_uploads(socket) do
    if socket.assigns[:uploads] do
      socket
    else
      max_size_mb = max_upload_size_mb()

      upload_opts = [
        accept: :any,
        max_entries: 10,
        max_file_size: max_size_mb * 1_000_000,
        auto_upload: true,
        progress: &__MODULE__.parent_progress/3
      ]

      # Pickers upload through an upload of their own (`@picker_upload`): a
      # page has one file input per upload, so a picker opened beside another
      # browser would otherwise render a second input with the same id, show
      # the other browser's transfers, and have its uploads copied there too.
      socket
      |> assign(:max_upload_size_mb, max_size_mb)
      |> allow_upload(:media_files, upload_opts)
      |> allow_upload(@picker_upload, upload_opts)
      |> attach_file_event_forwarding()
    end
  end

  # Entries LiveView turned away before a byte moved, named and cleared.
  #
  # Nothing ever rendered `upload_errors`, so a rejected entry sat in the
  # inline list as a progress bar stuck at 0% forever — and kept holding one
  # of the `max_entries` slots, so the NEXT drop silently lost a file too.
  # Dropping eleven files was the sharpest case: ten upload, the eleventh
  # never transfers, and the `:too_many_files` error on the config clears
  # without anyone seeing it. Now each such entry becomes a row in the
  # problems panel saying why, and is cancelled so it stops blocking.
  #
  # Read off `parent_uploads` on every render the parent hands down — the
  # one place every selection and drop is guaranteed to pass through,
  # however its entries were registered. The uploads live on the parent's
  # socket, so the cancel is the parent's (`:cancel_rejected_uploads`).
  defp harvest_rejected_uploads(socket) do
    name = socket.assigns.upload_name

    case socket.assigns[:parent_uploads] do
      # A real upload config only: `upload_errors/1,2` read its internals,
      # and component tests hand down plain maps standing in for one.
      %{^name => %Phoenix.LiveView.UploadConfig{} = conf} ->
        seen = socket.assigns[:upload_rejected_refs] || MapSet.new()

        case Enum.reject(rejected_entries(conf), fn {e, _} -> MapSet.member?(seen, e.ref) end) do
          [] ->
            socket

          rejected ->
            entries = Enum.map(rejected, &elem(&1, 0))
            send(self(), {__MODULE__, :cancel_rejected_uploads, entries})

            rejected
            |> Enum.reduce(socket, fn {entry, reason}, acc ->
              add_upload_problem(acc, %{
                kind: :rejected,
                client_name: entry.client_name,
                client_size: entry.client_size,
                reason: reason,
                retry: false
              })
            end)
            |> assign(:upload_rejected_refs, MapSet.union(seen, MapSet.new(entries, & &1.ref)))
        end

      _ ->
        socket
    end
  end

  @doc false
  def rejected_entries(conf) do
    open = Enum.reject(conf.entries, &(&1.done? or &1.cancelled?))

    invalid =
      for entry <- open, errors = upload_errors(conf, entry), errors != [] do
        {entry, upload_rejection_reason(errors, conf)}
      end

    # Beyond the limit: the entries past the first `max_entries` never get a
    # transfer slot — the LAST ones, in the order they were added.
    too_many =
      if :too_many_files in upload_errors(conf) do
        rejected_refs = MapSet.new(invalid, fn {e, _} -> e.ref end)

        open
        |> Enum.reject(&MapSet.member?(rejected_refs, &1.ref))
        |> Enum.drop(conf.max_entries)
        |> Enum.map(&{&1, upload_rejection_reason([:too_many_files], conf)})
      else
        []
      end

    invalid ++ too_many
  end

  @doc false
  def upload_rejection_reason(errors, conf) do
    cond do
      :too_large in errors ->
        gettext("Larger than the %{mb} MB upload limit.",
          mb: div(conf.max_file_size, 1_000_000)
        )

      :not_accepted in errors ->
        gettext("This type of file is not accepted here.")

      :too_many_files in errors ->
        gettext(
          "Up to %{count} files upload at once, so this one was not sent. Add it again.",
          count: conf.max_entries
        )

      true ->
        gettext("The upload could not start.")
    end
  end

  # Live-refresh plumbing: subscribe the parent LiveView to storage file
  # events and forward each one to every registered MediaBrowser on the
  # page, so a just-uploaded file's dimensions/thumbnails — and freshly
  # baked annotated thumbnails — appear without a manual reload (the
  # component refreshes the affected rows in its `update/2`). A lifecycle
  # hook (not an injected clause) so it composes with host LiveViews that
  # define their own handle_info; it {:halt}s, so the message never leaks
  # to host clauses. Guarded by setup_uploads' run-once check above —
  # attach_hook raises on duplicate names.
  defp attach_file_event_forwarding(socket) do
    if connected?(socket) do
      Storage.subscribe_to_file_events()

      attach_hook(socket, :phoenix_kit_mb_file_events, :handle_info, fn
        {:phoenix_kit_file_processed, file_uuid}, socket ->
          {:halt, forward_to_browsers(socket, file_processed: file_uuid)}

        {:phoenix_kit_file_thumbnail_updated, file_uuid}, socket ->
          {:halt, forward_to_browsers(socket, thumbnail_updated: file_uuid)}

        {:phoenix_kit_file_trashed, file_uuid}, socket ->
          {:halt, forward_to_browsers(socket, file_trashed: file_uuid)}

        {:phoenix_kit_file_restored, file_uuid}, socket ->
          {:halt, forward_to_browsers(socket, file_restored: file_uuid)}

        {:phoenix_kit_file_deleted, file_uuid}, socket ->
          {:halt, forward_to_browsers(socket, file_deleted: file_uuid)}

        {:phoenix_kit_files_trashed, file_uuids}, socket ->
          {:halt, forward_to_browsers(socket, files_trashed: file_uuids)}

        {:phoenix_kit_files_restored, file_uuids}, socket ->
          {:halt, forward_to_browsers(socket, files_restored: file_uuids)}

        {:phoenix_kit_files_deleted, file_uuids}, socket ->
          {:halt, forward_to_browsers(socket, files_deleted: file_uuids)}

        _msg, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  defp forward_to_browsers(socket, update) do
    socket.assigns[:media_browser_ids]
    |> Kernel.||(MapSet.new())
    |> Enum.each(&send_update(__MODULE__, [{:id, &1} | update]))

    socket
  end

  @doc false
  # Called by the Embed macro's `{:comments_updated, ...}` handle_info
  # clause (the comments component reports to the host PROCESS; components
  # can't receive handle_info). Fans the payload out to every registered
  # browser so an open viewer refreshes its counts/badges.
  def notify_file_comments_changed(socket, payload) do
    {:noreply, forward_to_browsers(socket, file_comments_changed: payload)}
  end

  @doc false
  # Progress callback that runs on the parent LiveView socket.
  # Consumes the upload and sends the file to the MediaBrowser component for processing.
  def parent_progress(name, entry, socket) when name in [:media_files, @picker_upload] do
    if entry.done? do
      # Persist file to a temp path since consume_uploaded_entry cleans up the original
      persistent_path = Path.join(System.tmp_dir!(), "pk_upload_#{entry.uuid}")

      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          File.cp!(path, persistent_path)
          {:ok, :done}
        end)

      if result == :done do
        path = into_inbox(socket, persistent_path, entry)
        # Payload is wrapped in a tuple so the outer message stays a 3-tuple;
        # the Embed macro's handle_info matches `{Mod, _, _}` only.
        send(self(), {__MODULE__, :process_pending_upload, {path, entry}})
      end

      # The bytes are the server's now: the browser can drop the copy it
      # stashed in case the transfer was cut short (the UploadResume hook).
      {:noreply, ack_received(socket, [entry])}
    else
      {:noreply, socket}
    end
  end

  # A received upload waits in the user's inbox until it is stored, so a
  # failure, a crash or a refresh before then leaves it somewhere the
  # "Upload problems" panel can find it (see `UploadInbox`). No user, or a
  # disk that refuses: the plain temp file, as before — still retryable for
  # as long as this LiveView lives.
  defp into_inbox(socket, path, entry) do
    with %{uuid: user_uuid} <- socket.assigns[:phoenix_kit_current_user],
         {:ok, _item, inbox_path} <-
           UploadInbox.put(user_uuid, path, %{
             client_name: entry.client_name,
             client_type: entry.client_type,
             client_size: entry.client_size
           }) do
      inbox_path
    else
      _ -> path
    end
  end

  # Tells the UploadResume hook which stashed files it can let go of —
  # received by the server, or rejected with a reason the panel shows. The
  # key is what the browser itself knows about a picked file.
  defp ack_received(socket, entries) do
    push_event(
      socket,
      "phoenix_kit:upload-received",
      Map.merge(resume_target(socket), %{keys: Enum.map(entries, &client_key/1)})
    )
  end

  # These events reach every UploadResume hook on the page. A picker names
  # itself so that the hook of the browser beside it ignores them (and it
  # ignores that browser's); any other browser sends them as it always did.
  defp resume_target(socket),
    do: if(socket.assigns[:picker] == true, do: %{browser: socket.assigns.id}, else: %{})

  @doc false
  def client_key(entry),
    do: "#{entry.client_name}|#{entry.client_size}|#{entry.client_last_modified}"

  # A browser's own copy is an inbox item of its own — with a record, so a
  # failure keeps it findable and a refresh cannot orphan it. No user or an
  # inbox that refuses: a plain temp copy, as before.
  defp copy_for_recipient(socket, path, entry, component_id) do
    inboxed =
      with %{uuid: user_uuid} <- socket.assigns[:phoenix_kit_current_user],
           {:ok, _item, copy} <-
             UploadInbox.put(
               user_uuid,
               path,
               %{
                 client_name: entry.client_name,
                 client_type: entry.client_type,
                 client_size: entry.client_size
               },
               copy: true
             ) do
        {:ok, copy}
      else
        _ -> :error
      end

    case inboxed do
      {:ok, _} = ok ->
        ok

      :error ->
        copy = "#{path}-#{component_id}"
        if File.cp(path, copy) == :ok, do: {:ok, copy}, else: :error
    end
  end

  @doc """
  Takes the browser `id` off the page's upload routing.

  Every browser registers with its LiveView when it mounts, and the page sends
  each finished upload — and a copy of it — to every browser registered. A
  host that stops rendering a browser (a closed modal, a switched tab) calls
  this, from the LiveView or from one of its LiveComponents (both run in the
  LiveView's process), so nothing is routed to a browser that is gone. It
  sends `{MediaBrowser, :unregister, id}` to the calling process, which
  `handle_parent_info/2` handles. Rendering the browser again registers it
  again — a new mount; a browser kept mounted (hidden) and unregistered is
  not registered again, and its uploads go to the inbox. Unregister only a
  browser you stop rendering.
  """
  @spec unregister_browser(String.t()) :: :ok
  def unregister_browser(id) do
    send(self(), {__MODULE__, :unregister, id})
    :ok
  end

  @doc "Catch-all handler for parent LiveViews to delegate MediaBrowser messages."
  def handle_parent_info({__MODULE__, :register_component, id}, socket) do
    ids = MapSet.put(socket.assigns[:media_browser_ids] || MapSet.new(), id)
    {:noreply, assign(socket, :media_browser_ids, ids)}
  end

  def handle_parent_info({__MODULE__, :register_picker, id}, socket) do
    ids = MapSet.put(socket.assigns[:media_picker_ids] || MapSet.new(), id)
    {:noreply, assign(socket, :media_picker_ids, ids)}
  end

  def handle_parent_info({__MODULE__, :unregister, id}, socket) do
    {:noreply,
     socket
     |> assign(
       :media_browser_ids,
       MapSet.delete(socket.assigns[:media_browser_ids] || MapSet.new(), id)
     )
     |> assign(
       :media_picker_ids,
       MapSet.delete(socket.assigns[:media_picker_ids] || MapSet.new(), id)
     )}
  end

  # A picker's report is the host's to handle, ahead of this delegate (see the
  # moduledoc's "Picker"). One that ends up here was not handled: said in the
  # log rather than dropped in silence.
  def handle_parent_info({__MODULE__, id, payload}, socket)
      when payload == :pick_cancelled or
             (is_tuple(payload) and tuple_size(payload) == 2 and
                elem(payload, 0) in [:picked, :picker_uploading]) do
    Logger.warning(
      "MediaBrowser id=#{id}: the host did not handle the picker's " <>
        "#{inspect(if is_tuple(payload), do: elem(payload, 0), else: payload)} — match " <>
        "{MediaBrowser, id, _} picker messages before handle_parent_info/2"
    )

    {:noreply, socket}
  end

  def handle_parent_info({__MODULE__, _id, {:flash, kind, message}}, socket)
      when kind in [:info, :error, :warning] and is_binary(message) do
    {:noreply, Phoenix.LiveView.put_flash(socket, kind, message)}
  end

  def handle_parent_info({__MODULE__, :process_pending_upload, {path, entry}}, socket) do
    # Forward the upload to every registered MediaBrowser. If more than one is on
    # the page, copy the temp file per recipient so each component owns its own
    # path — otherwise the first one to run would delete the shared file and the
    # rest would crash on `File.stat/1`.
    # The picker upload's files go to the browsers on it, any other upload's
    # to the other browsers (see `setup_uploads/1`). A retried or hand-built
    # entry carries no upload name and goes to the other browsers, as every
    # upload used to.
    browsers = socket.assigns[:media_browser_ids] || MapSet.new()
    pickers = socket.assigns[:media_picker_ids] || MapSet.new()

    component_ids =
      if Map.get(entry, :upload_config) == @picker_upload,
        do: browsers |> MapSet.intersection(pickers) |> MapSet.to_list(),
        else: browsers |> MapSet.difference(pickers) |> MapSet.to_list()

    case component_ids do
      [] ->
        keep_unrouted_upload(path)

      [single] ->
        send_update(__MODULE__, id: single, pending_upload: {path, entry})

      [first | rest] ->
        send_update(__MODULE__, id: first, pending_upload: {path, entry})

        Enum.each(rest, fn id ->
          case copy_for_recipient(socket, path, entry, id) do
            {:ok, copy} -> send_update(__MODULE__, id: id, pending_upload: {copy, entry})
            :error -> :ok
          end
        end)
    end

    {:noreply, socket}
  end

  # A browser spotted entries LiveView turned away (see
  # `harvest_rejected_uploads/1`) and has listed them; the uploads are this
  # socket's, so the cancel happens here. Cancelling an entry another
  # browser already cancelled is a no-op.
  def handle_parent_info({__MODULE__, :cancel_rejected_uploads, entries}, socket) do
    socket =
      Enum.reduce(entries, socket, fn entry, acc ->
        name = Map.get(entry, :upload_config) || :media_files

        open? =
          case acc.assigns[:uploads] do
            %{^name => %{entries: list}} when is_list(list) ->
              Enum.any?(list, &(&1.ref == entry.ref))

            _ ->
              false
          end

        if open?, do: cancel_upload(acc, name, entry.ref), else: acc
      end)

    {:noreply, ack_received(socket, entries)}
  end

  def handle_parent_info(_msg, socket), do: {:noreply, socket}

  # No browser is registered to take the upload: the host took the last one
  # off the page while the transfer ran. Deleting it lost the file without a
  # word; kept in the inbox it is an upload problem the next browser lists,
  # with Retry. A plain temp file (no user, no inbox) has nowhere to be
  # listed, so it goes.
  defp keep_unrouted_upload(path) do
    case UploadInbox.locate(path) do
      {user_uuid, id} ->
        UploadInbox.fail(
          user_uuid,
          id,
          gettext("No open media browser could receive this upload.")
        )

      nil ->
        Logger.warning("MediaBrowser: no browser was registered to receive an upload")
        File.rm(path)
    end
  end

  defp maybe_allow_upload(socket, has_buckets) do
    if has_buckets do
      assign(socket, :max_upload_size_mb, max_upload_size_mb())
    else
      assign(socket, :max_upload_size_mb, 0)
    end
  end

  @doc false
  def handle_progress(:media_files, entry, socket) do
    socket =
      if entry.done? do
        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            process_single_upload(socket, path, entry)
          end)

        {flash_type, flash_msg} = build_upload_flash_message([result])

        new_uuids =
          case result do
            {:ok, %{file_uuid: uuid}} -> [uuid | socket.assigns.last_uploaded_file_uuids]
            _ -> socket.assigns.last_uploaded_file_uuids
          end

        socket
        |> reload_current_page()
        |> Phoenix.LiveView.put_flash(flash_type, flash_msg)
        |> assign(:last_uploaded_file_uuids, new_uuids)
      else
        socket
      end

    {:noreply, socket}
  end

  # ──────────────────────────────────────────────────────────────
  # Event handlers
  # ──────────────────────────────────────────────────────────────

  # Every event that changes something: exactly the ones that refuse to run
  # when the browser is `readonly` (a test holds the two lists together).
  @write_events ~w(
    change_folder_color delete_all_orphaned delete_file delete_folder delete_selected
    discard_all_uploads discard_upload empty_trash folder_description_input folder_header_input long_press_select
    move_file_to_folder move_folder_to_folder move_selected_to_folder new_folder_input
    open_cover_picker open_image_editor open_logo_picker open_new_folder_modal
    prepare_move_file prepare_move_folder remove_folder_cover remove_folder_logo
    rename_folder rename_folder_input restore_file restore_folder restore_selected
    retry_all_uploads retry_upload rotate_file save_folder_description
    save_folder_header box_select select_all set_featured set_header_size show_move_modal show_upload
    start_edit_folder_description start_edit_folder_header start_rename_folder
    removal_confirm removal_release submit_new_folder toggle_header_option toggle_move_folder toggle_select
    toggle_select_folder toggle_select_mode toggle_upload trash_file trash_folder
    unset_featured
  )

  @doc false
  def write_events, do: @write_events

  # The actions that work on the selection, not on what their params name.
  @selection_events ~w(delete_selected move_selected_to_folder restore_selected)

  # The actions that work on every file of the view at once.
  @every_file_events ~w(empty_trash delete_all_orphaned)

  # The events the removal guard stands in front of: each can send a file to
  # the trash or delete it (the drag onto the Trash button pushes
  # `trash_file`, `trash_folder` or `delete_selected`). "Delete all orphaned"
  # is not one of them: orphans are in no folder.
  @removal_events ~w(trash_file delete_file delete_selected trash_folder delete_folder empty_trash)

  # The actions that carry every file homed under a folder with them: trash,
  # delete and move a folder. Renaming or recolouring one is shared folder
  # metadata and stays allowed.
  @folder_content_events ~w(trash_folder delete_folder move_folder_to_folder)

  # Folder events that change what a folder is (its name, colour, header, cover,
  # description) or remove it. A restricted viewer (`viewer_uuid`) sees folders
  # that merely hold one of their files, but changes only the ones they created.
  @folder_metadata_events ~w(
    rename_folder rename_folder_input start_rename_folder change_folder_color
    save_folder_description start_edit_folder_description folder_description_input
    save_folder_header start_edit_folder_header folder_header_input set_header_size
    toggle_header_option open_cover_picker open_logo_picker remove_folder_cover
    remove_folder_logo trash_folder delete_folder restore_folder
  )

  # The folder writes `folder_actions: false` takes away (see the moduledoc's
  # "Picker"): every folder edit, every move, folders in a selection, and the
  # Trash view. Hidden in the markup and refused below, ahead of every other
  # clause — the markup is a courtesy, a console can send any event.
  @folder_action_events ~w(
    open_new_folder_modal new_folder_input submit_new_folder
    start_rename_folder rename_folder_input rename_folder change_folder_color
    start_edit_folder_description folder_description_input save_folder_description
    start_edit_folder_header folder_header_input save_folder_header set_header_size
    toggle_header_option open_cover_picker open_logo_picker remove_folder_cover
    remove_folder_logo trash_folder delete_folder restore_folder
    move_folder_to_folder prepare_move_folder move_file_to_folder prepare_move_file
    show_move_modal toggle_move_folder move_selected_to_folder toggle_select_folder
    toggle_trash_filter empty_trash restore_file restore_selected
  )

  @doc false
  def folder_action_events, do: @folder_action_events

  # What a picker does not have: bulk select (its pick is an ordered list of
  # its own) and the view switch (it always shows the grid).
  @picker_off_events ~w(
    toggle_select_mode long_press_select toggle_select toggle_select_folder
    select_all box_select set_view_mode
  )

  @doc false
  def picker_off_events, do: @picker_off_events

  # What a picker does not do to the files it shows: they are someone's
  # files, opened to be chosen from. Rotating, editing, the featured pointer
  # and emptying the trash are refused; Download and Move to Trash stay.
  # Deleting for good (the Trash view's Delete) is refused below.
  @picker_file_write_events ~w(rotate_file open_image_editor set_featured unset_featured empty_trash)

  @doc false
  def picker_file_write_events, do: @picker_file_write_events

  def handle_event(event, _params, socket)
      when event in @folder_action_events and socket.assigns.folder_actions == false do
    {:noreply, log_refused(socket, event, "folder actions are off")}
  end

  def handle_event(event, _params, socket)
      when event in @picker_off_events and socket.assigns.picker == true do
    {:noreply, log_refused(socket, event, "the browser is a picker")}
  end

  def handle_event(event, _params, socket)
      when event in @picker_file_write_events and socket.assigns.picker == true do
    {:noreply, log_refused(socket, event, "the browser is a picker")}
  end

  def handle_event(event, _params, socket)
      when event in ~w(delete_file delete_folder delete_selected) and
             socket.assigns.picker == true and socket.assigns.filter_trash == true do
    {:noreply, log_refused(socket, event, "a picker deletes nothing for good")}
  end

  # A restricted viewer (`viewer_uuid`) is shown only what is theirs, and this is
  # the boundary for what an event NAMES: any uuid can be sent from a console.
  # An event that names a file someone else uploaded, or a folder the viewer
  # cannot see, is refused before any handler below sees it, and so is one that
  # changes or removes a folder they did not create.
  def handle_event(event, params, socket)
      when is_binary(socket.assigns.viewer_uuid) and
             not is_map_key(socket.private, :viewer_checked) do
    if viewer_refused?(event, params, socket) do
      Logger.warning(
        "MediaBrowser id=#{socket.assigns.id}: #{event} refused — it names something " <>
          "viewer #{socket.assigns.viewer_uuid} may not see or change"
      )

      {:noreply, put_flash(socket, :error, gettext("That is not yours"))}
    else
      socket = %{socket | private: Map.put(socket.private, :viewer_checked, true)}
      {:noreply, socket} = handle_event(event, params, socket)
      {:noreply, %{socket | private: Map.delete(socket.private, :viewer_checked)}}
    end
  end

  # A contributor changes only the files they uploaded (`own_files_only`):
  # a write that names someone else's file, or works on a selection holding
  # one, is refused before any handler below sees it.
  def handle_event(event, params, socket)
      when is_binary(socket.assigns.own_files_only) and event in @write_events and
             not is_map_key(socket.private, :own_files_checked) do
    uuids =
      param_uuids(params, []) ++
        if(event in @selection_events,
          do: Enum.to_list(socket.assigns.selected_files),
          else: []
        )

    folders = acted_on_folders(event, params, socket)

    # Emptying the trash and clearing orphans act on every file at once; a
    # folder write carries every file in its subtree.
    # Emptying the trash and clearing orphans are refused a contributor, who
    # would touch files they did not upload; for a restricted viewer they are
    # scoped to the viewer's own files already (`lib_opts/1`).
    if (event in @every_file_events and is_nil(socket.assigns[:viewer_uuid])) or
         others_file?(uuids, socket.assigns.own_files_only) or
         others_file_in_folders?(folders, socket.assigns.own_files_only) do
      Logger.warning(
        "MediaBrowser id=#{socket.assigns.id}: #{event} refused — it names a file " <>
          "#{socket.assigns.own_files_only} did not upload"
      )

      {:noreply, put_flash(socket, :error, gettext("You can only change files you uploaded"))}
    else
      socket = %{socket | private: Map.put(socket.private, :own_files_checked, true)}
      {:noreply, socket} = handle_event(event, params, socket)
      {:noreply, %{socket | private: Map.delete(socket.private, :own_files_checked)}}
    end
  end

  # A browser that shows one library acts only on that library's files and
  # folders; one that names none acts only on what a site listing shows (not a
  # user library, not a private one). The listings are filtered already; this
  # is the boundary for what an event NAMES, since any uuid can be sent from a
  # console: a file or folder outside the shown library in an event's params
  # refuses the event before any handler below sees it. Without it a member of
  # a user library could trash, rename or move a Media file by its uuid
  # (`within_scope?/2` is true for everything when there is no scope folder).
  def handle_event(event, params, socket)
      when not is_map_key(socket.private, :library_checked) do
    if foreign_reference?(params, socket.assigns[:library_uuid]) do
      Logger.warning(
        "MediaBrowser id=#{socket.assigns.id}: #{event} refused — it names a file or " <>
          "folder outside #{shown_library_label(socket.assigns[:library_uuid])}"
      )

      {:noreply, put_flash(socket, :error, library_refusal(socket.assigns[:library_uuid], event))}
    else
      socket = %{socket | private: Map.put(socket.private, :library_checked, true)}

      {:noreply, socket} = handle_event(event, params, socket)
      # An event can end an upload's wait without the page rendering again
      # (a Retry whose store failed empties the browser's own queue): the
      # picker's report to its host follows it here, as it follows
      # `update/2`. The page's transfers are read from its last render, so a
      # cancelled transfer is seen on the next `update/2`, not here.
      {:noreply, socket |> unchecked() |> sync_picker_uploading()}
    end
  end

  # The removal guard (see the moduledoc's "Removal guard"). Every event that
  # can make a file disappear is stopped here, AFTER the gates above (readonly
  # is left to the handler, which refuses it; the viewer, own-files and
  # library gates have run) and BEFORE its handler: the plan says which files
  # would go, the module is asked where they are in use, and the dialog asks
  # the person. The handler itself runs on the confirmation, through the
  # gates again. With no guard, or nothing that disappears, it runs at once —
  # as it always did.
  def handle_event(event, params, socket)
      when event in @removal_events and not is_map_key(socket.private, :removal_checked) do
    run_removal(event, params, socket)
  end

  def handle_event("removal_confirm", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "removal_confirm")}
  end

  def handle_event("removal_release", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "removal_release")}
  end

  # Only the dialog this browser shows now: a click from a stale render, or an
  # event made up in a console, names a token that is not the pending one.
  def handle_event("removal_confirm", %{"token" => token}, socket) do
    case socket.assigns[:removal_pending] do
      %{token: ^token, event: event, params: params, failed?: false} = pending ->
        socket
        |> assign(:removal_pending, nil)
        |> replay_removal(event, params, {:confirm, pending})

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("removal_release", %{"token" => token}, socket) do
    case socket.assigns[:removal_pending] do
      %{token: ^token, release_label: label} = pending when is_binary(label) ->
        release_removal(socket, pending)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("removal_cancel", %{"token" => token}, socket) do
    case socket.assigns[:removal_pending] do
      %{token: ^token} -> {:noreply, assign(socket, :removal_pending, nil)}
      _ -> {:noreply, socket}
    end
  end

  # No token, or not a map of params the dialog sends: nothing to answer.
  def handle_event(event, _params, socket)
      when event in ~w(removal_confirm removal_release removal_cancel),
      do: {:noreply, socket}

  # Finder/Explorer-style instant folder creation. Click the "+" button
  # in any toolbar and a folder appears named "untitled" (or
  # "untitled 1", "untitled 2", ... if that's taken). The new folder
  # immediately opens inline rename in the sidebar.
  # Open the New-folder modal, seeding the placeholder with the next default
  # name. Creation itself is deferred to "submit_new_folder" so Cancel adds
  # nothing.
  def handle_event("open_new_folder_modal", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "open_new_folder_modal")}
  end

  def handle_event("open_new_folder_modal", _params, socket) do
    case folder_creation_block(socket) do
      nil ->
        parent_uuid = current_folder_uuid(socket)
        scope = scope_folder_id(socket)

        {:noreply,
         socket
         |> assign(:show_new_folder_modal, true)
         |> assign(:new_folder_name, "")
         |> assign(
           :new_folder_placeholder,
           next_untitled_name(parent_uuid, scope, lib_opts(socket))
         )}

      msg ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("new_folder_input", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "new_folder_input")}
  end

  def handle_event("new_folder_input", %{"name" => name}, socket) do
    {:noreply, assign(socket, :new_folder_name, name)}
  end

  def handle_event("close_new_folder_modal", _params, socket) do
    {:noreply, assign(socket, :show_new_folder_modal, false)}
  end

  def handle_event("submit_new_folder", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "submit_new_folder")}
  end

  def handle_event("submit_new_folder", %{"name" => name}, socket) do
    case folder_creation_block(socket) do
      nil ->
        parent_uuid = current_folder_uuid(socket)
        scope = scope_folder_id(socket)
        user = socket.assigns[:phoenix_kit_current_user]

        # Blank → fall back to the placeholder default ("untitled"/"untitled N").
        name =
          case String.trim(name) do
            "" -> next_untitled_name(parent_uuid, scope, lib_opts(socket))
            trimmed -> trimmed
          end

        socket = assign(socket, :show_new_folder_modal, false)

        case Storage.create_folder(
               %{name: name, parent_uuid: parent_uuid, user_uuid: user && user.uuid}
               |> Map.merge(Map.new(lib_opts(socket))),
               scope
             ) do
          {:ok, _folder} ->
            {:noreply,
             socket
             |> assign(:new_folder_name, "")
             |> reload_folder_lists()
             |> expand_sidebar_folder(parent_uuid)
             |> force_sidebar_expanded()
             |> put_flash(:info, gettext("Folder \"%{name}\" created", name: name))}

          {:error, :out_of_scope} ->
            {:noreply,
             put_flash(socket, :error, gettext("Cannot create folder outside the allowed scope"))}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to create folder"))}
        end

      msg ->
        {:noreply,
         socket
         |> assign(:show_new_folder_modal, false)
         |> put_flash(:error, msg)}
    end
  end

  def handle_event("delete_folder", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "delete_folder")}
  end

  def handle_event("delete_folder", %{"id" => folder_uuid}, socket) do
    folder = Storage.get_folder(folder_uuid)
    scope = scope_folder_id(socket)

    if folder do
      # Mirror the file kebab: trash-recursive when outside the trash
      # view, permanent-recursive (with storage cleanup) when inside.
      # Subtree files come along automatically — both helpers walk
      # descendants via `Storage.folder_subtree_uuids/1` and apply the
      # operation atomically.
      result =
        if socket.assigns[:filter_trash] do
          Storage.delete_folder_completely(folder, scope)
        else
          Storage.trash_folder(folder, scope)
        end

      # Only `{:ok, _}` is a deletion. Everything else used to fall through
      # to the success flash — a refused or failed delete said "moved to
      # trash" while the folder sat where it was.
      case result do
        {:ok, _} ->
          flash =
            if socket.assigns[:filter_trash],
              do: gettext("Folder permanently deleted"),
              else: gettext("Folder moved to trash")

          {:noreply,
           socket
           |> reload_folder_lists()
           |> reload_current_page()
           |> put_flash(:info, flash)}

        {:error, :out_of_scope} ->
          {:noreply,
           put_flash(socket, :error, gettext("Cannot delete folder outside the allowed scope"))}

        {:error, :managed} ->
          {:noreply, put_flash(socket, :error, managed_folder_message())}

        {:error, :in_use} ->
          # What could go went; the folders that still hold a file in use stayed.
          {:noreply,
           socket
           |> reload_folder_lists()
           |> reload_current_page()
           |> put_flash(
             :error,
             gettext(
               "Some files in this folder are in use by something else, so they and their folders were kept."
             )
           )}

        {:error, reason} ->
          Logger.warning(
            "[MediaBrowser] delete_folder #{folder.uuid} failed: #{inspect(reason, limit: 5)}"
          )

          message =
            if socket.assigns[:filter_trash],
              do: gettext("Could not delete the folder. Nothing was removed."),
              else: gettext("Could not move the folder to the trash. Nothing was moved.")

          {:noreply, socket |> reload_folder_lists() |> put_flash(:error, message)}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Folder not found"))}
    end
  end

  def handle_event("move_file_to_folder", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "move_file_to_folder")}
  end

  def handle_event(
        "move_file_to_folder",
        %{"file_uuid" => file_uuid, "folder_uuid" => folder_uuid},
        socket
      ) do
    scope = scope_folder_id(socket)
    # "root" in a scoped browser is the scope folder, not nil. Passing nil
    # would mean the system's true root, which is outside the scope —
    # `move_file_to_folder/3` would reject it with `:out_of_scope`.
    target = if folder_uuid == "", do: scope, else: folder_uuid

    from = appearance_folder_of(socket, file_uuid)

    case Storage.move_file_between_folders(file_uuid, from, target, scope) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("File moved")) |> reload_current_page()}

      {:error, :out_of_scope} ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot move file outside the allowed scope"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to move file"))}
    end
  end

  # Drag a folder onto another folder (or the root drop target) to
  # reparent it. Mirrors `move_file_to_folder` but uses
  # `Storage.update_folder/3`, which enforces the cycle check (can't
  # move a folder into its own descendant). JS pre-empts the
  # drop-on-self case so we don't see it here.
  def handle_event("move_folder_to_folder", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "move_folder_to_folder")}
  end

  def handle_event(
        "move_folder_to_folder",
        %{"folder_uuid" => folder_uuid, "target_uuid" => target_uuid},
        socket
      ) do
    scope = scope_folder_id(socket)
    target = if target_uuid == "", do: scope, else: target_uuid

    case Storage.get_folder(folder_uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Folder not found"))}

      folder ->
        case Storage.update_folder(folder, %{parent_uuid: target}, scope) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Folder moved"))
             |> reload_folder_lists()
             |> reload_current_page()}

          {:error, :out_of_scope} ->
            {:noreply,
             put_flash(socket, :error, gettext("Cannot move folder outside the allowed scope"))}

          {:error, :cycle} ->
            {:noreply,
             put_flash(socket, :error, gettext("Cannot move a folder into its own descendant"))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to move folder"))}
        end
    end
  end

  # Drag-to-trash: file dragged onto the sidebar Trash button. Always
  # soft-deletes via `Storage.trash_file/1` — the "drop on trash" gesture
  # means "put this in the trash", not "permanently destroy". Permanent
  # deletion stays explicit (kebab Delete Permanently when already in
  # trash view, or the Empty Trash button).
  def handle_event("trash_file", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "trash_file")}
  end

  def handle_event("trash_file", %{"file_uuid" => file_uuid}, socket) do
    scope = scope_folder_id(socket)
    repo = PhoenixKit.Config.get_repo()
    file = repo.get(Storage.File, file_uuid)
    viewed = file && appearance_folder(socket, file)

    cond do
      is_nil(file) ->
        {:noreply, put_flash(socket, :error, gettext("File not found"))}

      not removable_here?(file, viewed, scope) ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot move file outside the allowed scope"))}

      true ->
        result = Storage.remove_file_from_folder(file, viewed)

        {:noreply,
         socket
         |> put_flash(:info, removal_flash(result))
         |> unpick_removed(file_uuid, result)
         |> close_viewer_on(file_uuid)
         |> reload_current_page()}
    end
  end

  # Drag-to-trash for a single folder. Mirrors `trash_file` above but
  # uses `Storage.trash_folder/2`, which recursively trashes the folder
  # and every descendant + file inside the subtree. Always soft-delete
  # — permanent deletion stays explicit (kebab Delete Permanently when
  # already in the trash view, or bulk select + delete).
  def handle_event("trash_folder", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "trash_folder")}
  end

  def handle_event("trash_folder", %{"folder_uuid" => folder_uuid}, socket) do
    scope = scope_folder_id(socket)
    folder = Storage.get_folder(folder_uuid)

    cond do
      is_nil(folder) ->
        {:noreply, put_flash(socket, :error, gettext("Folder not found"))}

      not Storage.within_scope?(folder.uuid, scope) ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot move folder outside the allowed scope"))}

      true ->
        case Storage.trash_folder(folder, scope) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Folder moved to trash"))
             |> reload_folder_lists()
             |> reload_current_page()}

          {:error, :out_of_scope} ->
            {:noreply,
             put_flash(socket, :error, gettext("Cannot move folder outside the allowed scope"))}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Failed to move folder to trash"))}
        end
    end
  end

  def handle_event("search", %{"q" => query}, socket) do
    if controlled_mode?(socket) do
      folder_uuid = current_folder_uuid(socket)

      send(
        self(),
        {__MODULE__, socket.assigns.id,
         {:navigate, %{folder: folder_uuid, q: query, page: 1, view: socket.assigns.file_view}}}
      )

      {:noreply, socket}
    else
      folder_uuid = current_folder_uuid(socket)
      per_page = socket.assigns.per_page
      scope = scope_folder_id(socket)
      file_view = socket.assigns.file_view

      {files, total_count} =
        if file_view == "all" do
          load_all_view_files(scope, 1, per_page, query, list_extra(socket))
        else
          load_scoped_files(scope, 1, per_page, folder_uuid, query, list_extra(socket))
        end

      folders =
        cond do
          file_view == "all" -> []
          query != "" -> Storage.search_folders(query, folder_uuid, scope, lib_opts(socket))
          true -> Storage.list_folders(folder_uuid, scope, lib_opts(socket))
        end

      {:noreply,
       socket
       |> assign(:search_query, query)
       |> assign(:folders, folders)
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, Pagination.total_pages(total_count, per_page))
       |> reset_stacks()}
    end
  end

  # The inline search collapses back to the magnifier when emptied via the ✕ or
  # blurred while empty.
  def handle_event("close_search_if_empty", _params, socket) do
    if socket.assigns.search_query == "" do
      {:noreply, assign(socket, :show_search, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_search", _params, socket) do
    socket = assign(socket, :show_search, false)

    if controlled_mode?(socket) do
      folder_uuid = current_folder_uuid(socket)

      send(
        self(),
        {__MODULE__, socket.assigns.id,
         {:navigate, %{folder: folder_uuid, q: "", page: 1, view: socket.assigns.file_view}}}
      )

      {:noreply, socket}
    else
      folder_uuid = current_folder_uuid(socket)
      per_page = socket.assigns.per_page
      scope = scope_folder_id(socket)
      file_view = socket.assigns.file_view

      {files, total_count} =
        if file_view == "all" do
          load_all_view_files(scope, 1, per_page, "", list_extra(socket))
        else
          load_scoped_files(scope, 1, per_page, folder_uuid, "", list_extra(socket))
        end

      folders =
        if file_view == "all",
          do: [],
          else: Storage.list_folders(folder_uuid, scope, lib_opts(socket))

      {:noreply,
       socket
       |> assign(:search_query, "")
       |> assign(:folders, folders)
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, Pagination.total_pages(total_count, per_page))
       |> reset_stacks()}
    end
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("navigate_folder", params, socket) do
    folder_uuid = params["folder-uuid"] || params["folder_uuid"]
    navigate_to_folder(socket, folder_uuid)
  end

  def handle_event("navigate_root", _params, socket) do
    navigate_to_folder(socket, nil)
  end

  def handle_event("navigate_view_all", _params, socket) do
    if controlled_mode?(socket) do
      q = socket.assigns.search_query

      send(
        self(),
        {__MODULE__, socket.assigns.id,
         {:navigate, %{view: "all", folder: nil, q: q, page: 1, filter_orphaned: false}}}
      )

      {:noreply, socket}
    else
      scope = scope_folder_id(socket)
      per_page = socket.assigns.per_page
      q = socket.assigns.search_query
      {files, total_count} = load_all_view_files(scope, 1, per_page, q, list_extra(socket))

      {:noreply,
       socket
       |> assign(:file_view, "all")
       |> assign(:current_folder, nil)
       |> assign(:breadcrumbs, [])
       |> assign(:folders, [])
       |> assign(:filter_orphaned, false)
       |> assign(:filter_trash, false)
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, Pagination.total_pages(total_count, per_page))}
    end
  end

  def handle_event("set_view_mode", %{"mode" => mode}, socket)
      when mode in ["grid", "list", "stacks"] do
    # Persist the choice to user meta so the next page load renders this mode
    # directly (the server is the source of truth — see @media_view_mode_key).
    socket =
      case socket.assigns[:phoenix_kit_current_user] do
        %{} = user ->
          assign(socket, :phoenix_kit_current_user, persist_user_view_mode(user, mode))

        _ ->
          socket
      end

    # Switching into stacks needs the per-folder previews computed once.
    {:noreply, socket |> assign(:view_mode, mode) |> assign_stacks()}
  end

  def handle_event("toggle_stack_expand", %{"folder-uuid" => folder_uuid}, socket) do
    expanded = socket.assigns.expanded_stacks

    socket =
      if folder_uuid in expanded do
        # Close: the client already played the fly-back before pushing this,
        # so just drop it. `just_opened_stack` clears so nothing re-animates.
        socket
        |> assign(:expanded_stacks, List.delete(expanded, folder_uuid))
        |> assign(:just_opened_stack, nil)
      else
        files = stack_folder_files(socket, folder_uuid, socket.assigns.per_page)

        # Prepend so the just-opened stack renders at the top, in open order.
        # Mark it as the one to animate open (only an explicit click does).
        socket
        |> assign(:expanded_stacks, [folder_uuid | expanded])
        |> assign(:just_opened_stack, folder_uuid)
        |> Phoenix.Component.update(:stack_files, &Map.put(&1, folder_uuid, files))
      end

    {:noreply, push_event(socket, "pk:stacks", %{uuids: socket.assigns.expanded_stacks})}
  end

  # Load the next page of files into an already-open stack, appending to what's
  # shown. Re-reads from the top at the grown limit (so it stays consistent with
  # assign_stacks); cards already in the DOM keep their place, new ones append.
  def handle_event("load_more_stack", %{"folder-uuid" => folder_uuid}, socket) do
    if folder_uuid in socket.assigns.expanded_stacks do
      loaded = length(Map.get(socket.assigns.stack_files, folder_uuid, []))
      files = stack_folder_files(socket, folder_uuid, loaded + socket.assigns.per_page)
      {:noreply, Phoenix.Component.update(socket, :stack_files, &Map.put(&1, folder_uuid, files))}
    else
      {:noreply, socket}
    end
  end

  # Reopen the stacks the user had expanded last visit (persisted in
  # localStorage by the StackMemory hook). Only meaningful in stacks view;
  # unknown/out-of-scope uuids are dropped, then echoed back so the hook can
  # prune them. Order is preserved (most-recently-opened first), matching how
  # the hook stored it.
  def handle_event("restore_stacks", %{"uuids" => uuids}, socket) when is_list(uuids) do
    if socket.assigns.view_mode == "stacks" do
      known = MapSet.new(socket.assigns.folders, & &1.uuid)
      valid = Enum.filter(uuids, &MapSet.member?(known, &1))

      socket =
        socket
        |> assign(:expanded_stacks, valid)
        |> assign(:just_opened_stack, nil)
        |> assign_stacks()

      {:noreply, push_event(socket, "pk:stacks", %{uuids: valid})}
    else
      {:noreply, socket}
    end
  end

  # The toolbar's sort, type and shape live in the URL when the browser is
  # synced to it (a refresh, or a tab the browser discarded and reloaded, comes
  # back to the same view), and in the socket when it is not. Either way the
  # listing restarts at its first page.
  def handle_event("set_sort", %{"sort" => sort}, socket) when sort in @valid_sorts do
    {:noreply, set_view_option(socket, :sort_by, :sort, sort)}
  end

  # Ignore an out-of-whitelist sort instead of crashing the component.
  def handle_event("set_sort", _params, socket), do: {:noreply, socket}

  def handle_event("set_file_filter", %{"type" => type}, socket)
      when type in @valid_file_types do
    # A locked browser hides this control, but the event is still reachable
    # from a console — and the whole point of the lock is that the consumer
    # can trust what comes back, so honour it on the server rather than in
    # the markup alone.
    if socket.assigns[:only_file_type] do
      {:noreply, socket}
    else
      {:noreply, set_view_option(socket, :file_type_filter, :type, type)}
    end
  end

  # Ignore an out-of-whitelist file-type filter instead of crashing.
  def handle_event("set_file_filter", _params, socket), do: {:noreply, socket}

  def handle_event("set_shape_filter", %{"shape" => shape}, socket)
      when shape in @valid_shapes do
    {:noreply, set_view_option(socket, :shape_filter, :shape, shape)}
  end

  def handle_event("set_shape_filter", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_sidebar", _params, socket) do
    socket = assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)
    {:noreply, persist_tree_state(socket)}
  end

  def handle_event("start_rename_folder", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "start_rename_folder")}
  end

  def handle_event("start_rename_folder", %{"folder-uuid" => folder_uuid} = params, socket) do
    source = params["source"] || "content"
    folder = Storage.get_folder(folder_uuid)

    {:noreply,
     socket
     |> assign(:renaming_folder, folder_uuid)
     |> assign(:renaming_source, source)
     |> assign(:renaming_text, (folder && folder.name) || "")}
  end

  def handle_event("rename_folder_input", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "rename_folder_input")}
  end

  def handle_event("rename_folder_input", %{"name" => name}, socket) do
    {:noreply, assign(socket, :renaming_text, name)}
  end

  def handle_event("cancel_rename_folder", _params, socket) do
    {:noreply,
     socket
     |> assign(:renaming_folder, nil)
     |> assign(:renaming_source, nil)
     |> assign(:renaming_text, "")}
  end

  def handle_event("rename_folder", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "rename_folder")}
  end

  def handle_event("rename_folder", %{"folder_uuid" => folder_uuid, "name" => name}, socket) do
    folder = Storage.get_folder(folder_uuid)

    scope = scope_folder_id(socket)

    if folder && name != "" do
      case Storage.update_folder(folder, %{name: String.trim(name)}, scope) do
        {:ok, updated} ->
          parent_uuid = current_folder_uuid(socket)

          {:noreply,
           socket
           |> assign(:renaming_folder, nil)
           |> assign(:renaming_source, nil)
           |> assign(:renaming_text, "")
           |> assign(:folders, Storage.list_folders(parent_uuid, scope, lib_opts(socket)))
           |> assign(:folder_tree, Storage.list_folder_tree(scope, lib_opts(socket)))
           |> refresh_header_folder(folder_uuid, updated)}

        {:error, :out_of_scope} ->
          {:noreply,
           put_flash(socket, :error, gettext("Cannot rename folder outside the allowed scope"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to rename folder"))}
      end
    else
      {:noreply,
       socket
       |> assign(:renaming_folder, nil)
       |> assign(:renaming_source, nil)
       |> assign(:renaming_text, "")}
    end
  end

  # Folder description edit — opens the inline editor in the current-folder
  # header, seeded with the folder's existing description.
  def handle_event("start_edit_folder_description", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "start_edit_folder_description")}
  end

  def handle_event("start_edit_folder_description", %{"folder-uuid" => folder_uuid}, socket) do
    folder = loaded_folder(socket, folder_uuid)

    {:noreply,
     socket
     |> assign(:editing_folder_description, folder_uuid)
     |> assign(:folder_description_text, (folder && folder.description) || "")}
  end

  def handle_event("folder_description_input", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "folder_description_input")}
  end

  def handle_event("folder_description_input", %{"description" => description}, socket) do
    {:noreply, assign(socket, :folder_description_text, description)}
  end

  def handle_event("cancel_edit_folder_description", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_folder_description, nil)
     |> assign(:folder_description_text, "")}
  end

  def handle_event("save_folder_description", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "save_folder_description")}
  end

  def handle_event(
        "save_folder_description",
        %{"folder_uuid" => folder_uuid, "description" => description},
        socket
      ) do
    folder = loaded_folder(socket, folder_uuid)
    scope = scope_folder_id(socket)
    # Blank/whitespace-only clears the description (stored as nil).
    trimmed = String.trim(description)
    value = if trimmed == "", do: nil, else: trimmed

    if folder do
      case Storage.update_folder(folder, %{description: value}, scope) do
        {:ok, updated} ->
          parent_uuid = current_folder_uuid(socket)

          socket =
            socket
            |> assign(:editing_folder_description, nil)
            |> assign(:folder_description_text, "")
            # Reload the listing so the grid card / list row reflects the new
            # description immediately (they render from `@folders`, not the
            # tree), plus the tree.
            |> assign(:folders, Storage.list_folders(parent_uuid, scope, lib_opts(socket)))
            |> assign(:folder_tree, Storage.list_folder_tree(scope, lib_opts(socket)))

          # Refresh the header's folder if we're editing the one we're inside.
          socket =
            if socket.assigns[:current_folder] &&
                 to_string(socket.assigns.current_folder.uuid) == to_string(folder_uuid),
               do: assign(socket, :current_folder, updated),
               else: socket

          {:noreply, socket}

        {:error, :out_of_scope} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Cannot edit a folder outside the allowed scope")
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to save folder description"))}
      end
    else
      {:noreply,
       socket
       |> assign(:editing_folder_description, nil)
       |> assign(:folder_description_text, "")}
    end
  end

  # ── In-folder header editor ───────────────────────────────────────────
  # Edits the current folder's name AND description together from the
  # header you see after opening a folder. Separate from the grid/list
  # card editors above (which only touch the description), so adding a
  # name field here doesn't disturb those.
  def handle_event("start_edit_folder_header", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "start_edit_folder_header")}
  end

  def handle_event("start_edit_folder_header", %{"folder-uuid" => folder_uuid}, socket) do
    folder = loaded_folder(socket, folder_uuid)

    {:noreply,
     socket
     |> assign(:editing_folder_header, folder_uuid)
     |> assign(:folder_header_name, (folder && folder.name) || "")
     |> assign(:folder_header_description, (folder && folder.description) || "")
     # Load the cover/logo previews up front (unconditionally) so the editor
     # shows them even when their show toggles are off — navigation gates these
     # on the toggles, so they may be nil when the editor opens.
     |> assign_folder_image(:folder_cover, folder && folder_image_data(folder.cover_file_uuid))
     |> assign_folder_image(:folder_logo, folder && folder_image_data(folder.logo_file_uuid))}
  end

  def handle_event("folder_header_input", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "folder_header_input")}
  end

  def handle_event("folder_header_input", params, socket) do
    {:noreply,
     socket
     |> assign(:folder_header_name, params["name"] || socket.assigns.folder_header_name)
     |> assign(
       :folder_header_description,
       params["description"] || socket.assigns.folder_header_description
     )}
  end

  def handle_event("cancel_edit_folder_header", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_folder_header, nil)
     |> assign(:folder_header_name, "")
     |> assign(:folder_header_description, "")}
  end

  # Open the media picker (scoped to the open folder) to choose/upload the
  # header background (cover) or the icon (logo).
  def handle_event("open_cover_picker", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "open_cover_picker")}
  end

  def handle_event("open_cover_picker", _params, socket) do
    {:noreply, socket |> assign(:image_picker_target, "cover") |> assign(:selecting_cover, true)}
  end

  def handle_event("open_logo_picker", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "open_logo_picker")}
  end

  def handle_event("open_logo_picker", _params, socket) do
    {:noreply, socket |> assign(:image_picker_target, "logo") |> assign(:selecting_cover, true)}
  end

  # Clear the folder's cover / logo. The image stays in the folder as a normal
  # asset — only the header reference is removed.
  def handle_event("remove_folder_cover", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "remove_folder_cover")}
  end

  def handle_event("remove_folder_cover", %{"folder-uuid" => folder_uuid}, socket) do
    update_header_field(socket, folder_uuid, %{cover_file_uuid: nil})
  end

  def handle_event("remove_folder_logo", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "remove_folder_logo")}
  end

  def handle_event("remove_folder_logo", %{"folder-uuid" => folder_uuid}, socket) do
    update_header_field(socket, folder_uuid, %{logo_file_uuid: nil})
  end

  # Header size (small / medium / large) — affects the hero height.
  def handle_event("set_header_size", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "set_header_size")}
  end

  def handle_event("set_header_size", %{"size" => size, "folder-uuid" => folder_uuid}, socket)
      when size in ~w(small medium large) do
    update_header_field(socket, folder_uuid, %{header_size: size})
  end

  # Ignore an out-of-whitelist header size instead of crashing.
  def handle_event("set_header_size", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_header_option", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "toggle_header_option")}
  end

  # Toggle a header element's visibility (title / icon / creator / date /
  # file_count / description / background).
  def handle_event(
        "toggle_header_option",
        %{"option" => option, "folder-uuid" => folder_uuid},
        socket
      ) do
    field = header_option_field(option)
    folder = field && loaded_folder(socket, folder_uuid)

    if folder do
      update_header_field(socket, folder_uuid, %{field => !Map.get(folder, field, true)})
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_folder_header", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "save_folder_header")}
  end

  def handle_event(
        "save_folder_header",
        %{"folder_uuid" => folder_uuid, "name" => name, "description" => description},
        socket
      ) do
    folder = loaded_folder(socket, folder_uuid)
    scope = scope_folder_id(socket)
    trimmed_name = String.trim(name)
    trimmed_desc = String.trim(description)
    desc_value = if trimmed_desc == "", do: nil, else: trimmed_desc

    cond do
      is_nil(folder) ->
        {:noreply, reset_folder_header_edit(socket)}

      trimmed_name == "" ->
        {:noreply, put_flash(socket, :error, gettext("Folder name can't be blank"))}

      true ->
        save_folder_header(socket, folder, folder_uuid, scope, trimmed_name, desc_value)
    end
  end

  def handle_event("change_folder_color", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "change_folder_color")}
  end

  def handle_event(
        "change_folder_color",
        %{"folder-uuid" => folder_uuid, "color" => color},
        socket
      ) do
    folder = Storage.get_folder(folder_uuid)

    scope = scope_folder_id(socket)

    if folder do
      case Storage.update_folder(folder, %{color: color}, scope) do
        {:ok, _} ->
          parent_uuid = current_folder_uuid(socket)

          {:noreply,
           socket
           |> assign(:folders, Storage.list_folders(parent_uuid, scope, lib_opts(socket)))
           |> assign(:folder_tree, Storage.list_folder_tree(scope, lib_opts(socket)))}

        {:error, :out_of_scope} ->
          {:noreply,
           put_flash(socket, :error, gettext("Cannot change folder outside the allowed scope"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to change color"))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_folder_expand", %{"folder-uuid" => folder_uuid}, socket) do
    expanded = socket.assigns.expanded_folders

    expanded =
      if MapSet.member?(expanded, folder_uuid),
        do: MapSet.delete(expanded, folder_uuid),
        else: MapSet.put(expanded, folder_uuid)

    socket = assign(socket, :expanded_folders, expanded)
    {:noreply, persist_tree_state(socket)}
  end

  def handle_event("toggle_select_mode", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "toggle_select_mode")}
  end

  def handle_event("toggle_select_mode", _params, socket) do
    if socket.assigns.select_mode do
      {:noreply, exit_select_mode(socket)}
    else
      {:noreply, assign(socket, :select_mode, true)}
    end
  end

  # Esc leaves select mode from anywhere, mirroring the toolbar's Cancel — the
  # window-keydown is only attached while select mode is on (see the heex).
  def handle_event("exit_select_mode", _params, socket) do
    {:noreply, exit_select_mode(socket)}
  end

  # Long-press on a card (from the MediaDragDrop JS hook) enters select mode and
  # selects the held item.
  def handle_event("long_press_select", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "long_press_select")}
  end

  def handle_event("long_press_select", %{"type" => "file", "uuid" => uuid}, socket) do
    {:noreply,
     socket
     |> assign(:select_mode, true)
     |> assign(:selected_files, MapSet.put(socket.assigns.selected_files, uuid))}
  end

  # Without folder actions a folder is never selected (see `selectable_on_screen/1`).
  def handle_event(
        "long_press_select",
        %{"type" => "folder"},
        %{assigns: %{folder_actions: false}} = socket
      ),
      do: {:noreply, log_refused(socket, "long_press_select", "folder actions are off")}

  def handle_event("long_press_select", %{"type" => "folder", "uuid" => uuid}, socket) do
    {:noreply,
     socket
     |> assign(:select_mode, true)
     |> assign(:selected_folders, MapSet.put(socket.assigns.selected_folders, uuid))}
  end

  # A picker's click picks (see `pick/2`) and opens nothing.
  def handle_event(
        "click_file",
        %{"file-uuid" => file_uuid},
        %{assigns: %{picker: true}} = socket
      ) do
    {:noreply, pick(socket, file_uuid)}
  end

  # A double click in a `:single` picker picks that file and confirms, file
  # dialog style (MediaDragDrop sends it). A double click elsewhere is just
  # two clicks.
  def handle_event(
        "pick_quick_confirm",
        %{"file-uuid" => file_uuid},
        %{assigns: %{picker: true, pick_mode: :single}} = socket
      ) do
    socket = pick(socket, file_uuid)

    cond do
      socket.assigns.picked != [file_uuid] -> {:noreply, socket}
      picker_busy?(socket) -> {:noreply, log_refused(socket, "pick_quick_confirm", "uploading")}
      true -> {:noreply, confirm_pick(socket)}
    end
  end

  def handle_event("pick_quick_confirm", _params, socket), do: {:noreply, socket}

  # Confirm and Cancel are disabled while an upload is on its way (see
  # `upload_in_progress?/1`); refused here too.
  def handle_event(event, _params, %{assigns: %{picker: true}} = socket)
      when event in ~w(pick_confirm pick_cancel) do
    cond do
      picker_busy?(socket) -> {:noreply, log_refused(socket, event, "an upload is on its way")}
      event == "pick_confirm" -> {:noreply, confirm_pick(socket)}
      true -> {:noreply, report_once(socket, :pick_cancelled)}
    end
  end

  def handle_event(event, _params, socket) when event in ~w(pick_confirm pick_cancel),
    do: {:noreply, socket}

  # A tile's eye (a picker's click picks, so its viewer opens from here). It
  # opens the viewer on a file of the page and leaves the pick alone; prev /
  # next step through the page it is on (`locate_file/2`).
  def handle_event(
        "view_file",
        %{"file-uuid" => file_uuid},
        %{assigns: %{picker: true}} = socket
      ) do
    case locate_file(socket, file_uuid) do
      {file, siblings} -> {:noreply, open_viewer(socket, file, siblings) |> notify_viewer_nav()}
      nil -> {:noreply, socket}
    end
  end

  # Another browser has no eye: its click opens the viewer (or selects).
  def handle_event("view_file", _params, socket),
    do: {:noreply, log_refused(socket, "view_file", "the browser is not a picker")}

  # The picker viewer's Select / Deselect for the file it shows: a picked
  # file comes out of the pick (in `:single` too, which a tile's click never
  # does), any other is picked as a click picks it, checked the same way.
  def handle_event(
        "viewer_pick",
        %{"file-uuid" => file_uuid},
        %{assigns: %{picker: true}} = socket
      ) do
    if file_uuid in socket.assigns.picked do
      {:noreply, put_pick(socket, List.delete(socket.assigns.picked, file_uuid))}
    else
      {:noreply, pick(socket, file_uuid)}
    end
  end

  def handle_event("viewer_pick", _params, socket), do: {:noreply, socket}

  # In selection mode, clicks toggle the file in/out and stay in selection
  # mode (the toolbar's "Select" button is how callers reach bulk-select).
  # Otherwise open the in-place modal viewer for that file — admin context
  # gets the same popup, plus an "Open details page" button in the sidebar
  # (see `details_path`) for the full /admin/media/:uuid page.
  def handle_event("click_file", %{"file-uuid" => file_uuid}, socket) do
    if socket.assigns.select_mode do
      {:noreply, do_toggle_file(socket, file_uuid)}
    else
      # `locate_file/2` also finds files inside expanded stacks, and hands
      # back the list prev/next should step through. A miss (stale click
      # against a since-reloaded page) leaves the viewer alone rather than
      # opening it empty.
      case locate_file(socket, file_uuid) do
        {file, siblings} -> {:noreply, open_viewer(socket, file, siblings) |> notify_viewer_nav()}
        nil -> {:noreply, socket}
      end
    end
  end

  def handle_event("close_viewer", _params, socket) do
    {:noreply, open_viewer(socket, nil) |> notify_viewer_nav()}
  end

  def handle_event("open_image_editor", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "open_image_editor")}
  end

  def handle_event("open_image_editor", %{"file-uuid" => file_uuid}, socket) do
    {:noreply, open_image_editor(socket, file_uuid)}
  end

  def handle_event("close_image_editor", _params, socket) do
    {:noreply, assign(socket, :image_editor_file, nil)}
  end

  # Single keydown router so we can handle multiple keys without stacking
  # phx-window-keydown directives (only one fires per element).
  def handle_event("viewer_keydown", %{"key" => "Escape"}, socket) do
    {:noreply, open_viewer(socket, nil) |> notify_viewer_nav()}
  end

  def handle_event("viewer_keydown", %{"key" => "ArrowLeft"}, socket) do
    {:noreply, step_viewer(socket, :prev) |> notify_viewer_nav()}
  end

  def handle_event("viewer_keydown", %{"key" => "ArrowRight"}, socket) do
    {:noreply, step_viewer(socket, :next) |> notify_viewer_nav()}
  end

  def handle_event("viewer_keydown", _params, socket), do: {:noreply, socket}

  def handle_event("step_viewer", %{"dir" => "prev"}, socket) do
    {:noreply, step_viewer(socket, :prev) |> notify_viewer_nav()}
  end

  def handle_event("step_viewer", %{"dir" => "next"}, socket) do
    {:noreply, step_viewer(socket, :next) |> notify_viewer_nav()}
  end

  # The gallery settled on a picture (it slides there itself, and says so
  # afterwards). Only a file of the list the viewer is stepping through. The
  # hook asks again when it sees no sign the server followed, so naming the
  # file already open is answered with nothing (no second URL announcement).
  def handle_event("gallery_go", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    case socket.assigns[:viewer_file] do
      %{file_uuid: ^uuid} ->
        {:noreply, socket}

      _ ->
        case Enum.find(socket.assigns[:viewer_siblings] || [], &(&1.file_uuid == uuid)) do
          nil -> {:noreply, socket}
          file -> {:noreply, socket |> open_viewer(file) |> notify_viewer_nav()}
        end
    end
  end

  # Etcher annotation events + composer lifecycle are owned by the
  # MediaCanvasViewer child LiveComponent embedded in the viewer
  # modal — events fire there, not here. See
  # `lib/phoenix_kit_web/components/media_canvas_viewer.ex`.

  def handle_event("toggle_select_folder", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "toggle_select_folder")}
  end

  def handle_event("toggle_select_folder", %{"folder-uuid" => folder_uuid}, socket) do
    selected = socket.assigns.selected_folders

    selected =
      if MapSet.member?(selected, folder_uuid),
        do: MapSet.delete(selected, folder_uuid),
        else: MapSet.put(selected, folder_uuid)

    {:noreply, assign(socket, :selected_folders, selected)}
  end

  def handle_event("toggle_select", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "toggle_select")}
  end

  def handle_event("toggle_select", %{"file-uuid" => file_uuid}, socket) do
    selected = socket.assigns.selected_files

    selected =
      if MapSet.member?(selected, file_uuid),
        do: MapSet.delete(selected, file_uuid),
        else: MapSet.put(selected, file_uuid)

    {:noreply, assign(socket, :selected_files, selected)}
  end

  def handle_event("select_all", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "select_all")}
  end

  def handle_event("select_all", _params, socket) do
    {files, folders} = selectable_on_screen(socket)

    {:noreply,
     socket
     |> assign(:selected_files, files)
     |> assign(:selected_folders, folders)}
  end

  def handle_event("box_select", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "box_select")}
  end

  # A box drawn over the cards (MediaDragDrop): what it touched becomes the
  # selection — added to it with Shift or Cmd/Ctrl held — and select mode
  # comes on, so the bulk actions are a click away. Only what is on screen
  # can be picked, the same set Select all covers; a box over nothing,
  # without the modifier, clears the selection.
  def handle_event("box_select", params, socket) do
    {on_screen_files, on_screen_folders} = selectable_on_screen(socket)
    files = params |> Map.get("files", []) |> box_uuids(on_screen_files) |> MapSet.new()
    folders = params |> Map.get("folders", []) |> box_uuids(on_screen_folders) |> MapSet.new()

    {files, folders} =
      if params["additive"] == true do
        {MapSet.union(socket.assigns.selected_files, files),
         MapSet.union(socket.assigns.selected_folders, folders)}
      else
        {files, folders}
      end

    picked? = MapSet.size(files) + MapSet.size(folders) > 0

    {:noreply,
     socket
     |> assign(:selected_files, files)
     |> assign(:selected_folders, folders)
     |> assign(:select_mode, socket.assigns.select_mode or picked?)}
  end

  def handle_event("deselect_all", _params, socket) do
    # "Clear" only empties the selection — the toolbar's separate Cancel
    # button (toggle_select_mode) is what exits selection mode.
    {:noreply,
     socket
     |> assign(:selected_files, MapSet.new())
     |> assign(:selected_folders, MapSet.new())}
  end

  def handle_event("show_move_modal", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "show_move_modal")}
  end

  def handle_event("show_move_modal", _params, socket) do
    # Bulk move only opens when something is selected. The Move button is
    # disabled with an empty selection; this guards the handler too so a
    # stray event can't pop an empty modal.
    if MapSet.size(socket.assigns.selected_files) +
         MapSet.size(socket.assigns.selected_folders) > 0 do
      {:noreply, open_move_modal(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_move_folder", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "toggle_move_folder")}
  end

  # Expand/collapse a folder in the Move modal's directory tree.
  def handle_event("toggle_move_folder", %{"folder-uuid" => uuid}, socket) do
    expanded = socket.assigns.move_expanded

    expanded =
      if MapSet.member?(expanded, uuid),
        do: MapSet.delete(expanded, uuid),
        else: MapSet.put(expanded, uuid)

    {:noreply, assign(socket, :move_expanded, expanded)}
  end

  def handle_event("close_move_modal", _params, socket) do
    # Clear the transient single-item selection when the cancel came from
    # a kebab-triggered move. Bulk-mode users may want their selection to
    # persist across a cancel (so they can retry without reselecting), so
    # only clear when select_mode is off — which is also when the kebabs
    # are visible, since we hide them in select_mode.
    socket = assign(socket, :show_move_modal, false)

    socket =
      if socket.assigns.select_mode do
        socket
      else
        socket
        |> assign(:selected_files, MapSet.new())
        |> assign(:selected_folders, MapSet.new())
      end

    {:noreply, socket}
  end

  # Single-file move from kebab — pre-populates the selection with just
  # this file and opens the move modal. Reuses the bulk
  # `move_selected_to_folder` flow without entering select_mode.
  def handle_event("prepare_move_file", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "prepare_move_file")}
  end

  def handle_event("prepare_move_file", %{"file-uuid" => file_uuid}, socket) do
    {:noreply,
     socket
     |> assign(:selected_files, MapSet.new([file_uuid]))
     |> assign(:selected_folders, MapSet.new())
     |> open_move_modal()}
  end

  # Single-folder move from kebab — symmetric to `prepare_move_file`.
  def handle_event("prepare_move_folder", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "prepare_move_folder")}
  end

  def handle_event("prepare_move_folder", %{"folder-uuid" => folder_uuid}, socket) do
    {:noreply,
     socket
     |> assign(:selected_files, MapSet.new())
     |> assign(:selected_folders, MapSet.new([folder_uuid]))
     |> open_move_modal()}
  end

  def handle_event("move_selected_to_folder", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "move_selected_to_folder")}
  end

  # The drag-and-drop batch drop used to send `folder_uuid` (the move
  # dialog's `phx-value-folder-uuid` arrives as `folder-uuid`), and with no
  # clause for it the LiveView crashed and the page reloaded with nothing
  # moved. The hook sends `folder-uuid` now; a page still running the old
  # script lands here instead of crashing.
  def handle_event("move_selected_to_folder", %{"folder_uuid" => folder_uuid} = params, socket)
      when not is_map_key(params, "folder-uuid") do
    handle_event("move_selected_to_folder", %{"folder-uuid" => folder_uuid}, socket)
  end

  def handle_event("move_selected_to_folder", %{"folder-uuid" => folder_uuid}, socket) do
    scope = scope_folder_id(socket)
    # "root" in a scoped browser is the scope folder, not nil — same fix as
    # the drag-drop `move_file_to_folder` handler above. Without this,
    # picking the home/root option in the move modal silently failed for
    # files (`:out_of_scope`) and silently *escaped* the scope for folders
    # (the scoped `update_folder` skips the parent-scope check when the
    # new parent is nil).
    target = if folder_uuid == "", do: scope, else: folder_uuid

    {files, folders} = shown_selection(socket)

    file_count =
      Enum.count(files, fn file ->
        from = appearance_folder(socket, file)

        case Storage.move_file_between_folders(file.uuid, from, target, scope) do
          {:ok, _} -> true
          _ -> false
        end
      end)

    folder_count =
      Enum.count(folders, fn folder ->
        sel_folder_uuid = to_string(folder.uuid)

        # A trashed folder is not moved out of the trash by being dropped
        # somewhere — it comes back through Restore, which brings its
        # contents with it. Reparenting it here left it trashed, exactly
        # the silent no-op a trashed FILE used to get.
        cond do
          sel_folder_uuid == target -> false
          not is_nil(folder.trashed_at) -> false
          true -> match?({:ok, _}, Storage.update_folder(folder, %{parent_uuid: target}, scope))
        end
      end)

    {:noreply,
     socket
     |> assign(:select_mode, false)
     |> assign(:selected_files, MapSet.new())
     |> assign(:selected_folders, MapSet.new())
     |> assign(:show_move_modal, false)
     |> put_flash(
       :info,
       ngettext("%{count} item moved", "%{count} items moved", file_count + folder_count)
     )
     |> reload_folder_lists()
     |> reload_current_page()}
  end

  def handle_event("delete_selected", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "delete_selected")}
  end

  def handle_event("delete_selected", _params, socket) do
    scope = scope_folder_id(socket)
    {files, folders} = shown_selection(socket)

    # Files the removal guard kept (`removal_except`) are not attempted, let
    # alone counted as failures: `removal_execute` reports them as "kept: in
    # use", and a result here would call the same files "could not be removed".
    files = Enum.reject(files, &(&1.uuid in removal_except(socket)))

    # Each result is counted: the flash used to report every selected item
    # as deleted, whatever happened to it.
    file_results =
      if socket.assigns.filter_trash do
        # Permanent delete from trash (with scope guard). The status check is
        # a belt-and-braces guard: only files actually in the trash may be
        # destroyed, no matter how a uuid ended up in the selection.
        Enum.map(files, fn file ->
          if file.status == "trashed" && Storage.within_scope?(file.folder_uuid, scope) &&
               (is_nil(removal_only(socket)) or file.uuid in removal_only(socket)),
             do: Storage.delete_file_completely(file),
             else: {:error, :not_removable}
        end)
      else
        # Soft-delete to trash — folder-aware: a file only LINKED into the
        # viewed folder is unlinked, not trashed for its owner.
        Enum.map(files, fn file ->
          viewed = appearance_folder(socket, file)

          if removable_here?(file, viewed, scope),
            do: Storage.remove_file_from_folder(file, viewed),
            else: {:error, :not_removable}
        end)
      end

    # Folders now have trash support (V119) — recursive trash outside
    # the trash view, recursive permanent delete inside. Both operations
    # cover the folder's entire subtree (descendant folders + files).
    folder_results = delete_selected_folders(socket, folders, scope)

    {done, failed} =
      Enum.split_with(file_results ++ folder_results, &match?({:ok, _}, ok_tuple(&1)))

    socket =
      socket
      |> assign(:select_mode, false)
      |> assign(:selected_files, MapSet.new())
      |> assign(:selected_folders, MapSet.new())
      |> reload_folder_lists()
      |> reload_current_page()

    socket =
      if done != [] do
        put_flash(
          socket,
          :info,
          deleted_selection_message(length(done), socket.assigns.filter_trash)
        )
      else
        socket
      end

    socket =
      if failed != [] do
        Logger.warning(
          "[MediaBrowser] delete_selected: #{length(failed)} not removed: " <>
            inspect(Enum.uniq(failed), limit: 5)
        )

        put_flash(socket, :error, not_removed_message(failed))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("download_selected", _params, socket) do
    # Selection survives paging, stacks, and folder navigation, so resolve it
    # from the DB (scope-guarded, like delete_selected) instead of the
    # currently-rendered lists — an assigns-only lookup silently skipped
    # every selected file that wasn't on the visible page.
    scope = scope_folder_id(socket)
    repo = PhoenixKit.Config.get_repo()
    uuids = MapSet.to_list(socket.assigns.selected_files)

    files =
      from(f in Storage.File, where: f.uuid in ^uuids)
      |> repo.all()
      |> shown_only(socket)
      |> Enum.filter(&removable_here?(&1, appearance_folder(socket, &1), scope))
      |> enrich_files()
      |> Enum.map(fn f ->
        %{url: Map.get(f.urls, "original") || Map.get(f.urls, :original), name: f.filename}
      end)
      |> Enum.reject(&is_nil(&1.url))

    {:noreply, push_event(socket, "download_files", %{files: files})}
  end

  # Single-file delete via the per-row kebab menu. Mirrors `delete_selected`
  # for one file — soft-delete to trash when outside the trash view, permanent
  # delete when already inside it. Scope-guarded the same way.
  # Rotate a single file's saved orientation ±90 from the per-file kebab.
  # Same persistence as the viewer's rotate button — writes
  # metadata["rotation"] and broadcasts the thumbnail refresh — so the grid
  # reorients its thumbnail via the rotation_class CSS transform (no
  # re-encode, no open viewer needed). Images only; scope-guarded like the
  # other per-file mutations.
  def handle_event("rotate_file", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "rotate_file")}
  end

  def handle_event("rotate_file", %{"file-uuid" => file_uuid, "dir" => dir}, socket) do
    delta = if dir == "left", do: -90, else: 90
    scope = scope_folder_id(socket)

    # Rotation is written on the FILE, so it shows in every folder holding
    # it — the owner's included. The file's home must be in scope, not only
    # its appearance here: a file merely linked in from outside (a content
    # duplicate another user uploaded first) is theirs to rotate, not ours.
    with %Storage.File{} = file <- Storage.get_file(file_uuid),
         true <- Storage.within_scope?(file.folder_uuid, scope) do
      # Turned from the rotation the row holds NOW, and merged into the
      # metadata it holds now: two quick clicks add up, and a title saved in
      # between survives.
      rotate = fn metadata ->
        current = normalized_rotation(Map.get(metadata, "rotation"))
        Map.put(metadata, "rotation", Integer.mod(current + delta, 360))
      end

      case Storage.update_file_metadata(file, rotate) do
        {:ok, _} ->
          Storage.broadcast_file_thumbnail_updated(file_uuid)
          {:noreply, refresh_processed_file(socket, file_uuid, viewer: false)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not rotate the image."))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("delete_file", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "delete_file")}
  end

  def handle_event("delete_file", %{"file-uuid" => file_uuid}, socket) do
    scope = scope_folder_id(socket)
    repo = PhoenixKit.Config.get_repo()
    file = repo.get(Storage.File, file_uuid)

    viewed = file && appearance_folder(socket, file)

    if file && removable_here?(file, viewed, scope) do
      # Same guards as delete_selected: permanent deletion only for files
      # actually in the trash — by the row's status, not by the view, since the
      # viewer can open a trashed file from a link outside the trash view (the
      # row could have been restored from another session since this view
      # rendered) AND whose home is in scope —
      # destroying the record and its bytes reaches every folder holding
      # the file, so appearing here (a link from outside) is not enough. A
      # linked file in this folder's trash is unlinked instead.
      cond do
        # A picker deletes nothing for good, from whatever view: the
        # permanent branch below is chosen by the row, not by the view.
        socket.assigns[:picker] == true and file.status == "trashed" ->
          {:noreply, log_refused(socket, "delete_file", "a picker deletes nothing for good")}

        file.status == "trashed" and Storage.within_scope?(file.folder_uuid, scope) ->
          # A file that something else still uses is kept, and the message says
          # so; the viewer stays open on it.
          case permanent_delete_flash(Storage.delete_file_completely(file)) do
            {:info, flash} ->
              {:noreply, removed(socket, file_uuid, flash)}

            {:error, message} ->
              {:noreply, socket |> put_flash(:error, message) |> reload_current_page()}
          end

        true ->
          result = Storage.remove_file_from_folder(file, viewed)

          {:noreply,
           socket
           |> unpick_removed(file_uuid, result)
           |> removed(file_uuid, removal_flash(result))}
      end
    else
      # Nothing in this browser shows that file: a stale row, a uuid from
      # another listing, a forged one. Refusing is right; refusing in
      # silence is not — the button was pressed and the screen has to
      # answer for it.
      {:noreply, put_flash(socket, :error, gettext("Failed to remove file"))}
    end
  end

  # Single-file download via the per-row kebab menu. Pushes the same
  # `download_files` event the JS hook listens for, with one entry. The heex
  # only renders the menu item when an "original" URL is present, so a
  # missing URL here is a stale assigns / race condition — silent no-op is
  # the right call.
  def handle_event("download_file", %{"file-uuid" => file_uuid}, socket) do
    # `locate_file/2` also covers files inside expanded stacks — the stack
    # card renders the same Download kebab, and an uploaded_files-only lookup
    # silently no-oped it.
    file =
      case locate_file(socket, file_uuid) do
        {file, _list} -> file
        nil -> nil
      end

    url = file && (Map.get(file.urls || %{}, "original") || Map.get(file.urls || %{}, :original))

    if url do
      {:noreply,
       push_event(socket, "download_files", %{files: [%{url: url, name: file.filename}]})}
    else
      {:noreply, socket}
    end
  end

  # Featured image — see the moduledoc's `:featured` attr. The browser
  # never writes anything itself: it tells the host and moves its own
  # badge/kebab state so the click feels instant even though the host's
  # persistence (and any `send_update` correction) is still in flight.
  # No-op when the host never opted in (`:featured` is `nil`) — the kebab
  # item and viewer button are both gated on it, so this only fires from
  # a stale client render.
  def handle_event("set_featured", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "set_featured")}
  end

  def handle_event("set_featured", %{"file-uuid" => file_uuid}, socket) do
    {:noreply, notify_featured(socket, file_uuid)}
  end

  def handle_event("unset_featured", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "unset_featured")}
  end

  def handle_event("unset_featured", _params, socket) do
    {:noreply, notify_featured(socket, nil)}
  end

  def handle_event("toggle_trash_filter", _params, socket) do
    filter_trash = !socket.assigns.filter_trash
    # Trash is scoped to the current folder's subtree (see trash_scope/1);
    # the active-file reload below uses the plain embedded scope.
    t_scope = trash_scope(socket)

    {files, total_count} =
      if filter_trash do
        load_trashed_files(t_scope, 1, socket.assigns.per_page, lib_opts(socket))
      else
        scope = scope_folder_id(socket)
        folder_uuid = current_folder_uuid(socket)
        load_scoped_files(scope, 1, socket.assigns.per_page, folder_uuid, "", list_extra(socket))
      end

    # In trash view `@folders` becomes the trashed-folder list so the
    # grid/list rows render trashed folders alongside trashed files.
    # Leaving trash must RELOAD the active folder set — the assign still
    # holds the trashed list at that point, which left trashed folder
    # cards on screen in the normal view.
    folders =
      if filter_trash,
        do: Storage.list_trashed_folders(t_scope, lib_opts(socket)),
        else:
          Storage.list_folders(
            current_folder_uuid(socket),
            scope_folder_id(socket),
            lib_opts(socket)
          )

    {:noreply,
     socket
     |> assign(:filter_trash, filter_trash)
     |> assign(:filter_orphaned, false)
     |> assign(:folders, folders)
     |> assign(:uploaded_files, files)
     |> assign(:total_count, total_count)
     |> assign(:total_pages, Pagination.total_pages(total_count, socket.assigns.per_page))
     |> assign(:current_page, 1)
     # Trash and normal view show disjoint rows, so a carried-over selection
     # is invisible — and dangerous: delete_selected keys its permanent
     # branch off the view, so active files selected before the switch
     # would be permanently destroyed.
     |> assign(:selected_files, MapSet.new())
     |> assign(:selected_folders, MapSet.new())
     |> assign(:trash_count, full_trash_count(t_scope, lib_opts(socket)))}
  end

  # One row at a time, from the trash view's own menu. `restore_selected`
  # below has always existed and does the same for a selection; neither was
  # reachable, so a trashed file's only way back was its details page.
  def handle_event("restore_file", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "restore_file")}
  end

  def handle_event("restore_file", %{"file-uuid" => file_uuid}, socket) do
    scope = scope_folder_id(socket)
    file = Storage.get_file(file_uuid)

    if file && Storage.within_scope?(file.folder_uuid, scope) do
      case Storage.restore_file(file) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("File restored"))
           |> close_viewer_on(file_uuid)
           |> reload_folder_lists()
           |> reload_current_page()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to restore file"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Failed to restore file"))}
    end
  end

  def handle_event("restore_folder", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "restore_folder")}
  end

  def handle_event("restore_folder", %{"folder-uuid" => folder_uuid}, socket) do
    scope = scope_folder_id(socket)

    with %Storage.Folder{} = folder <- Storage.get_folder(folder_uuid),
         {:ok, _} <- Storage.restore_folder(folder, scope) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Folder restored"))
       |> reload_folder_lists()
       |> reload_current_page()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Failed to restore folder"))}
    end
  end

  def handle_event("restore_selected", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "restore_selected")}
  end

  def handle_event("restore_selected", _params, socket) do
    scope = scope_folder_id(socket)
    {files, folders} = shown_selection(socket)

    restored_files =
      Enum.reduce(files, 0, fn file, acc ->
        if Storage.within_scope?(file.folder_uuid, scope) do
          case Storage.restore_file(file) do
            {:ok, _} -> acc + 1
            _ -> acc
          end
        else
          acc
        end
      end)

    restored_folders =
      Enum.reduce(folders, 0, fn folder, acc ->
        if Storage.within_scope?(folder.uuid, scope) do
          case Storage.restore_folder(folder, scope) do
            {:ok, _} -> acc + 1
            _ -> acc
          end
        else
          acc
        end
      end)

    total = restored_files + restored_folders

    {:noreply,
     socket
     |> assign(:select_mode, false)
     |> assign(:selected_files, MapSet.new())
     |> assign(:selected_folders, MapSet.new())
     |> put_flash(:info, ngettext("%{count} item restored", "%{count} items restored", total))
     |> reload_folder_lists()
     |> reload_current_page()}
  end

  def handle_event("empty_trash", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "empty_trash")}
  end

  def handle_event("empty_trash", _params, socket) do
    # Scoped to the folder you're viewing the Trash of — emptying a folder's
    # trash must not purge sibling roots' trashed files.
    {:ok, count} =
      Storage.empty_trash(trash_scope(socket), [
        {:except, removal_except(socket)} | [{:only, removal_only(socket)} | lib_opts(socket)]
      ])

    {:noreply,
     socket
     # What the removal guard kept stays in the trash, and in view.
     |> assign(:filter_trash, removal_except(socket) != [])
     |> put_flash(
       :info,
       ngettext("%{count} file permanently deleted", "%{count} files permanently deleted", count)
     )
     |> reload_current_page()}
  end

  def handle_event("toggle_orphan_filter", _params, socket) do
    filter_orphaned = !socket.assigns.filter_orphaned

    if controlled_mode?(socket) do
      folder_uuid = current_folder_uuid(socket)
      q = socket.assigns.search_query

      send(
        self(),
        {__MODULE__, socket.assigns.id,
         {:navigate,
          %{folder: folder_uuid, q: q, page: 1, filter_orphaned: filter_orphaned, view: nil}}}
      )

      {:noreply, socket}
    else
      per_page = socket.assigns.per_page
      scope = scope_folder_id(socket)
      folder_uuid = current_folder_uuid(socket)
      search = socket.assigns.search_query

      {files, total_count} =
        if filter_orphaned do
          load_orphaned_files(1, per_page, lib_opts(socket))
        else
          load_scoped_files(scope, 1, per_page, folder_uuid, search, list_extra(socket))
        end

      orphaned_count =
        if filter_orphaned,
          do: total_count,
          else: Storage.count_orphaned_files(scope_folder_id(socket), lib_opts(socket))

      {:noreply,
       socket
       |> assign(:filter_orphaned, filter_orphaned)
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_pages, Pagination.total_pages(total_count, per_page))
       |> assign(:total_count, total_count)
       |> assign(:orphaned_count, orphaned_count)}
    end
  end

  def handle_event("delete_all_orphaned", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "delete_all_orphaned")}
  end

  def handle_event("delete_all_orphaned", _params, socket) do
    orphan_uuids = Storage.find_orphaned_files(lib_opts(socket)) |> Enum.map(& &1.uuid)
    Storage.queue_file_cleanup(orphan_uuids)

    {:noreply,
     put_flash(
       socket,
       :info,
       ngettext(
         "%{count} orphaned file will be moved to the trash",
         "%{count} orphaned files will be moved to the trash",
         length(orphan_uuids)
       )
     )}
  end

  def handle_event("toggle_upload", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "toggle_upload")}
  end

  def handle_event("toggle_upload", _params, socket) do
    {:noreply, assign(socket, :show_upload, !socket.assigns.show_upload)}
  end

  def handle_event("toggle_search", _params, socket) do
    {:noreply, assign(socket, :show_search, !socket.assigns.show_search)}
  end

  def handle_event("show_upload", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "show_upload")}
  end

  def handle_event("show_upload", _params, socket) do
    {:noreply, assign(socket, :show_upload, true)}
  end

  def handle_event("validate", _params, socket) do
    # Upload progress is handled via the progress: &handle_progress/3 callback.
    {:noreply, socket}
  end

  # ── Upload problems panel ─────────────────────────────────────────
  #
  # Every way an upload can fail to land ends up as a row here, by name and
  # with why — see `upload_problems/1`. Retry sends kept bytes back through
  # the same drain the original upload took (or, for a transfer the page
  # lost, asks the browser to re-send what it stashed); Discard lets go.

  def handle_event("retry_upload", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "retry_upload")}
  end

  def handle_event("retry_upload", %{"key" => key}, socket) do
    {:noreply, retry_upload_problems(socket, &(&1.key == key))}
  end

  def handle_event("retry_upload", _params, socket), do: {:noreply, socket}

  def handle_event("retry_all_uploads", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "retry_all_uploads")}
  end

  def handle_event("retry_all_uploads", _params, socket) do
    {:noreply, retry_upload_problems(socket, & &1.retry)}
  end

  def handle_event("discard_upload", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "discard_upload")}
  end

  def handle_event("discard_upload", %{"key" => key}, socket) do
    {:noreply, discard_upload_problems(socket, &(&1.key == key))}
  end

  def handle_event("discard_upload", _params, socket), do: {:noreply, socket}

  def handle_event("discard_all_uploads", _params, socket)
      when socket.assigns.readonly == true do
    {:noreply, log_readonly_blocked(socket, "discard_all_uploads")}
  end

  def handle_event("discard_all_uploads", _params, socket) do
    {:noreply, discard_upload_problems(socket, fn _ -> true end)}
  end

  # The UploadResume hook found files a previous page load stashed and never
  # heard back about: the transfer was cut short (a refresh, a closed tab, a
  # dropped connection). Listed like any other problem; Resume re-sends them.
  def handle_event("upload_resume_available", %{"items" => items}, socket)
      when is_list(items) do
    socket =
      items
      |> Enum.filter(&(is_map(&1) and is_binary(&1["key"])))
      |> Enum.reject(fn item ->
        Enum.any?(socket.assigns.upload_problems_session, &(&1[:client_key] == item["key"]))
      end)
      |> Enum.reduce(socket, fn item, acc ->
        add_upload_problem(acc, %{
          kind: :browser,
          client_name: if(is_binary(item["name"]), do: item["name"], else: "file"),
          client_size: item["size"],
          client_key: item["key"],
          retry: item["blob"] == true,
          reason:
            if(item["blob"] == true,
              do: gettext("The upload was cut short — the page was closed or refreshed."),
              else:
                gettext(
                  "The upload was cut short, and the file was too large to keep a copy of. Add it again."
                )
            )
        })
      end)

    {:noreply, socket}
  end

  def handle_event("upload_resume_available", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, socket.assigns.upload_name, ref)}
  end

  def handle_event("set_page", %{"page" => page_str}, socket) do
    page =
      case Integer.parse(page_str) do
        {n, _} when n > 0 -> n
        _ -> 1
      end

    # Trash and orphaned are not URL-addressable views (the nav contract only
    # carries folder/q/page/view), so page them locally even in controlled
    # mode — a {:navigate} round-trip would silently exit the view. The local
    # branch goes through `reload_current_page/1`, which keeps the trash arm
    # and the sort/type filters the old hand-rolled loader here dropped.
    local_only_view? = socket.assigns[:filter_trash] || socket.assigns.filter_orphaned

    if controlled_mode?(socket) and not local_only_view? do
      folder_uuid = current_folder_uuid(socket)
      q = socket.assigns.search_query
      file_view = socket.assigns.file_view

      send(
        self(),
        {__MODULE__, socket.assigns.id,
         {:navigate, %{folder: folder_uuid, q: q, page: page, view: file_view}}}
      )

      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:current_page, page)
       |> reload_current_page()}
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Navigation helpers
  # ──────────────────────────────────────────────────────────────

  defp do_toggle_file(socket, file_uuid) do
    selected = socket.assigns.selected_files

    selected =
      if MapSet.member?(selected, file_uuid),
        do: MapSet.delete(selected, file_uuid),
        else: MapSet.put(selected, file_uuid)

    assign(socket, :selected_files, selected)
  end

  # Leave select mode and drop any selection — shared by the toolbar Cancel
  # button and the Esc key.
  # Everything a selection can pick right now: the files rendered on screen
  # (`uploaded_files` AND, in stacks view, each expanded stack's own list —
  # the same duality as `locate_file/2`) and the folders listed.
  defp selectable_on_screen(socket) do
    stack_file_uuids =
      (socket.assigns[:stack_files] || %{})
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.file_uuid)

    files =
      MapSet.new(Enum.map(socket.assigns.uploaded_files, & &1.file_uuid) ++ stack_file_uuids)

    # Without folder actions a folder is never in a selection: every bulk
    # action on one (move, trash, delete) is a folder action.
    folders =
      if socket.assigns.folder_actions,
        do: socket.assigns.folders,
        else: []

    {files, MapSet.new(folders, & &1.uuid)}
  end

  defp box_uuids(list, allowed) when is_list(list) do
    Enum.filter(list, &(is_binary(&1) and MapSet.member?(allowed, &1)))
  end

  defp box_uuids(_other, _allowed), do: []

  defp exit_select_mode(socket) do
    socket
    |> assign(:select_mode, false)
    |> assign(:selected_files, MapSet.new())
    |> assign(:selected_folders, MapSet.new())
  end

  # Look up the clicked file's enriched map (filename, mime_type, size, urls,
  # …) inside the current page's uploaded_files list so the modal can render
  # without an extra DB roundtrip.
  # Rendered files live in TWO places: the current page's list
  # (`uploaded_files`) and, in stacks view, each expanded stack's own list
  # (`stack_files`, keyed by folder uuid). Resolve against both — searching
  # only `uploaded_files` silently no-oped every click on a file inside an
  # expanded stack, since the lookup missed and the viewer opened on `nil`.
  #
  # Returns the file *and* the list it came from, so the viewer's prev/next
  # steps through the right siblings (a stack's own files, not the page's).
  defp locate_file(socket, file_uuid) do
    stacks = Map.values(socket.assigns[:stack_files] || %{})

    Enum.find_value([socket.assigns.uploaded_files | stacks], fn list ->
      case Enum.find(list, fn f -> f.file_uuid == file_uuid end) do
        nil -> nil
        file -> {file, list}
      end
    end)
  end

  # Advance the modal viewer by one step through the list it was opened
  # from (see `locate_file/2`). Stops at the boundary (no wrap-around) so
  # the user knows they hit the edge instead of being silently teleported
  # to the other end.
  defp step_viewer(socket, direction) do
    current = socket.assigns.viewer_file
    list = socket.assigns[:viewer_siblings] || []

    with %{file_uuid: uuid} <- current,
         idx when is_integer(idx) <-
           Enum.find_index(list, fn f -> f.file_uuid == uuid end),
         next_idx <- if(direction == :prev, do: idx - 1, else: idx + 1),
         true <- next_idx >= 0 and next_idx < length(list),
         %{} = next_file <- Enum.at(list, next_idx) do
      open_viewer(socket, next_file)
    else
      _ -> socket
    end
  end

  # Opens / closes the modal viewer. The per-file content (canvas,
  # annotations, composer, sidebar with comments) lives in the
  # `MediaCanvasViewer` child LiveComponent embedded in the viewer
  # heex — it loads its own annotations on mount based on the file
  # we pass through `assigns[:file]`. MediaBrowser only owns the
  # modal open/close lifecycle and which file is currently shown.
  # `siblings` is the list prev/next steps through. Passing `nil` keeps the
  # list already in play — how `step_viewer/2` moves within it without
  # re-deciding which list the viewer belongs to.
  defp open_viewer(socket, file, siblings \\ nil)

  defp open_viewer(socket, nil, _siblings) do
    socket |> assign(:viewer_file, nil) |> assign(:viewer_siblings, [])
  end

  defp open_viewer(socket, %{file_uuid: _} = file, nil), do: assign(socket, :viewer_file, file)

  defp open_viewer(socket, %{file_uuid: _} = file, siblings) do
    socket |> assign(:viewer_file, file) |> assign(:viewer_siblings, siblings)
  end

  # In controlled mode, a viewer change patches `file` into the URL (via
  # the parent's url_sync hook) so a refresh reopens exactly this view —
  # folder AND file. The rest of the nav rides along unchanged; the hook's
  # feed-back lands in apply_nav_params' fast path, so no reload happens.
  # Uncontrolled hosts get the local state only, as before.
  # The viewer's own Move to trash / Restore / Delete forever: the file leaves
  # this view, so the viewer on it closes (a file viewed from another tile
  # stays open).
  defp close_viewer_on(socket, file_uuid) do
    case socket.assigns[:viewer_file] do
      %{file_uuid: ^file_uuid} -> socket |> open_viewer(nil) |> notify_viewer_nav()
      _ -> socket
    end
  end

  defp notify_viewer_nav(socket) do
    if controlled_mode?(socket) do
      viewer = socket.assigns[:viewer_file]
      emitted = viewer && viewer.file_uuid

      # Bounded: a host that never echoes `file` clears it on its first
      # nav-params update, but must not grow it until then.
      echoes = Enum.take((socket.assigns[:viewer_nav_echoes] || []) ++ [emitted], -20)
      socket = assign(socket, :viewer_nav_echoes, echoes)

      send(
        self(),
        {__MODULE__, socket.assigns.id,
         {:navigate,
          %{
            folder: current_folder_uuid(socket),
            q: socket.assigns.search_query,
            page: socket.assigns.current_page,
            filter_orphaned: socket.assigns.filter_orphaned,
            view: socket.assigns.file_view,
            file: emitted
          }}}
      )

      socket
    else
      socket
    end
  end

  defp navigate_to_folder(socket, folder_uuid) when folder_uuid in [nil, ""] do
    if controlled_mode?(socket) do
      send(self(), {__MODULE__, socket.assigns.id, {:navigate, %{folder: nil, q: "", page: 1}}})
      {:noreply, socket}
    else
      scope = scope_folder_id(socket)
      per_page = socket.assigns.per_page
      {files, total_count} = load_scoped_files(scope, 1, per_page, nil, "", list_extra(socket))

      {:noreply,
       socket
       |> assign(:file_view, nil)
       |> assign(:filter_trash, false)
       |> assign(:filter_orphaned, false)
       |> assign(:current_folder, nil)
       |> assign(:breadcrumbs, [])
       |> assign(:folders, Storage.list_folders(nil, scope, lib_opts(socket)))
       |> assign(:search_query, "")
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, Pagination.total_pages(total_count, per_page))}
    end
  end

  defp navigate_to_folder(socket, folder_uuid) do
    if controlled_mode?(socket) do
      send(
        self(),
        {__MODULE__, socket.assigns.id, {:navigate, %{folder: folder_uuid, q: "", page: 1}}}
      )

      {:noreply, socket}
    else
      scope = scope_folder_id(socket)

      {current_folder, actual_uuid} =
        if folder_uuid do
          folder = Storage.get_folder(folder_uuid)

          if folder && Storage.within_scope?(folder.uuid, scope) do
            {folder, folder.uuid}
          else
            {nil, nil}
          end
        else
          {nil, nil}
        end

      breadcrumbs = Storage.folder_breadcrumbs(actual_uuid, scope)
      folders = Storage.list_folders(actual_uuid, scope, lib_opts(socket))
      per_page = socket.assigns.per_page

      {files, total_count} =
        load_scoped_files(scope, 1, per_page, actual_uuid, "", list_extra(socket))

      {:noreply,
       socket
       |> assign(:file_view, nil)
       |> assign(:filter_trash, false)
       |> assign(:filter_orphaned, false)
       |> assign(:current_folder, current_folder)
       |> assign(:breadcrumbs, breadcrumbs)
       |> assign(:folders, folders)
       |> assign(:search_query, "")
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, Pagination.total_pages(total_count, per_page))
       |> auto_expand_breadcrumbs(breadcrumbs)}
    end
  end

  # Refresh `@folders` (the children of the current navigation folder)
  # and `@folder_tree` (the sidebar tree). Called from handlers that
  # mutate folder rows — move, bulk move/delete — so the UI shows the
  # new structure without a manual refresh. File-only mutations skip
  # this since they don't change the folder set.
  defp reload_folder_lists(socket) do
    scope = scope_folder_id(socket)
    parent_uuid = current_folder_uuid(socket)
    filter_trash = socket.assigns[:filter_trash]
    file_view = socket.assigns[:file_view]

    folders =
      cond do
        filter_trash -> Storage.list_trashed_folders(trash_scope(socket), lib_opts(socket))
        file_view == "all" -> []
        true -> Storage.list_folders(parent_uuid, scope, lib_opts(socket))
      end

    socket
    |> assign(:folders, folders)
    |> assign(:folder_tree, Storage.list_folder_tree(scope, lib_opts(socket)))
  end

  # Keep the hero header (and the open Edit-header panel) in sync when the
  # renamed folder is the one shown there. The title/description block reads
  # `@current_folder`/`@scope_folder`, not the sidebar tree — without this it
  # would keep displaying the pre-rename name after a sidebar rename.
  defp refresh_header_folder(socket, folder_uuid, updated) do
    same? = fn folder ->
      folder && to_string(folder.uuid) == to_string(folder_uuid)
    end

    socket =
      if same?.(socket.assigns[:current_folder]),
        do: assign(socket, :current_folder, updated),
        else: socket

    socket =
      if same?.(socket.assigns[:scope_folder]),
        do:
          socket
          |> assign(:scope_folder, updated)
          |> assign(:scope_folder_name, updated.name),
        else: socket

    if socket.assigns[:editing_folder_header] &&
         to_string(socket.assigns.editing_folder_header) == to_string(folder_uuid),
       do: assign(socket, :folder_header_name, updated.name),
       else: socket
  end

  # Combined trash count for the sidebar badge — files + folders.
  # Used wherever `:trash_count` is assigned so the badge reflects the
  # whole trash bucket, not just files.
  defp full_trash_count(scope, lib) do
    Storage.count_trashed_files(scope, lib) + Storage.count_trashed_folders(scope, lib)
  end

  # Sets one of the toolbar's view options. Controlled (URL-synced) browsers
  # hand the change to the host as a navigation and apply it when it comes back
  # in the nav params; the others apply it here.
  defp set_view_option(socket, assign_key, nav_key, value) do
    if controlled_mode?(socket) do
      send(
        self(),
        {__MODULE__, socket.assigns.id, {:navigate, Map.put(current_nav(socket), nav_key, value)}}
      )

      socket
    else
      socket
      |> assign(assign_key, value)
      |> assign(:current_page, 1)
      |> reload_current_page()
    end
  end

  # Where the browser is, as a navigation payload, at its first page: the same
  # folder, search, flat view and orphan filter, and every view option as it is.
  defp current_nav(socket) do
    a = socket.assigns

    %{
      folder: current_folder_uuid(socket),
      q: a.search_query,
      page: 1,
      filter_orphaned: a.filter_orphaned,
      view: a.file_view,
      type: a.file_type_filter,
      sort: a.sort_by,
      shape: a.shape_filter
    }
  end

  defp reload_current_page(socket) do
    folder_uuid = current_folder_uuid(socket)
    page = socket.assigns.current_page
    per_page = socket.assigns.per_page
    search = socket.assigns.search_query
    scope = scope_folder_id(socket)
    file_view = socket.assigns[:file_view]

    extra = list_extra(socket)

    {files, total_count} =
      cond do
        socket.assigns[:filter_trash] ->
          load_trashed_files(trash_scope(socket), page, per_page, lib_opts(socket))

        socket.assigns.filter_orphaned ->
          load_orphaned_files(page, per_page, lib_opts(socket))

        file_view == "all" ->
          load_all_view_files(scope, page, per_page, search, extra)

        true ->
          load_scoped_files(scope, page, per_page, folder_uuid, search, extra)
      end

    total_pages = Pagination.total_pages(total_count, per_page)

    # Deleting the last item of the last page leaves current_page out of
    # range — an empty grid with the pagination footer hidden. Clamp back to
    # the last populated page and reload once (the changed-page condition
    # guarantees termination).
    if files == [] and page > 1 and total_count > 0 and max(total_pages, 1) != page do
      socket
      |> assign(:current_page, max(total_pages, 1))
      |> reload_current_page()
    else
      socket
      |> assign(:uploaded_files, files)
      |> assign(:total_count, total_count)
      |> assign(:total_pages, total_pages)
      |> assign(:trash_count, full_trash_count(trash_scope(socket), lib_opts(socket)))
      |> assign_stacks()
    end
  end

  # Stacks view: for each child folder, load a few preview thumbnails + the
  # total file count for the collapsed "pile". No-op unless in stacks mode, so
  # grid/list don't pay for the per-folder queries. Cheap enough for a typical
  # folder count; revisit with a batched query if folder lists grow large.
  defp assign_stacks(%{assigns: %{view_mode: "stacks"}} = socket) do
    scope = scope_folder_id(socket)

    previews =
      Map.new(socket.assigns.folders, fn folder ->
        {files, count} =
          case Storage.list_files_in_scope(
                 scope,
                 [folder_uuid: folder.uuid, page: 1, per_page: 4] ++ list_extra(socket)
               ) do
            {:error, _} -> {[], 0}
            {fs, total} -> {fs, total}
          end

        {folder.uuid, %{previews: enrich_files(files), count: count}}
      end)

    # Keep the open stacks' grids fresh too, so a drag-move into/out of an
    # expanded stack (or any other reload) reflects immediately. Re-read at the
    # count the user has already loaded (>= one page) so "Load more" progress
    # survives a reload instead of snapping back to the first page.
    stack_files =
      Map.new(socket.assigns.expanded_stacks, fn uuid ->
        loaded = length(Map.get(socket.assigns.stack_files, uuid, []))
        limit = max(socket.assigns.per_page, loaded)
        {uuid, stack_folder_files(socket, uuid, limit)}
      end)

    socket
    |> assign(:stack_previews, previews)
    |> assign(:stack_files, stack_files)
  end

  defp assign_stacks(socket), do: socket

  # A file listed in the viewed folder is either homed there (scope-checked
  # on its home) or LINKED into it — a link is in scope by construction,
  # wherever the file's home lives. Gates every per-file action taken
  # from a listing: trash, move, download, rotate.
  defp removable_here?(file, viewed, scope) do
    if is_binary(viewed) do
      # Inside a folder view the file must actually appear here — a
      # stale or forged uuid of some other in-scope file is refused.
      to_string(file.folder_uuid) == to_string(viewed) or
        not is_nil(Storage.folder_link(viewed, file.uuid))
    else
      Storage.within_scope?(file.folder_uuid, scope)
    end
  end

  # The folder a listed file APPEARS in: the folder being viewed when it
  # holds the file (home or link), else the first expanded stack that
  # does — a stack shows a child folder's files at the parent level, so
  # the viewed folder alone would act on the wrong appearance (or, at
  # the root, on the file's home). Nil only when no folder view shows
  # it: the root / All Files / search, where actions address the file.
  defp appearance_folder(socket, file) do
    # The root of a SCOPED browser is the scope folder, not the system root —
    # the same reading `move_file_to_folder` has always applied to a drop on
    # "root". A host embeds the browser scoped to a folder of its own (a
    # sub-order's Files tab), opens it there with no current folder, and the
    # files it shows are usually links: they live in the order's folder and
    # this one points at them. Without the scope in the candidates nothing
    # here appears to be "in" a folder at all, and a per-file action falls
    # through to asking where the file LIVES.
    candidates =
      List.wrap(current_folder_uuid(socket) || scope_folder_id(socket)) ++
        (socket.assigns[:expanded_stacks] || [])

    Enum.find(candidates, fn folder_uuid ->
      to_string(file.folder_uuid) == to_string(folder_uuid) or
        not is_nil(Storage.folder_link(folder_uuid, file.uuid))
    end)
  end

  defp appearance_folder_of(socket, file_uuid) do
    case Storage.get_file(file_uuid) do
      %Storage.File{} = file -> appearance_folder(socket, file)
      _ -> current_folder_uuid(socket)
    end
  end

  # `delete_file` done: say so, close the viewer on the file, reload.
  defp removed(socket, file_uuid, flash) do
    socket
    |> put_flash(:info, flash)
    |> close_viewer_on(file_uuid)
    |> reload_current_page()
  end

  # A file removed here (trashed, or taken out of this folder) leaves a
  # picker's pick at once — the trash broadcast that also drops it does not
  # come for a file only unlinked or rehomed.
  defp unpick_removed(socket, file_uuid, {:ok, _how, _file}) do
    picked = socket.assigns[:picked] || []
    if file_uuid in picked, do: put_pick(socket, List.delete(picked, file_uuid)), else: socket
  end

  defp unpick_removed(socket, _file_uuid, _result), do: socket

  # ── Removal guard ────────────────────────────────────────────────────
  #
  # `mode` is where the event came from: `:fresh` (a click), `{:confirm,
  # pending}` (the person confirmed the dialog) or `{:reask, pending}` (the
  # guard released the files). Only a confirmation removes anything after the
  # dialog was shown, and only what the dialog showed.

  defp run_removal(event, params, socket) do
    mode = Map.get(socket.private, :removal_mode, :fresh)
    module = Removal.guard(socket.assigns)

    if is_nil(module) or socket.assigns.readonly == true do
      removal_pass(event, params, socket, [])
    else
      case removal_analysis(event, params, socket) do
        :pass when mode == :fresh ->
          removal_pass(event, params, socket, [])

        :pass ->
          {:noreply, put_flash(socket, :info, gettext("There is nothing left to remove."))}

        analysis ->
          removal_decide(module, event, params, socket, analysis, mode)
      end
    end
  end

  # Runs the handler. `except` are files it must leave alone (kept by the guard).
  defp removal_pass(event, params, socket, except, only \\ nil) do
    private =
      socket.private
      |> Map.put(:removal_checked, true)
      |> Map.put(:removal_except, except)
      |> Map.put(:removal_only, only)

    {:noreply, socket} = handle_event(event, params, %{socket | private: private})

    {:noreply,
     %{
       socket
       | private: Map.drop(socket.private, [:removal_checked, :removal_except, :removal_only])
     }}
  end

  defp removal_except(socket), do: Map.get(socket.private, :removal_except, [])

  # The files the dialog showed as free, when the action skips what is in use:
  # the handler deletes exactly these, not whatever it finds now.
  defp removal_only(socket), do: Map.get(socket.private, :removal_only)

  # The person's click on the dialog runs the event again, so every gate of
  # `handle_event/3` — viewer, own files, library — judges it once more.
  #
  # The confirmation itself passed those gates, and their markers ride in
  # `private`; they are taken off so that the replay is judged afresh, against
  # the rows as they are now.
  defp replay_removal(socket, event, params, mode) do
    private =
      socket.private
      |> Map.drop([:viewer_checked, :own_files_checked, :library_checked])
      |> Map.put(:removal_mode, mode)

    socket = %{socket | private: private}
    {:noreply, socket} = handle_event(event, params, socket)
    {:noreply, %{socket | private: Map.delete(socket.private, :removal_mode)}}
  end

  defp release_removal(socket, pending) do
    module = Removal.guard(socket.assigns)
    ctx = Removal.ctx(socket.assigns, pending.action, pending.folder_uuid)
    held = pending.places |> Enum.map(& &1.file_uuid) |> Enum.uniq()

    result = if module, do: Removal.release(module, held, ctx), else: {:error, nil}

    case result do
      :ok ->
        socket
        |> assign(:removal_pending, nil)
        |> replay_removal(pending.event, pending.params, {:reask, pending})

      {:error, message} ->
        {:noreply, assign(socket, :removal_pending, %{pending | error: message || :generic})}
    end
  end

  defp removal_decide(module, event, params, socket, analysis, mode) do
    ctx = Removal.ctx(socket.assigns, analysis.action, analysis.folder_uuid)

    case removal_places(module, analysis.files, ctx) do
      :error ->
        {:noreply, assign(socket, :removal_pending, removal_failed(analysis))}

      {:ok, places} ->
        held = places |> Enum.map(& &1.file_uuid) |> Enum.uniq()
        free = analysis.files -- held
        shown = shown_removal(mode)

        if removal_confirmed?(mode, analysis, free, held) do
          removal_execute(event, params, socket, analysis, free, held)
        else
          error =
            if shown && not same_files?(shown, analysis, free),
              do: gettext("The files changed. Check the list and confirm again.")

          pending =
            removal_pending(module, ctx, socket, analysis, {event, params}, %{
              places: places,
              free: free,
              held: held,
              error: error
            })

          {:noreply, assign(socket, :removal_pending, pending)}
        end
    end
  end

  defp removal_places(_module, [], _ctx), do: {:ok, []}
  defp removal_places(module, files, ctx), do: Removal.places(module, files, ctx)

  defp shown_removal({:confirm, pending}), do: pending
  defp shown_removal({:reask, _pending}), do: nil
  defp shown_removal(:fresh), do: nil

  # The same plan the dialog showed, and still removable: all of it, or — for
  # the actions that skip what is in use — what was free.
  defp removal_confirmed?({:confirm, pending}, analysis, free, held) do
    same_files?(pending, analysis, free) and (free != [] or analysis.folders > 0) and
      (held == [] or analysis.skip?)
  end

  defp removal_confirmed?(_mode, _analysis, _free, _held), do: false

  defp same_files?(pending, analysis, free),
    do:
      Enum.sort(pending.files) == Enum.sort(analysis.files) and
        Enum.sort(pending.free) == Enum.sort(free) and
        Enum.sort(pending.folder_uuids) == Enum.sort(analysis.folder_uuids)

  defp removal_execute(event, params, socket, analysis, free, held) do
    only = if analysis.skip?, do: free

    {:noreply, socket} = removal_pass(event, params, socket, held, only)

    if held == [] do
      {:noreply, socket}
    else
      # What is left of the free files was not deleted (a refusal, a race):
      # the summary counts the fact, not the plan.
      left = count_files(free)

      {:noreply,
       put_flash(
         socket,
         :info,
         gettext("%{deleted} deleted, %{kept} kept: in use",
           deleted: length(free) - left,
           kept: length(held) + left
         )
       )}
    end
  end

  defp count_files([]), do: 0

  defp count_files(uuids) do
    PhoenixKit.Config.get_repo().aggregate(
      from(f in Storage.File, where: f.uuid in ^uuids),
      :count,
      :uuid
    )
  end

  @removal_names_shown 8
  @removal_names_held 50

  defp removal_pending(module, ctx, socket, analysis, {event, params}, found) do
    %{places: places, free: free, held: held, error: error} = found
    free_shown = Enum.take(free, @removal_names_shown)
    names = removal_names(socket, Enum.take(held, @removal_names_held) ++ free_shown)

    free_names = for uuid <- free_shown, name = names[uuid], do: name

    %{
      token: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      failed?: false,
      event: event,
      params: params,
      action: analysis.action,
      folder_uuid: analysis.folder_uuid,
      kind: analysis.kind,
      skip?: analysis.skip?,
      folders: analysis.folders,
      folder_uuids: analysis.folder_uuids,
      files: analysis.files,
      free: free,
      places: places,
      names: names,
      free_names: free_names,
      free_hidden: length(free) - length(free_names),
      release_label: if(held != [], do: Removal.release_label(module, ctx)),
      error: error
    }
  end

  defp removal_failed(analysis) do
    %{
      token: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      failed?: true,
      kind: analysis.kind,
      folders: analysis.folders,
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

  # File names for the dialog, of the files this browser shows only.
  defp removal_names(_socket, []), do: %{}

  defp removal_names(socket, uuids) do
    uuids
    |> load_by_uuid(Storage.File)
    |> shown_only(socket)
    |> Map.new(&{&1.uuid, &1.original_file_name || &1.file_name})
  end

  # What an event would remove, from the same readings its handler acts on
  # (`Storage.removal_plan/2`). `:pass` when no file disappears, or when the
  # event names nothing this browser can act on (no such file or folder, out
  # of scope, a picker's delete for good). It does not judge everything the
  # handler might still refuse (a managed folder, say): the dialog may be
  # drawn first, and the replay refuses.
  defp removal_analysis("trash_file", %{"file_uuid" => file_uuid}, socket)
       when is_binary(file_uuid) do
    scope = scope_folder_id(socket)
    file = PhoenixKit.Config.get_repo().get(Storage.File, file_uuid)
    viewed = file && appearance_folder(socket, file)

    if file && removable_here?(file, viewed, scope),
      do:
        removal_analysis_of(
          :trash_file,
          :trash,
          Storage.removal_plan(:remove_file, {file, viewed}),
          viewed
        ),
      else: :pass
  end

  defp removal_analysis("delete_file", %{"file-uuid" => file_uuid}, socket)
       when is_binary(file_uuid) do
    scope = scope_folder_id(socket)
    file = PhoenixKit.Config.get_repo().get(Storage.File, file_uuid)
    viewed = file && appearance_folder(socket, file)

    cond do
      is_nil(file) or not removable_here?(file, viewed, scope) ->
        :pass

      # The handler refuses a picker's delete for good.
      socket.assigns[:picker] == true and file.status == "trashed" ->
        :pass

      file.status == "trashed" and Storage.within_scope?(file.folder_uuid, scope) ->
        removal_analysis_of(
          :delete_file,
          :delete,
          Storage.removal_plan(:delete_files, [file]),
          viewed
        )

      true ->
        removal_analysis_of(
          :delete_file,
          :trash,
          Storage.removal_plan(:remove_file, {file, viewed}),
          viewed
        )
    end
  end

  defp removal_analysis("trash_folder", %{"folder_uuid" => folder_uuid}, socket)
       when is_binary(folder_uuid) do
    folder_removal_analysis(:trash_folder, :trash_folder, :trash, folder_uuid, socket)
  end

  defp removal_analysis("delete_folder", %{"id" => folder_uuid}, socket)
       when is_binary(folder_uuid) do
    if socket.assigns[:filter_trash],
      do: folder_removal_analysis(:delete_folder, :delete_folder, :delete, folder_uuid, socket),
      else: folder_removal_analysis(:delete_folder, :trash_folder, :trash, folder_uuid, socket)
  end

  defp removal_analysis("delete_selected", _params, socket) do
    scope = scope_folder_id(socket)
    {files, folders} = shown_selection(socket)
    folders = folders_in_scope(folders, scope)
    trash? = socket.assigns[:filter_trash] == true

    file_plan =
      if trash? do
        files
        |> Enum.filter(&(&1.status == "trashed" and Storage.within_scope?(&1.folder_uuid, scope)))
        |> then(&Storage.removal_plan(:delete_files, &1))
      else
        files
        |> Enum.filter(&removable_here?(&1, appearance_folder(socket, &1), scope))
        |> Enum.map(&Storage.removal_plan(:remove_file, {&1, appearance_folder(socket, &1)}))
        |> merge_removal_plans()
      end

    folder_action = if trash?, do: :delete_folder, else: :trash_folder

    plan =
      merge_removal_plans([
        file_plan | Enum.map(folders, &Storage.removal_plan(folder_action, &1))
      ])

    removal_analysis_of(
      :delete_selected,
      if(trash?, do: :delete, else: :trash),
      plan,
      current_folder_uuid(socket),
      skip?: trash? and folders == [],
      folder_uuids: Enum.map(folders, & &1.uuid)
    )
  end

  defp removal_analysis("empty_trash", _params, socket) do
    trashed =
      Storage.list_trashed_files(
        trash_scope(socket),
        Keyword.take(lib_opts(socket), [:library_uuid, :viewer_uuid])
      )

    removal_analysis_of(
      :empty_trash,
      :delete,
      Storage.removal_plan(:delete_files, trashed),
      current_folder_uuid(socket),
      skip?: true
    )
  end

  defp removal_analysis(_event, _params, _socket), do: :pass

  defp folder_removal_analysis(action, plan_action, kind, folder_uuid, socket) do
    folder = Storage.get_folder(folder_uuid)

    if folder && Storage.within_scope?(folder.uuid, scope_folder_id(socket)),
      do:
        removal_analysis_of(action, kind, Storage.removal_plan(plan_action, folder), folder.uuid,
          folder_uuids: [folder.uuid]
        ),
      else: :pass
  end

  # Only `trash` and `delete` make a file disappear: a plan with neither needs
  # no guard. A folder removed has always been confirmed, though, so an action
  # on folders asks even when no file goes with them.
  defp removal_analysis_of(action, kind, plan, folder_uuid, opts \\ []) do
    files = Enum.uniq(plan.trash ++ plan.delete)
    folder_uuids = Keyword.get(opts, :folder_uuids, [])
    folders = length(folder_uuids)

    if files == [] and folders == 0 do
      :pass
    else
      %{
        action: action,
        kind: kind,
        files: files,
        folders: folders,
        folder_uuids: folder_uuids,
        folder_uuid: folder_uuid,
        skip?: Keyword.get(opts, :skip?, false)
      }
    end
  end

  defp merge_removal_plans(plans) do
    Enum.reduce(plans, %{trash: [], delete: [], rehome: [], unlink: []}, fn plan, acc ->
      Map.merge(acc, plan, fn _key, a, b -> a ++ b end)
    end)
  end

  defp assign_removal_guarded(socket),
    do: assign(socket, :removal_guarded, not is_nil(Removal.guard(socket.assigns)))

  # What a permanent delete of one file answers. The message says why when the file
  # is in use: pressing Delete and being told nothing — or told it worked — is
  # the failure this replaces.
  defp permanent_delete_flash({:ok, _}), do: {:info, gettext("File permanently deleted")}

  defp permanent_delete_flash({:error, :in_use}),
    do:
      {:error,
       gettext(
         "This file is in use by something else (a comment, for instance), so it can't be deleted."
       )}

  defp permanent_delete_flash(_), do: {:error, gettext("Failed to remove file")}

  defp removal_flash({:ok, :trashed, _}), do: gettext("File moved to trash")
  defp removal_flash({:ok, _unlinked_or_rehomed, _}), do: gettext("File removed from this folder")
  defp removal_flash(_), do: gettext("Failed to move file")

  # Enriched files directly in a folder, for an expanded stack grid. `limit`
  # caps how many are loaded (always from the top) — never the whole folder, so
  # opening a stack with thousands of files loads one page, not all of them.
  # Per-stack "Load more" grows the limit; assign_stacks re-reads at the current
  # limit so a reload (drag-move, etc.) keeps everything the user has loaded.
  defp stack_folder_files(socket, folder_uuid, limit) do
    case Storage.list_files_in_scope(
           scope_folder_id(socket),
           [folder_uuid: folder_uuid, page: 1, per_page: limit] ++ list_extra(socket)
         ) do
      {:error, _} -> []
      {fs, _total} -> enrich_files(fs)
    end
  end

  # Navigating to a different folder context: collapse any open stacks (they
  # belonged to the previous folder) and recompute the new folder's previews.
  defp reset_stacks(socket) do
    socket
    |> assign(:expanded_stacks, [])
    |> assign(:stack_files, %{})
    |> assign(:just_opened_stack, nil)
    |> assign_stacks()
  end

  # Relays a featured-image choice to the host and moves the browser's own
  # `featured.uuid` so the badge/kebab flip immediately — see the
  # moduledoc's `:featured` attr and the `"set_featured"`/`"unset_featured"`
  # handle_event clauses above. A no-op when the host never opted in.
  defp notify_featured(socket, uuid) do
    case socket.assigns[:featured] do
      nil ->
        socket

      featured ->
        send(self(), {__MODULE__, socket.assigns.id, {:set_featured, uuid}})
        assign(socket, :featured, %{featured | uuid: uuid})
    end
  end

  # Open the move modal, seeding its directory tree's expansion from the
  # sidebar's current `:expanded_folders` so the picker opens showing the
  # same expanded directories the user already sees on the left. The
  # modal then tracks its own `:move_expanded` independently, so drilling
  # in the picker doesn't move the sidebar.
  defp open_move_modal(socket) do
    socket
    |> assign(:show_move_modal, true)
    |> assign(:move_expanded, socket.assigns.expanded_folders)
  end

  defp current_folder_uuid(socket) do
    socket.assigns.current_folder && socket.assigns.current_folder.uuid
  end

  # Resolve a folder already loaded in assigns (the current folder or the
  # listing) before falling back to a DB read — the description editor is
  # always opened from a folder that's on screen, so the re-query is redundant.
  defp loaded_folder(socket, folder_uuid) do
    current = socket.assigns[:current_folder]
    key = to_string(folder_uuid)

    found =
      if current && to_string(current.uuid) == key do
        current
      else
        Enum.find(socket.assigns[:folders] || [], &(to_string(&1.uuid) == key))
      end

    found || Storage.get_folder(folder_uuid)
  end

  # The folder's creator (the `user_uuid` owner) for the folder-header info
  # line — returns the user struct (used for the avatar + name) or nil.
  # Header media (creator user + cover/logo URLs) for the folder hero. Each
  # piece is gated on its matching `header_show_*` toggle so a folder whose
  # header hides that element costs no extra query / signed-URL build on
  # navigation (the hot path). The Edit-header editor loads the cover/logo URLs
  # unconditionally when it opens (see `start_edit_folder_header`) so its
  # previews still work with the toggles off.
  defp assign_folder_header_media(socket, %{} = folder) do
    creator = if folder.header_show_creator, do: folder_creator_user(folder)
    cover = if folder.header_show_background, do: folder_image_data(folder.cover_file_uuid)
    logo = if folder.header_show_icon, do: folder_image_data(folder.logo_file_uuid)

    socket
    |> assign(:folder_creator_user, creator)
    |> assign(:folder_creator_name, creator_label(creator))
    |> assign_folder_image(:folder_cover, cover)
    |> assign_folder_image(:folder_logo, logo)
  end

  defp assign_folder_header_media(socket, _no_folder) do
    socket
    |> assign(:folder_creator_user, nil)
    |> assign(:folder_creator_name, nil)
    |> assign_folder_image(:folder_cover, nil)
    |> assign_folder_image(:folder_logo, nil)
  end

  # Splits a `folder_image_data/1` result into the `<prefix>_url` +
  # `<prefix>_rotation` assign pair (nil data → no image).
  defp assign_folder_image(socket, prefix, nil) do
    socket
    |> assign(:"#{prefix}_url", nil)
    |> assign(:"#{prefix}_rotation", 0)
  end

  defp assign_folder_image(socket, prefix, %{url: url, rotation: rotation}) do
    socket
    |> assign(:"#{prefix}_url", url)
    |> assign(:"#{prefix}_rotation", rotation)
  end

  defp folder_creator_user(%{user_uuid: user_uuid}) when is_binary(user_uuid),
    do: Auth.get_user(user_uuid)

  defp folder_creator_user(_), do: nil

  # Display label for a creator — full name, falling back to email.
  defp creator_label(nil), do: nil
  defp creator_label(user), do: User.display_name(user)

  # Display URL for a folder header image (cover or logo) by file uuid, or nil.
  # Loads the referenced file and enriches it for its signed URLs.
  # Resolve a folder's cover/logo image together with the file's saved
  # rotation, so folder header media renders the same way up as every other
  # thumbnail of the file.
  defp folder_image_data(uuid) when is_binary(uuid) do
    case Storage.get_file(uuid) do
      nil ->
        %{url: nil, rotation: 0}

      file ->
        url =
          case enrich_files([file]) do
            [%{urls: urls}] -> urls["original"] || urls |> Map.values() |> List.first()
            _ -> nil
          end

        %{url: url, rotation: normalized_rotation(Map.get(file.metadata || %{}, "rotation"))}
    end
  end

  defp folder_image_data(_), do: %{url: nil, rotation: 0}

  defp reset_folder_header_edit(socket) do
    socket
    |> assign(:editing_folder_header, nil)
    |> assign(:folder_header_name, "")
    |> assign(:folder_header_description, "")
  end

  defp save_folder_header(socket, folder, folder_uuid, scope, name, desc_value) do
    case Storage.update_folder(folder, %{name: name, description: desc_value}, scope) do
      {:ok, updated} ->
        parent_uuid = current_folder_uuid(socket)

        socket =
          socket
          |> reset_folder_header_edit()
          # Reload the listing + tree so any grid card / list row / sidebar
          # entry for this folder reflects the new name and description.
          |> assign(:folders, Storage.list_folders(parent_uuid, scope, lib_opts(socket)))
          |> assign(:folder_tree, Storage.list_folder_tree(scope, lib_opts(socket)))

        # Refresh the header's folder + breadcrumbs when editing the folder
        # we're currently inside, so the title, description and breadcrumb
        # trail all show the new name immediately.
        socket =
          if socket.assigns[:current_folder] &&
               to_string(socket.assigns.current_folder.uuid) == to_string(folder_uuid) do
            socket
            |> assign(:current_folder, updated)
            |> assign(:breadcrumbs, Storage.folder_breadcrumbs(folder_uuid, scope))
          else
            socket
          end

        {:noreply, socket}

      {:error, :out_of_scope} ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot edit a folder outside the allowed scope"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save folder header"))}
    end
  end

  # Read the per-user grid/list preference from `custom_fields`, defaulting to
  # "grid". Tolerant of a missing/garbage value.
  defp load_user_view_mode(%{} = user) do
    case Auth.get_user_field(user, @media_view_mode_key) do
      mode when mode in ["grid", "list", "stacks"] -> mode
      _ -> "grid"
    end
  end

  defp load_user_view_mode(_), do: "grid"

  # Persist the preference into a freshly-read `custom_fields` copy so a
  # concurrent change elsewhere isn't clobbered. Returns the updated user (or
  # the original on no-user / error) for the caller to re-assign.
  defp persist_user_view_mode(%{uuid: uuid} = user, mode) when is_binary(uuid) do
    fresh = Auth.get_user(uuid) || user
    merged = Map.put(fresh.custom_fields || %{}, @media_view_mode_key, mode)

    # Internal view preference — skip the custom-field-definition registration
    # so it never surfaces in the admin Custom Fields list or the users-table
    # column customizer. Mirrors the users/activity list views. Reads go
    # through `Auth.get_user_field/2`, which never consults definitions.
    case Auth.update_user_custom_fields(fresh, merged, ensure_definitions: false) do
      {:ok, updated} -> updated
      {:error, _} -> user
    end
  end

  defp persist_user_view_mode(user, _mode), do: user

  # Sidebar tree state (expanded folder uuids + collapsed flag). Persisted in
  # user meta so the first server render already shows the tree open — no
  # collapsed→expanded jump after connect.
  defp load_user_expanded_folders(%{} = user) do
    case Auth.get_user_field(user, @media_expanded_folders_key) do
      list when is_list(list) -> list |> Enum.filter(&is_binary/1) |> MapSet.new()
      _ -> MapSet.new()
    end
  end

  defp load_user_expanded_folders(_), do: MapSet.new()

  # The server opening the sidebar on its own (to show a folder it just
  # created). The revision bump is what makes it show: the chevron's
  # client-side class change is sticky and would otherwise be re-applied over
  # this render — see `FolderExplorer`'s `sidebar_rev`.
  defp force_sidebar_expanded(socket) do
    if socket.assigns.sidebar_collapsed do
      socket
      |> assign(:sidebar_collapsed, false)
      |> assign(:sidebar_rev, socket.assigns.sidebar_rev + 1)
    else
      socket
    end
  end

  defp load_user_sidebar_collapsed(%{} = user) do
    Auth.get_user_field(user, @media_sidebar_collapsed_key) == true
  end

  defp load_user_sidebar_collapsed(_), do: false

  # Write the current tree state into the user's custom_fields and re-assign the
  # updated user, mirroring `persist_user_view_mode/2`. We re-read the user fresh
  # from the DB first because `update_user_custom_fields` blind-writes the WHOLE
  # custom_fields map (no server-side merge) — using the in-socket copy would
  # clobber any custom_fields key written elsewhere since this socket loaded
  # (e.g. notification preferences saved on the settings page in another tab).
  defp persist_tree_state(%{assigns: %{picker: true}} = socket), do: socket

  defp persist_tree_state(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} = user when is_binary(uuid) ->
        fresh = Auth.get_user(uuid) || user

        merged =
          (fresh.custom_fields || %{})
          |> Map.put(
            @media_expanded_folders_key,
            MapSet.to_list(socket.assigns.expanded_folders)
          )
          |> Map.put(@media_sidebar_collapsed_key, socket.assigns.sidebar_collapsed)

        # Internal sidebar state — not an admin-managed custom field.
        case Auth.update_user_custom_fields(fresh, merged, ensure_definitions: false) do
          {:ok, updated} -> assign(socket, :phoenix_kit_current_user, updated)
          {:error, _} -> socket
        end

      _ ->
        socket
    end
  end

  defp scope_folder_id(socket), do: socket.assigns[:scope_folder_id]

  # The image editor, in a modal over the browser. Editing is authorized the
  # way rotating and deleting are here: the file's home is in this browser's
  # scope (the host decided who sees the browser). The uuid arrives from the
  # client, so it gets the viewer's gates first (well-formed uuid, never
  # system-managed, the `only_file_type` lock).
  #
  # The editor's scope is built here, once: `Scope.for_user/1` reads roles and
  # permissions, and a template attribute would repeat that on every render.
  defp open_image_editor(socket, file_uuid) do
    with %Storage.File{} = file <- fetch_viewable_file(socket, file_uuid),
         true <- ImageEditing.editable?(file) do
      socket
      |> open_viewer(nil)
      |> notify_viewer_nav()
      |> assign(:image_editor_scope, editor_scope(socket.assigns[:phoenix_kit_current_user]))
      |> assign(:image_editor_file, file)
    else
      _ -> socket
    end
  end

  defp notify_image_editor(socket, file_uuid) do
    case socket.assigns[:image_editor_file] do
      %{uuid: ^file_uuid} ->
        send_update(PhoenixKitWeb.Components.ImageEditor,
          id: image_editor_id(socket.assigns.id, file_uuid),
          file_processed: file_uuid
        )

      _ ->
        :ok
    end
  end

  defp editor_scope(%User{} = user), do: Scope.for_user(user)
  defp editor_scope(_user), do: nil

  # The scope for the Trash view + badge: the folder you're currently in (its
  # whole subtree), falling back to the embedded browser scope at the root.
  # Keeps a folder's Trash to what was deleted under it — never a sibling
  # root's trash. At the true root (no current folder, no embed scope) this is
  # nil, so the top-level view still shows all trash.
  defp trash_scope(socket), do: current_folder_uuid(socket) || scope_folder_id(socket)

  # trash_scope/1 reads the socket's `current_folder`, but on the nav path the
  # target folder is only a local (the socket still holds the old one), so this
  # resolves the same "this folder's subtree, else the embed scope" from
  # explicit args.
  defp folder_or_scope(nil, scope), do: scope
  defp folder_or_scope(folder, _scope), do: folder.uuid

  defp controlled_mode?(socket), do: socket.assigns[:on_navigate] != nil

  # ──────────────────────────────────────────────────────────────
  # Data loading
  # ──────────────────────────────────────────────────────────────

  # Both trash and orphan views render through the same list / grid
  # markup, so delegate to `enrich_files/1` for the per-file display
  # shape (urls, folder_path, etc.). Previously these hand-rolled the
  # map and omitted `folder_path`, which the list-view Path column
  # reads unconditionally — opening the trash or orphan view in list
  # mode crashed with `KeyError`.
  defp load_trashed_files(scope, page, per_page, lib) do
    offset = (page - 1) * per_page
    total_count = Storage.count_trashed_files(scope, lib)
    files = Storage.list_trashed_files(scope, [limit: per_page, offset: offset] ++ lib)
    {enrich_files(files), total_count}
  end

  defp load_orphaned_files(page, per_page, lib) do
    offset = (page - 1) * per_page
    total_count = Storage.count_orphaned_files(nil, lib)
    files = Storage.find_orphaned_files([limit: per_page, offset: offset] ++ lib)
    {enrich_files(files), total_count}
  end

  # Loads files within scope with optional folder/search filters.
  # When scope=nil AND folder_uuid=nil AND search="", passes include_orphaned: true
  # to preserve the /admin/media root view behavior of showing only orphan files.
  defp load_scoped_files(scope, page, per_page, folder_uuid, search, extra) do
    at_real_root = is_nil(scope) and is_nil(folder_uuid) and search in [nil, ""]

    opts = extra ++ [page: page, per_page: per_page]

    opts =
      if folder_uuid && folder_uuid != "", do: [{:folder_uuid, folder_uuid} | opts], else: opts

    opts = if search && search != "", do: [{:search, search} | opts], else: opts
    opts = if at_real_root, do: [{:include_orphaned, true} | opts], else: opts

    case Storage.list_files_in_scope(scope, opts) do
      {:error, :out_of_scope} -> {[], 0}
      {files, total_count} -> {enrich_files(files), total_count}
    end
  end

  # Loads ALL files in the system (or within scope subtree when scope is set).
  # Used for the view=all flat listing. Does not apply folder or orphan filters.
  defp load_all_view_files(scope, page, per_page, search, extra) do
    opts = extra ++ [page: page, per_page: per_page]
    opts = if search && search != "", do: [{:search, search} | opts], else: opts

    case Storage.list_files_in_scope(scope, opts) do
      {:error, :out_of_scope} -> {[], 0}
      {files, total_count} -> {enrich_files(files), total_count}
    end
  end

  defp enrich_files([]), do: []

  defp enrich_files(files) do
    repo = PhoenixKit.Config.get_repo()
    file_uuids = Enum.map(files, & &1.uuid)

    instances_by_file =
      from(fi in FileInstance, where: fi.file_uuid in ^file_uuids)
      |> repo.all()
      |> Enum.group_by(& &1.file_uuid)

    folder_uuids =
      files |> Enum.map(& &1.folder_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    folder_paths = Map.new(folder_uuids, fn fuuid -> {fuuid, Helpers.breadcrumb_path(fuuid)} end)

    # Which libraries of the batch have annotated thumbnails on (a library's
    # own choice, else the site setting), in one query — when off, the baked
    # variant is hidden so the grid falls back to the plain thumbnail.
    annotated_libraries =
      files |> Enum.map(& &1.library_uuid) |> Storage.AnnotationThumbnail.enabled_among()

    # The language and the site's primary language, read once for the batch.
    alt_opts = MediaThumbnail.alt_opts()

    # Files in a private library get time-window URLs; one query for all.
    private = files |> Enum.map(& &1.library_uuid) |> Libraries.private_among()

    # Deep zoom where the library's variant set makes tiles; one query too.
    tiles = files |> Enum.map(& &1.library_uuid) |> VariantSets.tiles_among()

    Enum.map(files, fn file ->
      instances = Map.get(instances_by_file, file.uuid, [])

      urls =
        generate_urls_from_instances(instances, file.uuid, file.mime_type,
          annotated_enabled?:
            to_string(file.library_uuid || Libraries.media_uuid()) in annotated_libraries,
          private: to_string(file.library_uuid) in private,
          tiles: to_string(file.library_uuid || Libraries.media_uuid()) in tiles
        )

      variant_widths = generate_widths_from_instances(instances)

      %{
        file_uuid: file.uuid,
        filename: file.original_file_name || file.file_name || "Unknown",
        # The file's own alt text in the page's language; without one the
        # thumbnail keeps the file name, which is what this grid lists files by.
        alt: MediaThumbnail.alt_text(file, alt_opts),
        original_filename: file.original_file_name,
        # Reconciled against the row's own mime/filename evidence, so a
        # misclassified row (stored before the write boundary defended this
        # column) degrades to the right rendering instead of a broken <img>.
        file_type: Storage.display_file_type(file),
        mime_type: file.mime_type,
        size: file.size,
        status: file.status,
        inserted_at: file.inserted_at,
        # Width and height come straight from the File schema columns
        # populated by the variant generator on upload. `nil` is
        # possible for files uploaded before the variant generator ran
        # (or for non-image types); `build_viewer_canvas/2` falls back
        # to a 1000x1000 placeholder canvas in that case so the LV
        # doesn't crash.
        width: file.width,
        height: file.height,
        # The image's saved orientation, applied to thumbnails as a CSS
        # transform (see `MediaThumbnail.rotation_class/1`) so the grid
        # matches what the viewer's canvas shows. Baked variants are
        # unrotated on disk; nil/garbage reads as unrotated.
        rotation: Map.get(file.metadata || %{}, "rotation"),
        folder_path: Map.get(folder_paths, file.folder_uuid),
        # What the file's burned copy was rendered from, so the viewer can
        # tell whether the drawing in front of it has already been burned
        # and skip re-rendering one that has (AnnotationBurn hook).
        burn_fingerprint: burn_fingerprint(file, instances),
        # The burned copy the viewer opens with, and its own extent. It is a
        # different shape from the picture — it takes in ink drawn past the
        # edges — so the viewer has to lay out ITS dimensions, not the
        # picture's.
        burn_size: burn_size(instances),
        urls: urls,
        variant_widths: variant_widths
      }
    end)
  end

  # ──────────────────────────────────────────────────────────────
  # Upload processing
  # ──────────────────────────────────────────────────────────────

  # A raise anywhere in the store — a hash on a vanished temp file, a bucket
  # adapter blowing up, a DB error mid-insert — used to take the whole
  # LiveView down: the page reconnected, every file still queued behind it
  # was lost, and nothing said so. Now it is one failed upload, recorded
  # with the others, its bytes kept for a retry.
  defp safe_process_single_upload(socket, path, entry) do
    process_single_upload(socket, path, entry)
  rescue
    error ->
      Logger.error(
        "MediaBrowser upload of #{inspect(entry.client_name)} raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:postpone, {:exception, Exception.message(error)}}
  catch
    kind, reason ->
      Logger.error(
        "MediaBrowser upload of #{inspect(entry.client_name)} #{kind}: #{inspect(reason)}"
      )

      {:postpone, {:exception, inspect(reason)}}
  end

  # What happens to the bytes once the store has answered. Stored: gone,
  # inbox item and all. Refused because the file already lives in another
  # library: gone too — that is a deliberate refusal the flash explains, and
  # retrying would only be refused again. Anything else failed, and the
  # bytes stay: marked in the inbox when they are there, held by this
  # browser otherwise, so the panel can offer Retry.
  defp settle_upload(socket, path, entry, result) do
    located = UploadInbox.locate(path)

    case result do
      {:postpone, :in_other_library} ->
        drop_upload_bytes(path, located)
        socket

      {:postpone, reason} ->
        case located do
          {user_uuid, id} ->
            UploadInbox.fail(user_uuid, id, describe_upload_failure(reason))
            socket

          nil ->
            add_upload_problem(socket, %{
              kind: :server,
              client_name: entry.client_name,
              client_size: entry.client_size,
              client_type: entry.client_type,
              reason: describe_upload_failure(reason),
              path: path
            })
        end

      _stored ->
        drop_upload_bytes(path, located)
        socket
    end
  end

  defp drop_upload_bytes(path, nil), do: File.rm(path)
  defp drop_upload_bytes(_path, {user_uuid, id}), do: UploadInbox.delete(user_uuid, id)

  @doc false
  # The sentence the panel shows for a store that failed. Short and in the
  # user's terms; the full reason is in the log line the failure wrote.
  def describe_upload_failure(:no_buckets_configured),
    do: gettext("No storage is set up to receive files.")

  def describe_upload_failure({:exception, _message}),
    do: gettext("The server ran into an error while saving it.")

  def describe_upload_failure(:file_missing),
    do: gettext("The uploaded file went missing on the server before it could be saved.")

  def describe_upload_failure(_reason),
    do: gettext("The server could not save it.")

  defp process_single_upload(socket, path, entry) do
    ext = Path.extname(entry.client_name) |> String.replace_leading(".", "")
    mime_type = entry.client_type || MIME.from_path(entry.client_name)
    # One classifier for every upload path (see `Storage.determine_file_type/2`) —
    # the local copy that used to live here had no audio clause, so an mp3 was
    # stored as a document and then hidden by the audio filter.
    file_type = Storage.determine_file_type(mime_type, entry.client_name)
    current_user = socket.assigns[:phoenix_kit_current_user]
    user_uuid = if current_user, do: current_user.uuid, else: nil

    case Elixir.File.stat(path) do
      {:ok, stat} ->
        store_upload(socket, path, entry, ext, mime_type, file_type, user_uuid, stat.size)

      {:error, _} ->
        {:postpone, :file_missing}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp store_upload(socket, path, entry, ext, mime_type, file_type, user_uuid, file_size) do
    file_hash = Auth.calculate_file_hash(path)

    case Storage.store_file_in_buckets(
           path,
           file_type,
           user_uuid,
           file_hash,
           ext,
           entry.client_name,
           [mime_type: mime_type] ++ lib_opts(socket)
         ) do
      # Dedup is still per uploader across the whole install: the same bytes
      # this person already stored in another library come back as that
      # file, which this library cannot show or hold.
      {:ok, file, :duplicate} ->
        if in_shown_library?(file, lib_opts(socket)) do
          maybe_set_folder(file, socket, placement_folder(socket, path))
          build_upload_result(file, entry, file_type, mime_type, file_size, true)
        else
          {:postpone, :in_other_library}
        end

      {:ok, file} ->
        maybe_set_folder(file, socket, placement_folder(socket, path))
        build_upload_result(file, entry, file_type, mime_type, file_size, false)

      {:error, reason} ->
        Logger.error("MediaBrowser upload error: #{inspect(reason)}")
        {:postpone, reason}
    end
  end

  defp build_upload_result(file, entry, file_type, mime_type, file_size, is_duplicate) do
    result = %{
      file_uuid: file.uuid,
      filename: entry.client_name,
      # The row's values, not the local echo: the write boundary may have
      # corrected the claimed type (and a :duplicate hit returns the earlier
      # row, whose type/mime this upload never influenced).
      file_type: file.file_type || file_type,
      mime_type: file.mime_type || mime_type,
      size: file_size,
      status: file.status,
      urls: %{}
    }

    result = if is_duplicate, do: Map.put(result, :duplicate, true), else: result
    {:ok, result}
  end

  defp build_upload_flash_message(uploaded_files) do
    {skipped, rest} =
      Enum.split_with(uploaded_files, &match?({:postpone, :in_other_library}, &1))

    cond do
      skipped != [] and rest == [] ->
        {:warning, other_library_message(length(skipped))}

      skipped != [] ->
        {type, message} = upload_flash(rest)
        {type, message <> " " <> other_library_message(length(skipped))}

      true ->
        upload_flash(rest)
    end
  end

  # Dedup is still per uploader across every library, and a second library
  # refuses a file it does not hold. That refusal is not a missing bucket —
  # saying so sent people to Settings to fix storage that was fine.
  defp other_library_message(count) do
    ngettext(
      "%{count} file is already in another library, so it was not added here.",
      "%{count} files are already in another library, so they were not added here.",
      count
    )
  end

  defp upload_flash(uploaded_files) do
    error_count = Enum.count(uploaded_files, &match?({:postpone, _}, &1))
    successful_uploads = Enum.reject(uploaded_files, &match?({:postpone, _}, &1))

    duplicate_count =
      Enum.count(successful_uploads, fn
        {:ok, %{duplicate: true}} -> true
        _ -> false
      end)

    new_count = length(successful_uploads) - duplicate_count
    build_flash_from_counts(error_count, new_count, duplicate_count)
  end

  defp build_flash_from_counts(error_count, new_count, duplicate_count) do
    cond do
      all_failed?(error_count, new_count, duplicate_count) ->
        build_all_failed_message()

      partial_success?(error_count, new_count) ->
        build_partial_success_message(new_count, error_count)

      only_duplicates?(duplicate_count, new_count) ->
        build_only_duplicates_message(duplicate_count)

      new_files_only?(new_count, duplicate_count) ->
        build_new_files_only_message(new_count)

      new_and_duplicates?(new_count, duplicate_count) ->
        build_new_and_duplicates_message(new_count, duplicate_count)

      true ->
        {:info, gettext("Upload processed")}
    end
  end

  defp all_failed?(error_count, new_count, duplicate_count),
    do: error_count > 0 && new_count == 0 && duplicate_count == 0

  defp partial_success?(error_count, new_count), do: error_count > 0 && new_count > 0
  defp only_duplicates?(duplicate_count, new_count), do: duplicate_count > 0 && new_count == 0
  defp new_files_only?(new_count, duplicate_count), do: new_count > 0 && duplicate_count == 0
  defp new_and_duplicates?(new_count, duplicate_count), do: new_count > 0 && duplicate_count > 0

  defp build_all_failed_message do
    {:error,
     gettext(
       "Upload failed: No storage buckets configured. Please configure at least one storage bucket before uploading files."
     )}
  end

  defp build_partial_success_message(new_count, error_count) do
    uploaded = ngettext("%{count} file uploaded", "%{count} files uploaded", new_count)
    failed = ngettext("%{count} failed", "%{count} failed", error_count)

    {:warning,
     gettext(
       "Partially successful: %{uploaded}, %{failed} due to missing storage buckets.",
       uploaded: uploaded,
       failed: failed
     )}
  end

  defp build_only_duplicates_message(duplicate_count) do
    {:info,
     ngettext(
       "Already have %{count} duplicate file. No new files were added.",
       "Already have %{count} duplicate files. No new files were added.",
       duplicate_count
     )}
  end

  defp build_new_files_only_message(new_count) do
    {:info,
     ngettext(
       "Upload successful! %{count} new file processed",
       "Upload successful! %{count} new files processed",
       new_count
     )}
  end

  defp build_new_and_duplicates_message(new_count, duplicate_count) do
    added = ngettext("%{count} new file added", "%{count} new files added", new_count)

    duplicates =
      ngettext(
        "%{count} file was already uploaded",
        "%{count} files were already uploaded",
        duplicate_count
      )

    {:info,
     gettext("Upload successful! %{added}. %{duplicates}.",
       added: added,
       duplicates: duplicates
     )}
  end

  defp maybe_set_folder(file, socket, target) do
    scope = scope_folder_id(socket)
    folder_uuid = target || scope

    cond do
      is_nil(folder_uuid) ->
        :ok

      is_nil(scope) or Storage.within_scope?(folder_uuid, scope) ->
        # The target folder is verified in-scope above. A fresh upload is
        # adopted; a content-duplicate that already lives in another
        # folder is LINKED here, never moved — moving it emptied the
        # folder that owned it (2026-09-12).
        Storage.attach_file_to_folder(file, folder_uuid)

      true ->
        Logger.warning(
          "MediaBrowser: refusing out-of-scope initial placement " <>
            "target=#{inspect(folder_uuid)} scope=#{inspect(scope)}"
        )

        :ok
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Style / icon helpers
  # ──────────────────────────────────────────────────────────────

  defp generate_urls_from_instances(instances, file_uuid, mime_type, opts) do
    annotated_enabled? = Keyword.fetch!(opts, :annotated_enabled?)
    private? = Keyword.fetch!(opts, :private)

    # For images, `put_dzi_url/3` adds a `"dzi"` manifest URL when tile
    # generation is enabled (shared with the detail page + lightbox so all
    # viewers wire deep zoom identically). Manifest + tiles are generated
    # lazily on first request; off → no `"dzi"` key, so Tessera just swaps
    # the medium/large/original rasters and never asks for tiles.
    instances
    |> Enum.reject(fn instance ->
      instance.variant_name == "thumbnail_annotated" and not annotated_enabled?
    end)
    # The signed URL is content-independent (a capability token); `version:`
    # adds the variant's checksum, so a re-baked `thumbnail_annotated` or an
    # edited image gets a new URL instead of a stale cached one.
    |> Enum.reduce(%{}, fn instance, acc ->
      url =
        URLSigner.signed_url(file_uuid, instance.variant_name,
          version: instance,
          private: private?
        )

      Map.put(acc, instance.variant_name, url)
    end)
    |> URLSigner.put_dzi_url(file_uuid, mime_type,
      version: original_instance(instances),
      private: private?,
      tiles: Keyword.fetch!(opts, :tiles)
    )
  end

  defp original_instance(instances), do: Enum.find(instances, &(&1.variant_name == "original"))

  # The burn the viewer opens with: `burned_large` (sized to be looked at),
  # else `burned` (the card-sized one, from a client that asked for no large
  # copy). `variant` travels with the size so the viewer shows the image these
  # dimensions describe. These are the names `AnnotationBurnController`
  # writes; nothing writes an `annotated` variant.
  @doc false
  def burn_size(instances) do
    Enum.find_value(~w(burned_large burned), fn variant ->
      case Enum.find(instances, &(&1.variant_name == variant)) do
        %{width: w, height: h} when is_integer(w) and is_integer(h) and w > 0 and h > 0 ->
          %{variant: variant, w: w, h: h}

        _ ->
          nil
      end
    end)
  end

  # The fingerprint of the drawing the stored burn was made from — only
  # while a burn is actually stored. An image edit deletes every variant, the
  # burns included, but leaves `metadata["burn"]` behind; handing that back
  # told the client its (unchanged) drawing was already burned, so no burn was
  # ever made again until somebody changed the drawing.
  @doc false
  def burn_fingerprint(file, instances) do
    if burn_size(instances),
      do: get_in(file.metadata || %{}, ["burn", "fingerprint"])
  end

  # Builds a parallel map of `%{variant_name => width}` from the same
  # FileInstance rows that produce the URLs. Used downstream by
  # `tessera_sources/1` to decide which variants to surface as zoom
  # layers and where to set the swap thresholds.
  defp generate_widths_from_instances(instances) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      case instance.width do
        nil -> acc
        w -> Map.put(acc, instance.variant_name, w)
      end
    end)
  end

  # Finder-style "untitled" / "untitled 1" / "untitled 2" naming for
  # quick folder creation. Looks at sibling folders in the same parent
  # and picks the first non-conflicting name. Gaps fill before
  # extending — if "untitled" and "untitled 5" exist, we create
  # "untitled 1". Active siblings only: the V122 partial index makes
  # trashed siblings invisible to the unique constraint, so
  # `list_folders/2`'s active-only view matches what the DB will
  # accept.
  # A readonly browser hides every affordance that would trigger one of these
  # events, but the event is still reachable from a console — server, not
  # markup, is what a consumer can actually trust — so it's refused here too
  # (mirrors the `only_file_type` lock on `set_file_filter` above).
  defp unchecked(socket), do: %{socket | private: Map.delete(socket.private, :library_checked)}

  # Whether a file or folder is one this browser shows: in the library it
  # shows (or a site library, when it names none) and visible to its viewer.
  # The event gate refuses what an event names; this is the same rule for what a
  # handler takes from the selection or the database. A list is checked with at
  # most two queries however long it is.
  defp shown_only(items, socket) do
    items = Enum.reject(items, &is_nil/1)
    opts = lib_opts(socket)

    items
    |> in_shown_libraries(opts[:library_uuid])
    |> visible_to_viewer(opts[:viewer_uuid], opts[:library_uuid])
  end

  defp in_shown_libraries(items, nil) do
    unlisted = items |> Enum.map(& &1.library_uuid) |> Libraries.user_or_hidden_among()
    Enum.reject(items, &(to_string(&1.library_uuid) in unlisted))
  end

  defp in_shown_libraries(items, library_uuid),
    do: Enum.filter(items, &(to_string(&1.library_uuid) == to_string(library_uuid)))

  defp visible_to_viewer(items, nil, _library_uuid), do: items

  defp visible_to_viewer(items, viewer_uuid, library_uuid) do
    folders =
      if Enum.any?(items, &match?(%Storage.Folder{}, &1)),
        do: MapSet.new(Storage.viewer_folder_uuids(viewer_uuid, library_uuid), &to_string/1)

    Enum.filter(items, fn
      %Storage.Folder{uuid: uuid} -> MapSet.member?(folders, to_string(uuid))
      file -> Storage.viewer_can_see_file?(viewer_uuid, file)
    end)
  end

  # The selected files and folders this browser shows, loaded and checked in
  # bulk.
  defp shown_selection(socket) do
    files = socket.assigns.selected_files |> load_by_uuid(Storage.File) |> shown_only(socket)

    folders =
      socket.assigns.selected_folders |> load_by_uuid(Storage.Folder) |> shown_only(socket)

    {files, folders}
  end

  defp load_by_uuid(uuids, schema) do
    if Enum.empty?(uuids),
      do: [],
      else:
        PhoenixKit.Config.get_repo().all(from(r in schema, where: r.uuid in ^Enum.to_list(uuids)))
  end

  # The folders of a selection a removal reaches: the ones in the browser's
  # scope. The analysis and the handler read the same set.
  defp folders_in_scope(folders, scope),
    do: Enum.filter(folders, &Storage.within_scope?(&1.uuid, scope))

  defp delete_selected_folders(socket, folders, scope) do
    folders
    |> folders_in_scope(scope)
    |> Enum.map(fn folder ->
      if socket.assigns.filter_trash,
        do: Storage.delete_folder_completely(folder, scope),
        else: Storage.trash_folder(folder, scope)
    end)
  end

  # Storage answers `{:ok, _}`, `{:ok, :trashed | :rehomed | …, _}` or `:ok`
  # when it did what was asked; anything else is a refusal or a failure.
  defp ok_tuple(:ok), do: {:ok, nil}
  defp ok_tuple(result) when is_tuple(result) and elem(result, 0) == :ok, do: {:ok, result}
  defp ok_tuple(other), do: other

  # What to tell the person about the items that stayed. A file or folder that
  # something else still uses (a comment attachment, say) is not a failure of
  # theirs or of the system; it is named as that, and the rest — if any — is not.
  defp not_removed_message(failed) do
    in_use = Enum.count(failed, &match?({:error, :in_use}, &1))
    other = length(failed) - in_use

    [
      if(in_use > 0,
        do:
          ngettext(
            "%{count} item is in use by something else and was kept.",
            "%{count} items are in use by something else and were kept.",
            in_use
          )
      ),
      if(other > 0,
        do:
          ngettext(
            "%{count} item could not be removed.",
            "%{count} items could not be removed.",
            other
          )
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp deleted_selection_message(count, true = _permanent),
    do: ngettext("%{count} item permanently deleted", "%{count} items permanently deleted", count)

  defp deleted_selection_message(count, _),
    do: ngettext("%{count} item moved to trash", "%{count} items moved to trash", count)

  defp managed_folder_message,
    do: gettext("This folder belongs to a module and can't be deleted here.")

  # The folders a write carries the contents of: the one a folder event
  # names (never a move's target), and the selected folders of a bulk
  # action.
  defp acted_on_folders(event, params, _socket) when event in @folder_content_events,
    do: params |> Map.take(["folder_uuid", "id"]) |> Map.values() |> param_uuids([])

  defp acted_on_folders(event, _params, socket) when event in @selection_events,
    do: Enum.to_list(socket.assigns[:selected_folders] || [])

  defp acted_on_folders(_event, _params, _socket), do: []

  # Whether any file homed under `folder_uuids` (their whole subtrees,
  # trashed files included) was uploaded by someone other than `user_uuid`.
  defp others_file_in_folders?([], _user_uuid), do: false

  defp others_file_in_folders?(folder_uuids, user_uuid) do
    subtree = folder_uuids |> Enum.uniq() |> Enum.flat_map(&Storage.folder_subtree_uuids/1)

    subtree != [] and
      PhoenixKit.Config.get_repo().exists?(
        from(f in Storage.File,
          where:
            f.folder_uuid in ^subtree and
              (is_nil(f.user_uuid) or f.user_uuid != type(^user_uuid, UUIDv7))
        )
      )
  end

  # Whether an event must be refused for a restricted viewer: it names a file
  # someone else uploaded or a folder they cannot see, or changes a folder they
  # did not create.
  defp viewer_refused?(event, params, socket) do
    viewer = socket.assigns.viewer_uuid
    repo = PhoenixKit.Config.get_repo()
    uuids = params |> param_uuids([]) |> Enum.uniq()

    folders_changed =
      acted_on_folders(event, params, socket) ++
        if(event in @folder_metadata_events,
          do:
            params
            |> Map.take(["folder_uuid", "folder-uuid", "id"])
            |> Map.values()
            |> param_uuids([]),
          else: []
        )

    others_file_named?(repo, uuids, viewer) or
      invisible_folder_named?(repo, uuids, viewer, socket.assigns[:library_uuid]) or
      folder_not_theirs?(repo, Enum.uniq(folders_changed), viewer)
  end

  defp others_file_named?(_repo, [], _viewer), do: false

  defp others_file_named?(repo, uuids, viewer) do
    repo.exists?(
      from(f in Storage.File,
        where: f.uuid in ^uuids and (is_nil(f.user_uuid) or f.user_uuid != type(^viewer, UUIDv7))
      )
    )
  end

  defp invisible_folder_named?(_repo, [], _viewer, _library), do: false

  defp invisible_folder_named?(repo, uuids, viewer, library_uuid) do
    named = repo.all(from(f in Storage.Folder, where: f.uuid in ^uuids, select: f.uuid))

    named != [] and
      not MapSet.subset?(
        MapSet.new(named, &to_string/1),
        MapSet.new(Storage.viewer_folder_uuids(viewer, library_uuid), &to_string/1)
      )
  end

  defp folder_not_theirs?(_repo, [], _viewer), do: false

  defp folder_not_theirs?(repo, uuids, viewer) do
    repo.exists?(
      from(f in Storage.Folder,
        where: f.uuid in ^uuids and (is_nil(f.user_uuid) or f.user_uuid != type(^viewer, UUIDv7))
      )
    )
  end

  # Whether any of `uuids` is a file someone other than `user_uuid` uploaded.
  defp others_file?([], _user_uuid), do: false

  defp others_file?(uuids, user_uuid) do
    uuids = Enum.uniq(uuids)

    PhoenixKit.Config.get_repo().exists?(
      from(f in Storage.File,
        where:
          f.uuid in ^uuids and
            (is_nil(f.user_uuid) or f.user_uuid != type(^user_uuid, UUIDv7))
      )
    )
  end

  # Whether any uuid in `params` (at any depth) is a file or folder of a
  # library other than `library_uuid`. A uuid that is neither (a variant, a
  # stale id) is not this check's business; the handler deals with it.
  # `library_uuid` nil is a browser that names no library: "outside" is then
  # what a site listing leaves out (user and private libraries).
  @doc false
  def foreign_reference?(params, library_uuid) do
    case param_uuids(params, []) |> Enum.uniq() do
      [] -> false
      uuids -> named_outside_library?(uuids, library_uuid)
    end
  end

  # With no library shown, "outside" is what the site listing leaves out
  # (`Libraries.exclude_user_libraries/1`).
  defp named_outside_library?(uuids, nil) do
    repo = PhoenixKit.Config.get_repo()

    libraries =
      repo.all(from(f in Storage.File, where: f.uuid in ^uuids, select: f.library_uuid)) ++
        repo.all(from(f in Storage.Folder, where: f.uuid in ^uuids, select: f.library_uuid))

    Libraries.user_or_hidden_among(libraries) != []
  end

  defp named_outside_library?(uuids, library_uuid) do
    repo = PhoenixKit.Config.get_repo()

    repo.exists?(
      from(f in Storage.File, where: f.uuid in ^uuids and f.library_uuid != ^library_uuid)
    ) or
      repo.exists?(
        from(f in Storage.Folder, where: f.uuid in ^uuids and f.library_uuid != ^library_uuid)
      )
  end

  defp library_refusal(nil, event) do
    if String.contains?(event, "folder"),
      do: gettext("Folder not found"),
      else: gettext("File not found")
  end

  defp library_refusal(_library_uuid, _event), do: gettext("That is not in this library")

  defp shown_library_label(nil), do: "the site libraries"
  defp shown_library_label(library_uuid), do: "library #{library_uuid}"

  defp param_uuids(%{} = map, acc),
    do: Enum.reduce(map, acc, fn {_k, v}, acc -> param_uuids(v, acc) end)

  defp param_uuids(list, acc) when is_list(list), do: Enum.reduce(list, acc, &param_uuids/2)

  defp param_uuids(value, acc) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> [uuid | acc]
      :error -> acc
    end
  end

  defp param_uuids(_value, acc), do: acc

  defp log_refused(socket, event, why) do
    Logger.warning("MediaBrowser id=#{socket.assigns.id}: #{event} refused — #{why}")
    socket
  end

  defp log_readonly_blocked(socket, event) do
    Logger.warning(
      "MediaBrowser id=#{socket.assigns.id}: #{event} blocked — component is readonly"
    )

    socket
  end

  # Returns a flash message when folder creation isn't allowed in the current
  # view (trash / all-files), or nil when it's fine.
  defp folder_creation_block(socket) do
    cond do
      socket.assigns[:filter_trash] ->
        gettext("Cannot create folders in trash")

      socket.assigns[:file_view] == "all" ->
        gettext("Cannot create folders in the all-files view")

      true ->
        nil
    end
  end

  defp next_untitled_name(parent_uuid, scope, lib) do
    base = gettext("untitled")

    existing =
      parent_uuid
      |> Storage.list_folders(scope, lib)
      |> Enum.map(& &1.name)
      |> MapSet.new()

    if MapSet.member?(existing, base) do
      n =
        Stream.iterate(1, &(&1 + 1))
        |> Enum.find(fn n -> not MapSet.member?(existing, "#{base} #{n}") end)

      "#{base} #{n}"
    else
      base
    end
  end

  defp auto_expand_breadcrumbs(socket, breadcrumbs) do
    ancestor_uuids = Enum.map(breadcrumbs, & &1.uuid)
    expanded = Enum.reduce(ancestor_uuids, socket.assigns.expanded_folders, &MapSet.put(&2, &1))
    assign(socket, :expanded_folders, expanded)
  end

  defp expand_sidebar_folder(socket, nil), do: socket

  defp expand_sidebar_folder(socket, folder_uuid) do
    assign(socket, :expanded_folders, MapSet.put(socket.assigns.expanded_folders, folder_uuid))
  end
end
