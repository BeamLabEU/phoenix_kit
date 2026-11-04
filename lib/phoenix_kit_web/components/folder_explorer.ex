defmodule PhoenixKitWeb.Components.FolderExplorer do
  @moduledoc """
  Reusable folder explorer sidebar — folder tree, navigation buttons,
  inline rename, and (optional) Trash / All Files / New Folder controls.

  Extracted from `PhoenixKitWeb.Components.MediaBrowser` so other LiveViews
  can embed folder navigation (folder pickers, category browsers, etc.)
  without duplicating the markup.

  ## Ownership model

  Pure presentation function component. The consumer owns all state and
  event handlers; FolderExplorer just renders. Every interactive control
  fires `phx-target={@myself}` back to the consumer, so the consumer must
  implement the relevant `handle_event/3` clauses:

      navigate_folder, navigate_root, navigate_view_all,
      toggle_folder_expand, toggle_sidebar, open_new_folder_modal,
      start_rename_folder, rename_folder_input, rename_folder,
      cancel_rename_folder, toggle_trash_filter

  **From a plain LiveView**, pass `myself={nil}`: HEEx omits a nil attribute,
  so no `phx-target` is rendered and the events arrive at the LiveView. The
  event names are not configurable — implement this vocabulary rather than
  fork the component.

  The drag-drop data attributes (`data-drop-folder`, `data-draggable-folder`,
  `data-draggable-file`, `data-drop-trash`) are emitted unless
  `enable_drag={false}`; consumers that wire up the `MediaDragDrop` JS hook get
  drag-drop for free, others can ignore them. `drop_only` keeps just the drop
  targets (`data-drop-folder`) when `enable_drag` is off: the tree takes a drop
  but nothing in it is dragged, and the Trash takes none.

  ## Showing what is in the folders

  By default this is a tree of folders and nothing else, which is what a media
  browser wants — its files live in a grid beside the tree. A consumer whose
  leaves *are* the point (a vault of notes, a file manager) passes `items` and
  an `:item` slot, and the leaves render inside their folders the way Obsidian
  and Finder show them:

      <.folder_explorer
        folder_tree={@folder_tree}
        items={%{"root" => @root_notes, folder_uuid => @notes_in_folder}}
        …
      >
        <:item :let={note}>
          <.link patch={~p"/notes/\#{note.id}"}>{note.label}</.link>
        </:item>
      </.folder_explorer>

  Items are keyed by folder uuid, with `"root"` for the top level, and each
  needs an `:id` — that is what `data-draggable-file` carries, so a leaf is
  draggable on the same terms as a folder. A folder holding only leaves still
  gets a chevron.

  ## Right-click menus

  Every folder row and leaf row carries the attributes `Core.ContextMenu`
  reads, so a consumer gets right-click / touch-and-hold menus by declaring
  the menus — the explorer needs no flag and no slot:

      <.context_menu
        id="folder-menu"
        selector="[data-context-kind=folder]"
        value_name={["folder-uuid", "folder_uuid"]}
      >
        <.context_menu_button phx-click="start_rename_folder" phx-value-source="sidebar" … />
      </.context_menu>

  `data-context-kind` is `"folder"` or `"item"`, `data-context-value` is the
  uuid, `data-context-label` the name. They sit on the folder row `<div>` and
  the leaf `<li>` — never on the wrapping `<li>` of a folder — so a right-click
  on a nested row resolves to that row and not to its ancestor folder.

  Consumers that declare no menu pay three attributes per row and get the
  browser's own menu, unchanged.

  ## A consumer's folder is its own

  `folder.color` is read through `folder_color/1` (`Map.get/2`), because a
  consumer's folder schema is not `PhoenixKit.Media.Folder` and need not have
  the concept. Reading the field directly raised `KeyError` and took the page
  down the moment such a consumer had one folder.

  ## Usage

      <.folder_explorer
        id="my-folder-explorer"
        myself={@myself}
        folder_tree={@folder_tree}
        current_folder={@current_folder}
        expanded_folders={@expanded_folders}
        scope_folder_id={@scope_folder_id}
        scope_folder_name={@scope_folder_name}
        renaming_folder={@renaming_folder}
        renaming_source={@renaming_source}
        renaming_text={@renaming_text}
        filter_trash={@filter_trash}
        file_view={@file_view}
        sidebar_collapsed={@sidebar_collapsed}
        trash_count={@trash_count}
      />

  ## Config flags

  - `show_create` (default `true`) — show the `+` toolbar button.
  - `show_all_files` (default `true`) — show the "All Files" flat-view button
    (only renders when `scope_folder_id` is `nil`; the flag gates that branch).
  - `show_trash` (default `true`) — show the Trash button + badge.

  Folder-color helpers (`folder_color_hex/1`, `folder_icon_style/2`,
  `folder_bg_style/1`) live here too since the sidebar and the grid/list
  folder cards in MediaBrowser both consume them.
  """

  use PhoenixKitWeb, :html

  alias Phoenix.LiveView.JS

  # ──────────────────────────────────────────────────────────────
  # Top-level component
  # ──────────────────────────────────────────────────────────────

  attr :id, :string, default: "folder-explorer"

  attr :myself, :any,
    default: nil,
    doc:
      "The consuming LiveComponent's `@myself`. Pass `nil` from a plain " <>
        "LiveView: HEEx omits a nil attribute, so `phx-target` is not " <>
        "rendered and the events arrive at the LiveView itself."

  attr :folder_tree, :any, required: true
  attr :current_folder, :any, default: nil
  attr :expanded_folders, :any, required: true
  attr :scope_folder_id, :any, default: nil
  attr :scope_folder_name, :string, default: "Root"

  attr :renaming_folder, :any, default: nil
  attr :renaming_source, :any, default: nil
  attr :renaming_text, :string, default: ""

  attr :filter_trash, :boolean, default: false
  attr :file_view, :string, default: nil

  attr :sidebar_collapsed, :boolean, default: false

  attr :sidebar_rev, :integer,
    default: 0,
    doc: """
    Bump it whenever the SERVER changes `sidebar_collapsed` on its own (not in
    answer to the chevron). The chevron flips the panes client-side, and
    LiveView keeps a `JS` class change sticky: it is re-applied after every
    patch, over whatever class the server renders. So a server-side
    `sidebar_collapsed: false` alone changed nothing on screen, and left the
    assign and the DOM disagreeing until a reload. The revision is part of the
    panes' ids, so a bump replaces them and the sticky change goes with them.
    """

  attr :trash_count, :integer, default: 0

  attr :show_create, :boolean, default: true
  attr :show_all_files, :boolean, default: true
  attr :show_trash, :boolean, default: true

  attr :show_rename, :boolean,
    default: true,
    doc: "Show the inline rename affordance on each folder."

  attr :items, :any,
    default: %{},
    doc: """
    Leaf rows to show *inside* folders, as `%{folder_uuid => [item]}`. Items at
    the top level go under the key `"root"`.

    A folder tree that cannot show what is in the folders is half a tree: a
    vault of markdown files, or any consumer whose leaves are the point, needs
    the files interleaved with the folders the way a file manager does it.
    Empty by default, which is the folders-only tree MediaBrowser renders.

    Each item must be a map with an `:id`. That is what
    `data-draggable-file` carries, so items are draggable on the same terms as
    folders with no work from the consumer.
    """

  attr :enable_drag, :boolean,
    default: true,
    doc:
      "Emit the drag-drop data attributes. Off for a consumer with no move " <>
        "handlers, so folders are not draggable into a void."

  attr :drop_only, :boolean,
    default: false,
    doc:
      "With `enable_drag` off, still emit `data-drop-folder` (the top level and every " <>
        "folder take a drop) but not the draggable folders nor the Trash drop."

  attr :class, :any,
    default: "hidden lg:block",
    doc:
      "Visibility/extra classes for the wrapper. The default reproduces the " <>
        "MediaBrowser behavior (desktop-only sidebar); consumers embedding the " <>
        "explorer elsewhere can lower the breakpoint (e.g. \"hidden md:block\")."

  slot :item,
    doc: """
    How one leaf row renders, given the item. Without it a row shows
    `item.label` (or `item.name`) as plain text — enough to see the tree, not
    enough to click it, so a real consumer passes this.
    """

  def folder_explorer(assigns) do
    # UUIDs on the path from a root folder down to (and including) the
    # current folder. Each node's guide-line connector is darkened when its
    # uuid is in this set, so the user can trace the branch they're inside.
    assigns =
      assign(
        assigns,
        :active_path,
        active_path_uuids(assigns.folder_tree, assigns.current_folder)
      )

    ~H"""
    <%!-- Both states stay in the DOM and the chevrons swap them CLIENT-side
         (JS.toggle_class) before pushing toggle_sidebar — collapsing used to
         wait a full round trip plus the re-render it dragged in, which read
         as the chevron being slow. The server still hears the event, so the
         assign (and the persisted preference) catch up, and its re-render
         then agrees with what the client already shows. The container takes
         no width of its own: whichever pane is visible sizes it. --%>
    <div id={@id} class={[@class, "shrink-0 h-full min-h-0"]}>
      <%!-- Collapsed strip --%>
      <div
        id={"#{@id}-collapsed-#{@sidebar_rev}"}
        class={["w-10", !@sidebar_collapsed && "hidden"]}
      >
        <button
          phx-click={toggle_sidebar_js(@id, @sidebar_rev, @myself)}
          class="btn btn-ghost btn-sm w-full"
          title={gettext("Show folders")}
        >
          <.icon name="hero-chevron-right" class="w-4 h-4" />
        </button>
      </div>
      <%!-- Expanded sidebar (wrapper, so visibility is a plain block-level
           `hidden` toggle that cannot fight the inner pane's `flex`) --%>
      <div
        id={"#{@id}-expanded-#{@sidebar_rev}"}
        class={["h-full min-h-0", @sidebar_collapsed && "hidden"]}
      >
        <div
          class="h-full min-h-0 flex flex-col border-r border-base-200 pr-3 mr-3 overflow-hidden"
          style="width: 240px; max-width: 240px;"
        >
          <div class="flex items-center justify-between mb-3">
            <h3 class="font-semibold text-sm text-base-content/70 uppercase tracking-wider">
              {gettext("Folders")}
            </h3>
            <div class="flex gap-0.5">
              <button
                :if={@show_create}
                phx-click="open_new_folder_modal"
                phx-target={@myself}
                class="btn btn-ghost btn-xs"
                title={gettext("New folder")}
              >
                <.icon name="hero-folder-plus" class="w-4 h-4" />
              </button>
              <button
                phx-click={toggle_sidebar_js(@id, @sidebar_rev, @myself)}
                class="btn btn-ghost btn-xs"
                title={gettext("Collapse sidebar")}
              >
                <.icon name="hero-chevron-left" class="w-4 h-4" />
              </button>
            </div>
          </div>

          <%!-- All Files flat view (only when unscoped — admin media page) --%>
          <%= if @show_all_files and is_nil(@scope_folder_id) do %>
            <button
              phx-click="navigate_view_all"
              title={gettext("Every file, whichever folder it is in")}
              phx-target={@myself}
              class={[
                "flex items-center gap-2 w-full px-2 py-1.5 rounded-lg text-sm transition-colors mb-1 text-left",
                if(@file_view == "all" and not @filter_trash,
                  do: "bg-primary/10 font-semibold text-primary",
                  else: "hover:bg-base-200"
                )
              ]}
            >
              <.icon name="hero-rectangle-stack" class="w-4 h-4 shrink-0" /> {gettext("All Files")}
            </button>
          <% end %>

          <%!-- Top level (navigate to the real root folder): the files that are in no
               folder, and the folders. Not every file; "All Files" is that. --%>
          <button
            phx-click="navigate_root"
            title={
              if is_nil(@scope_folder_id),
                do: gettext("Files that are in no folder, and the top folders")
            }
            phx-target={@myself}
            data-drop-folder={(@enable_drag || @drop_only) && "root"}
            class={[
              "flex items-center gap-2 w-full px-2 py-1.5 rounded-lg text-sm transition-colors mb-1 text-left",
              if(@current_folder == nil and @file_view != "all" and not @filter_trash,
                do: "bg-primary/10 font-semibold text-primary",
                else: "hover:bg-base-200"
              )
            ]}
          >
            <.icon name="hero-inbox" class="w-4 h-4 shrink-0" />
            {if @scope_folder_id, do: @scope_folder_name, else: gettext("Top level")}
          </button>

          <div class="divider my-1 h-0"></div>

          <%!-- Folder Tree --%>
          <%!-- Scrolls both ways: deep folders extend past the 240px width and
               keep their full names (no truncation); scroll right to read them.

               [scrollbar-gutter:stable]: navigating expands and collapses
               nodes, so the list crosses its own scroll threshold constantly.
               Without a reserved gutter the 15px bar appears and disappears
               and every row — icon included — jumps sideways with it. --%>
          <ul class="space-y-0.5 w-full min-h-0 flex-1 overflow-auto pr-1 [scrollbar-gutter:stable]">
            <%= for node <- @folder_tree do %>
              <.folder_tree_node
                node={node}
                current_folder={@current_folder}
                active_path={@active_path}
                expanded_folders={@expanded_folders}
                renaming_folder={@renaming_folder}
                renaming_source={@renaming_source}
                renaming_text={@renaming_text}
                filter_trash={@filter_trash}
                depth={0}
                myself={@myself}
                show_rename={@show_rename}
                enable_drag={@enable_drag}
                drop_only={@drop_only}
                items={@items}
                item={@item}
              />
            <% end %>

            <%!-- Items at the vault root, after the folders, as a file
                 manager orders them. --%>
            <.tree_item
              :for={entry <- items_for(@items, "root")}
              entry={entry}
              enable_drag={@enable_drag}
              item={@item}
            />
          </ul>

          <%!-- Trash --%>
          <%= if @show_trash do %>
            <div class="divider my-1 h-0"></div>
            <button
              phx-click="toggle_trash_filter"
              phx-target={@myself}
              data-drop-trash={@enable_drag && "true"}
              class={[
                "flex items-center gap-2 px-2 py-1.5 rounded-lg text-sm transition-colors w-full",
                if(@filter_trash,
                  do: "bg-error/10 font-semibold text-error",
                  else: "hover:bg-base-200 text-base-content/60"
                )
              ]}
            >
              <.icon name="hero-trash" class="w-4 h-4 shrink-0" /> {gettext("Trash")}
              <%= if @trash_count > 0 do %>
                <span class="badge badge-sm badge-error ml-auto">{@trash_count}</span>
              <% end %>
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # The optimistic half of the sidebar toggle: swap the two panes in the
  # DOM this instant, then tell the server — which flips the assign,
  # persists the preference, and re-renders to the same picture.
  defp toggle_sidebar_js(id, rev, myself) do
    js =
      %JS{}
      |> JS.toggle_class("hidden", to: "##{id}-collapsed-#{rev}")
      |> JS.toggle_class("hidden", to: "##{id}-expanded-#{rev}")

    if myself,
      do: JS.push(js, "toggle_sidebar", target: myself),
      else: JS.push(js, "toggle_sidebar")
  end

  # ──────────────────────────────────────────────────────────────
  # Leaf row
  # ──────────────────────────────────────────────────────────────

  attr :entry, :map, required: true
  attr :enable_drag, :boolean, default: true
  attr :item, :any, default: []

  @doc false
  # One leaf inside a folder. The `<li>` carries `data-draggable-file`, so an
  # item is draggable on the same terms as a folder and the consumer's slot can
  # stay a plain row — the drag-drop hook finds it either way.
  def tree_item(assigns) do
    ~H"""
    <li
      data-draggable-file={@enable_drag && Map.get(@entry, :id)}
      data-context-kind="item"
      data-context-value={Map.get(@entry, :id)}
      data-context-label={Map.get(@entry, :label) || Map.get(@entry, :name)}
      class="pl-5 pr-1 rounded hover:bg-base-200"
    >
      <%= if @item == [] do %>
        <span class="block text-sm truncate py-1 text-base-content/70">
          {Map.get(@entry, :label) || Map.get(@entry, :name)}
        </span>
      <% else %>
        {render_slot(@item, @entry)}
      <% end %>
    </li>
    """
  end

  @doc false
  # Leaves for one folder. Tolerant of a missing key and of a `nil` map, so a
  # consumer can pass items for the two folders it cares about.
  def items_for(items, key) when is_map(items), do: Map.get(items, key, [])
  def items_for(_items, _key), do: []

  # ──────────────────────────────────────────────────────────────
  # Recursive tree node
  # ──────────────────────────────────────────────────────────────

  attr :node, :map, required: true
  attr :current_folder, :any, required: true

  attr :active_path, :any,
    default: MapSet.new(),
    doc: "UUIDs from a root folder to the current folder; darkens their connector lines."

  attr :connector_mode, :atom,
    default: :normal,
    values: [:normal, :active_trunk, :active_turn],
    doc:
      "How this node's guide line is drawn: normal, a darkened pass-through trunk, or the darkened turn into the active branch."

  attr :expanded_folders, :any, required: true
  attr :renaming_folder, :any, default: nil
  attr :renaming_text, :string, default: ""
  attr :renaming_source, :any, default: nil
  attr :filter_trash, :boolean, default: false
  attr :depth, :integer, default: 0
  attr :myself, :any, default: nil
  attr :items, :any, default: %{}
  # The `:item` slot, forwarded down the recursion as a plain assign — a slot
  # is a list of maps, so it travels as an attr without ceremony.
  attr :item, :any, default: []

  # Behavior config so the same recursive node powers both the sidebar and the
  # move-destination picker. Defaults reproduce the sidebar; the move modal
  # passes its own select/toggle events and turns off rename + drag.
  attr :on_navigate, :string,
    default: "navigate_folder",
    doc: "Event fired when a folder row/name is clicked (sidebar navigates, move modal selects)."

  attr :on_toggle, :string,
    default: "toggle_folder_expand",
    doc: "Event fired by the disclosure chevron."

  attr :show_rename, :boolean, default: true, doc: "Show the inline rename affordance."
  attr :enable_drag, :boolean, default: true, doc: "Emit drag-drop data attributes."
  attr :drop_only, :boolean, default: false, doc: "Emit `data-drop-folder` with drag off."
  attr :hover_class, :string, default: "hover:bg-base-200", doc: "Row hover background utility."

  def folder_tree_node(assigns) do
    # In trash view no folder is "active" in the file sense — the user is
    # looking at trashed files, not a folder's contents. We keep
    # `@current_folder` populated in the socket so toggling trash off
    # restores the previous folder, but the tree highlight is suppressed
    # while filter_trash is on (the sidebar Trash button carries the
    # active highlight instead).
    assigns =
      assign(
        assigns,
        :is_active,
        (not assigns.filter_trash and assigns.current_folder) &&
          assigns.current_folder.uuid == assigns.node.folder.uuid
      )

    assigns =
      assign(
        assigns,
        :is_expanded,
        MapSet.member?(assigns.expanded_folders, assigns.node.folder.uuid)
      )

    assigns = assign(assigns, :has_children, assigns.node.children != [])
    assigns = assign(assigns, :node_items, items_for(assigns.items, assigns.node.folder.uuid))

    # `has_children` stays folder-only: the connector geometry is drawn from
    # it, and changing its meaning would move lines under MediaBrowser, which
    # passes no items. Expansion is the thing that has to widen — a folder
    # holding nothing but notes still opens.
    assigns =
      assign(assigns, :expandable?, assigns.has_children or assigns.node_items != [])

    assigns =
      assign(
        assigns,
        :is_renaming,
        (assigns.show_rename and
           assigns.renaming_folder == assigns.node.folder.uuid) &&
          assigns.renaming_source == "sidebar"
      )

    # This node's own connector style comes from its parent (`@connector_mode`).
    # For ITS children we find which one (if any) continues the active branch:
    # children above it get a darkened vertical trunk (`:active_trunk`), the
    # branch child itself gets the darkened turn (`:active_turn`), the rest stay
    # normal. Suppressed in trash view (the tree highlight is off there).
    assigns =
      assign(
        assigns,
        :on_path_child_index,
        if(assigns.filter_trash,
          do: nil,
          else:
            Enum.find_index(
              assigns.node.children,
              &MapSet.member?(assigns.active_path, &1.folder.uuid)
            )
        )
      )

    assigns =
      assign(
        assigns,
        :tree_connector_class,
        tree_connector_class(assigns.depth, assigns.has_children, assigns.connector_mode)
      )

    ~H"""
    <li class={[@tree_connector_class]}>
      <%!--
        Whole row is clickable to open the folder. LiveView resolves a click
        to the closest `phx-click` element, so the nested chevron (toggle) and
        rename buttons still handle their own clicks — only clicks elsewhere on
        the row fall through to `navigate_folder`. The click is suppressed while
        the inline rename form is open so clicking the text field doesn't
        navigate away. The inner folder button is kept for keyboard access.
      --%>
      <div
        phx-click={!@is_renaming && @on_navigate}
        phx-target={@myself}
        phx-value-folder-uuid={@node.folder.uuid}
        data-context-kind="folder"
        data-context-value={@node.folder.uuid}
        data-context-label={@node.folder.name}
        class={[
          "flex items-center gap-0.5 rounded-lg px-1 py-1 transition-colors group min-w-max",
          @hover_class,
          !@is_renaming && "cursor-pointer",
          @is_active && "font-semibold"
        ]}
        style={
          if @is_active,
            do:
              "background-color: #{folder_color_hex(folder_color(@node.folder)) || "oklch(var(--p))"}25"
        }
      >
        <%!--
          Chevron (expand/collapse). While its click waits on the server
          (`.phx-click-loading` on this button) the chevron turns into a
          spinner. The `>` variant keys on the button itself, not on the row
          around it, so opening the folder spins the row's icon only.

          Chevron and spinner are stacked in the same 16px box rather than
          swapped in the flow: trading one for the other used to resize the
          box (the icon is w-4, daisyUI's `loading-xs` 14px) and slide the
          rest of the row sideways and back on every click.

          The spinner only fades in after 300ms of waiting. `delay-300`
          applies while `.phx-click-loading` is on and NOT when it comes off,
          so a reply that beats the delay never starts the fade and shows
          nothing at all — no blink on a fast click — while a slow one still
          says "working". Same treatment on the folder icon below.
        --%>
        <%= if @expandable? do %>
          <button
            phx-click={@on_toggle}
            phx-target={@myself}
            phx-value-folder-uuid={@node.folder.uuid}
            class="btn btn-ghost btn-xs p-0 min-h-0 h-5 w-5 relative"
          >
            <.icon
              name={if @is_expanded, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
              class="absolute inset-0 m-auto w-4 h-4 text-base-content/40 transition-opacity duration-100 [.phx-click-loading>&]:opacity-0 [.phx-click-loading>&]:delay-300"
            />
            <span class="absolute inset-0 m-auto loading loading-spinner w-4 h-4 text-base-content/40 opacity-0 transition-opacity duration-100 [.phx-click-loading>&]:opacity-100 [.phx-click-loading>&]:delay-300"></span>
          </button>
        <% else %>
          <span class="w-5"></span>
        <% end %>

        <%= if @is_renaming do %>
          <%!-- Inline rename form --%>
          <form
            id={"folder-tree-rename-form-#{@node.folder.uuid}"}
            phx-submit="rename_folder"
            phx-change="rename_folder_input"
            phx-target={@myself}
            class="flex items-center gap-1.5 flex-1 min-w-0"
          >
            <input type="hidden" name="folder_uuid" value={@node.folder.uuid} />
            <span style={folder_icon_style(folder_color(@node.folder))}>
              <.icon name="hero-folder" class="w-4 h-4 shrink-0" />
            </span>
            <%!--
              Minimal bordered input — pairs with the row's
              `ring-2 ring-primary` above. Sits flush with the row's
              natural height (no daisyUI `input input-bordered input-xs`
              chunkiness) and uses a thin primary border + white bg so
              it reads as "edit field" without overwhelming the row.
            --%>
            <input
              type="text"
              name="name"
              id={"rename-folder-#{@node.folder.uuid}"}
              value={@renaming_text}
              class="bg-base-100 text-sm rounded px-1.5 py-0 flex-1 min-w-0 border border-primary/60 focus:outline-none focus:border-primary"
              phx-hook="SelectOnMount"
              required
              phx-keydown="cancel_rename_folder"
              phx-key="Escape"
              phx-blur="cancel_rename_folder"
              phx-target={@myself}
              phx-debounce="50"
            />
          </form>
        <% else %>
          <%!--
            Folder button (uncontrolled: phx-click instead of .link navigate).
            Opening a folder replies only once the new listing has rendered,
            so the icon turns into a spinner for as long as that takes —
            whether the click landed on this button or on the row around it.
          --%>
          <button
            phx-click={@on_navigate}
            phx-target={@myself}
            phx-value-folder-uuid={@node.folder.uuid}
            data-drop-folder={(@enable_drag || @drop_only) && @node.folder.uuid}
            data-draggable-folder={@enable_drag && @node.folder.uuid}
            class="flex items-center gap-1.5 flex-1 text-sm text-left"
          >
            <%!-- Stacked, and delayed by 300ms — see the chevron above. --%>
            <span
              class="relative block w-4 h-4 shrink-0"
              style={folder_icon_style(folder_color(@node.folder), @is_active)}
            >
              <.icon
                name={if @is_expanded, do: "hero-folder-open", else: "hero-folder"}
                class="absolute inset-0 w-4 h-4 transition-opacity duration-100 [.phx-click-loading_&]:opacity-0 [.phx-click-loading_&]:delay-300"
              />
              <span class="absolute inset-0 loading loading-spinner w-4 h-4 opacity-0 transition-opacity duration-100 [.phx-click-loading_&]:opacity-100 [.phx-click-loading_&]:delay-300"></span>
            </span>
            <span
              class={[
                "whitespace-nowrap block",
                @renaming_folder == @node.folder.uuid && !@is_renaming && "renaming-preview"
              ]}
              title={@node.folder.name}
            >
              <%= if @renaming_folder == @node.folder.uuid && @renaming_text != "" do %>
                {@renaming_text}
              <% else %>
                {@node.folder.name}
              <% end %>
            </span>
          </button>
          <%!-- Rename button (visible on hover) --%>
          <button
            :if={@show_rename}
            phx-click="start_rename_folder"
            phx-target={@myself}
            phx-value-folder-uuid={@node.folder.uuid}
            phx-value-source="sidebar"
            class="btn btn-ghost btn-xs p-0 min-h-0 h-5 w-5 opacity-0 group-hover:opacity-100"
            title={gettext("Rename")}
          >
            <.icon name="hero-pencil" class="w-3 h-3 text-base-content/40" />
          </button>
        <% end %>
      </div>

      <%!-- Children (expanded) --%>
      <%= if @expandable? && @is_expanded do %>
        <%!--
          Tree guide lines are drawn per child <li> (see the connector
          classes on the <li> below), not as a single full-height border on
          this <ul>. That lets the LAST child's vertical segment stop at its
          own row and curl right (an elbow), instead of the line overshooting
          past the last item. The parent folder's color is handed down as an
          inheriting CSS variable so every child connector picks it up; a
          deeper nested <ul> overrides it with its own folder color.
        --%>
        <ul
          class="ml-3"
          style={"--pk-tree-line: #{tree_line_color(folder_color(@node.folder))}; --pk-tree-line-active: #{tree_line_color_active(folder_color(@node.folder))}"}
        >
          <%= for {child, idx} <- Enum.with_index(@node.children) do %>
            <.folder_tree_node
              node={child}
              current_folder={@current_folder}
              active_path={@active_path}
              connector_mode={child_connector_mode(@on_path_child_index, idx)}
              expanded_folders={@expanded_folders}
              renaming_folder={@renaming_folder}
              renaming_source={@renaming_source}
              renaming_text={@renaming_text}
              filter_trash={@filter_trash}
              depth={@depth + 1}
              myself={@myself}
              on_navigate={@on_navigate}
              on_toggle={@on_toggle}
              show_rename={@show_rename}
              enable_drag={@enable_drag}
              drop_only={@drop_only}
              hover_class={@hover_class}
              items={@items}
              item={@item}
            />
          <% end %>

          <%!-- This folder's own leaves, after its subfolders. --%>
          <.tree_item
            :for={entry <- @node_items}
            entry={entry}
            enable_drag={@enable_drag}
            item={@item}
          />
        </ul>
      <% end %>
    </li>
    """
  end

  # Tree guide-line connector for a nested row (`depth > 0`). Returns a
  # literal Tailwind class string (kept whole so the JIT picks it up — never
  # interpolate the utility tokens):
  #
  #   * a vertical line down the row's left edge (`before`), full height so it
  #     flows to the next sibling — `last:` shortens it to the row's center and
  #     turns it into a left+bottom bordered box with a rounded corner, so the
  #     last row curls right into the folder instead of overshooting.
  #   * a horizontal elbow into the row (`after`, hidden on the last row since
  #     the bordered box already draws it).
  #
  # The elbow length depends on whether the row has a disclosure chevron: a
  # childless row runs the line across its empty chevron column right up to the
  # folder icon (`w-9`), while a row with a chevron stops the line at the
  # chevron (`w-4`) so it never crosses the `>` glyph. Root rows (`depth == 0`)
  # get no connector.
  # Color for the tree guide lines (`--pk-tree-line`), rendered at 50% opacity
  # so the lines read lighter rather than a solid, dark stroke. A colored folder
  # uses its hex with a `80` alpha suffix (~50%); an uncolored folder uses the
  # theme text color at 50% via `color-mix` (theme-adaptive — dark in light
  # mode, light in dark mode). The previous `oklch(var(--bc) / …)` neutral was
  # invalid under daisyUI 5's renamed variables, so its border fell back to a
  # solid-black `currentColor`.
  @doc false
  def tree_line_color(color) do
    case folder_color_hex(color) do
      nil -> "color-mix(in oklab, currentColor 50%, transparent)"
      hex -> hex <> "80"
    end
  end

  # Darker (less transparent) variant of the same line color, used for the
  # connectors on the active root→current branch — same hue, just bolder. A
  # colored folder bumps alpha `80` (~50%) → `E6` (~90%); the neutral falls
  # back to currentColor at 85% (still theme-adaptive, not solid black).
  @doc false
  def tree_line_color_active(color) do
    case folder_color_hex(color) do
      nil -> "color-mix(in oklab, currentColor 85%, transparent)"
      hex -> hex <> "E6"
    end
  end

  # Which connector mode a child renders, given the index of the branch child
  # in the same group (or nil when none): everything above the branch child is
  # a darkened pass-through trunk, the branch child is the darkened turn, the
  # rest are normal.
  defp child_connector_mode(nil, _idx), do: :normal
  defp child_connector_mode(branch_idx, idx) when idx < branch_idx, do: :active_trunk
  defp child_connector_mode(branch_idx, idx) when idx == branch_idx, do: :active_turn
  defp child_connector_mode(_branch_idx, _idx), do: :normal

  # Connector classes are returned as whole literal Tailwind strings (never
  # interpolate the utility tokens — the JIT scans source for complete class
  # names, so each variant is spelled out in full).
  #
  # Three modes:
  #   * :normal       — light vertical trunk + light elbow into the row.
  #   * :active_trunk — the active branch descends PAST this side row, so its
  #                     vertical trunk is darkened while the elbow into the row
  #                     stays light (the path doesn't enter here).
  #   * :active_turn  — the active branch turns INTO this row. The trunk stays
  #                     light so it can continue down to later siblings, and a
  #                     darkened L-elbow (`after`) draws the turn over its top.
  #                     A last child has no trunk below, so its `before` becomes
  #                     the darkened elbow instead.
  #
  # `w-4` vs `w-9`: a row with a disclosure chevron stops the elbow at the
  # chevron (`w-4`); a childless row runs it across the empty chevron column to
  # the folder icon (`w-9`).
  @doc false
  def tree_connector_class(0, _has_children, _mode), do: false

  def tree_connector_class(_depth, true = _has_children, :normal) do
    "relative pl-3.5 " <>
      "before:content-[''] before:absolute before:left-0 before:top-0 before:h-full before:w-0.5 before:bg-[var(--pk-tree-line)] " <>
      "after:content-[''] after:absolute after:left-0 after:top-[0.8125rem] after:h-0.5 after:w-4 after:bg-[var(--pk-tree-line)] " <>
      "last:before:h-[0.875rem] last:before:w-4 last:before:bg-transparent " <>
      "last:before:border-l-2 last:before:border-b-2 last:before:border-[var(--pk-tree-line)] last:before:rounded-bl-lg " <>
      "last:after:hidden"
  end

  def tree_connector_class(_depth, false = _has_children, :normal) do
    "relative pl-3.5 " <>
      "before:content-[''] before:absolute before:left-0 before:top-0 before:h-full before:w-0.5 before:bg-[var(--pk-tree-line)] " <>
      "after:content-[''] after:absolute after:left-0 after:top-[0.8125rem] after:h-0.5 after:w-9 after:bg-[var(--pk-tree-line)] " <>
      "last:before:h-[0.875rem] last:before:w-9 last:before:bg-transparent " <>
      "last:before:border-l-2 last:before:border-b-2 last:before:border-[var(--pk-tree-line)] last:before:rounded-bl-lg " <>
      "last:after:hidden"
  end

  def tree_connector_class(_depth, true = _has_children, :active_trunk) do
    "relative pl-3.5 " <>
      "before:content-[''] before:absolute before:left-[-1px] before:top-0 before:h-full before:w-1 before:bg-[var(--pk-tree-line-active)] " <>
      "after:content-[''] after:absolute after:left-0 after:top-[0.8125rem] after:h-0.5 after:w-4 after:bg-[var(--pk-tree-line)] " <>
      "last:before:h-[0.875rem] last:before:w-4 last:before:bg-transparent " <>
      "last:before:left-[-1px] last:before:border-l-4 last:before:border-b-4 last:before:border-[var(--pk-tree-line-active)] last:before:rounded-bl-lg " <>
      "last:after:hidden"
  end

  def tree_connector_class(_depth, false = _has_children, :active_trunk) do
    "relative pl-3.5 " <>
      "before:content-[''] before:absolute before:left-[-1px] before:top-0 before:h-full before:w-1 before:bg-[var(--pk-tree-line-active)] " <>
      "after:content-[''] after:absolute after:left-0 after:top-[0.8125rem] after:h-0.5 after:w-9 after:bg-[var(--pk-tree-line)] " <>
      "last:before:h-[0.875rem] last:before:w-9 last:before:bg-transparent " <>
      "last:before:left-[-1px] last:before:border-l-4 last:before:border-b-4 last:before:border-[var(--pk-tree-line-active)] last:before:rounded-bl-lg " <>
      "last:after:hidden"
  end

  def tree_connector_class(_depth, true = _has_children, :active_turn) do
    "relative pl-3.5 " <>
      "before:content-[''] before:absolute before:left-0 before:top-0 before:h-full before:w-0.5 before:bg-[var(--pk-tree-line)] " <>
      "after:content-[''] after:absolute after:left-[-1px] after:top-0 after:h-[0.8125rem] after:w-4 after:bg-transparent " <>
      "after:border-l-4 after:border-b-4 after:border-[var(--pk-tree-line-active)] after:rounded-bl-[0.15rem] " <>
      "last:before:h-[0.875rem] last:before:w-4 last:before:bg-transparent " <>
      "last:before:left-[-1px] last:before:border-l-4 last:before:border-b-4 last:before:border-[var(--pk-tree-line-active)] last:before:rounded-bl-lg " <>
      "last:after:hidden"
  end

  def tree_connector_class(_depth, false = _has_children, :active_turn) do
    "relative pl-3.5 " <>
      "before:content-[''] before:absolute before:left-0 before:top-0 before:h-full before:w-0.5 before:bg-[var(--pk-tree-line)] " <>
      "after:content-[''] after:absolute after:left-[-1px] after:top-0 after:h-[0.8125rem] after:w-9 after:bg-transparent " <>
      "after:border-l-4 after:border-b-4 after:border-[var(--pk-tree-line-active)] after:rounded-bl-[0.15rem] " <>
      "last:before:h-[0.875rem] last:before:w-9 last:before:bg-transparent " <>
      "last:before:left-[-1px] last:before:border-l-4 last:before:border-b-4 last:before:border-[var(--pk-tree-line-active)] last:before:rounded-bl-lg " <>
      "last:after:hidden"
  end

  # ──────────────────────────────────────────────────────────────
  # Active-branch path (root → current folder)
  # ──────────────────────────────────────────────────────────────

  # Set of folder UUIDs on the path from a root node down to (and including)
  # the current folder. Empty when there is no current folder or it isn't in
  # the tree. Walks the already-nested tree, so it's O(n) over visible nodes.
  @doc false
  def active_path_uuids(_tree, nil), do: MapSet.new()

  def active_path_uuids(tree, current_folder) do
    case find_node_path(tree, current_folder.uuid) do
      nil -> MapSet.new()
      path -> MapSet.new(path)
    end
  end

  defp find_node_path(nodes, target_uuid) do
    Enum.find_value(nodes, fn node ->
      if node.folder.uuid == target_uuid do
        [target_uuid]
      else
        case find_node_path(node.children, target_uuid) do
          nil -> nil
          sub -> [node.folder.uuid | sub]
        end
      end
    end)
  end

  # ──────────────────────────────────────────────────────────────
  # Folder color helpers (shared with grid/list folder cards)
  # ──────────────────────────────────────────────────────────────

  def folder_bg_style(color) do
    case folder_color_hex(color) do
      nil -> nil
      hex -> "background-color: #{hex}15"
    end
  end

  def folder_icon_style(color, _active? \\ false) do
    case folder_color_hex(color) do
      nil -> "color: oklch(var(--wa))"
      hex -> "color: #{hex}"
    end
  end

  @doc """
  A folder's colour, for a folder that may not have the concept.

  Read with `Map.get/3` rather than `folder.color` on purpose: this component
  is reusable, and a consumer's folder struct is its own — the knowledge base's
  has a path and a name and nothing else. A missing key raised `KeyError` and
  took the page down the moment such a vault had one folder.
  """
  @spec folder_color(map()) :: String.t() | nil
  def folder_color(folder), do: Map.get(folder, :color)

  def folder_color_hex("red"), do: "#ef4444"
  def folder_color_hex("orange"), do: "#f97316"
  def folder_color_hex("amber"), do: "#f59e0b"
  def folder_color_hex("yellow"), do: "#eab308"
  def folder_color_hex("lime"), do: "#84cc16"
  def folder_color_hex("green"), do: "#22c55e"
  def folder_color_hex("emerald"), do: "#10b981"
  def folder_color_hex("teal"), do: "#14b8a6"
  def folder_color_hex("cyan"), do: "#06b6d4"
  def folder_color_hex("sky"), do: "#0ea5e9"
  def folder_color_hex("blue"), do: "#3b82f6"
  def folder_color_hex("violet"), do: "#8b5cf6"
  def folder_color_hex("purple"), do: "#a855f7"
  def folder_color_hex("fuchsia"), do: "#d946ef"
  def folder_color_hex("pink"), do: "#ec4899"
  def folder_color_hex("rose"), do: "#f43f5e"
  def folder_color_hex(_), do: nil
end
