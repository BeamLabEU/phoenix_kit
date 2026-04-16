defmodule PhoenixKitWeb.Components.MediaBrowser do
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

  ## Usage (uncontrolled)

      <.live_component
        module={PhoenixKitWeb.Components.MediaBrowser}
        id="media-browser"
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />

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

  ## Required attributes

  - `id` — unique DOM id (required by LiveComponent)

  ## Optional attributes

  - `phoenix_kit_current_user` — logged-in user struct (for upload attribution)
  - `scope_folder_id` — constrain the browser to a virtual root folder
  - `on_navigate` — when truthy, enables controlled mode (URL-sync via parent)
  """
  use PhoenixKitWeb, :live_component

  require Logger

  import Ecto.Query

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  # ──────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:scope_folder_id, fn -> nil end)

    cond do
      not Map.has_key?(socket.assigns, :uploaded_files) ->
        socket = init_socket(socket)

        # Apply initial params if provided (avoids flash of root before correct view)
        socket =
          if Map.has_key?(assigns, :initial_params),
            do: apply_nav_params(socket, assigns.initial_params),
            else: socket

        {:ok, socket}

      Map.has_key?(assigns, :nav_params) ->
        {:ok, apply_nav_params(socket, socket.assigns.nav_params)}

      true ->
        {:ok, socket}
    end
  end

  defp apply_nav_params(socket, params) do
    q = params[:q] || ""
    page = params[:page] || 1
    filter_orphaned = params[:filter_orphaned] || false
    file_view = params[:view]
    scope = scope_folder_id(socket)
    per_page = socket.assigns.per_page

    {current_folder, breadcrumbs, folders, scoped_fallback?} =
      resolve_folder(params[:folder], scope)

    actual_uuid = current_folder && current_folder.uuid

    {files, total_count} =
      load_nav_files(scope, page, per_page, q, actual_uuid, filter_orphaned, file_view)

    orphaned_count =
      if filter_orphaned,
        do: total_count,
        else: Storage.count_orphaned_files(scope)

    socket
    |> assign(:current_folder, current_folder)
    |> assign(:breadcrumbs, breadcrumbs)
    |> assign(:folders, if(file_view == "all", do: [], else: folders))
    |> assign(:search_query, q)
    |> assign(:current_page, page)
    |> assign(:filter_orphaned, filter_orphaned)
    |> assign(:filter_trash, false)
    |> assign(:file_view, file_view)
    |> assign(:orphaned_count, orphaned_count)
    |> assign(:trash_count, Storage.count_trashed_files(scope_folder_id(socket)))
    |> assign(:uploaded_files, files)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, ceil(total_count / per_page))
    |> then(
      &if(scoped_fallback?,
        do: put_flash(&1, :info, "Folder not accessible — showing root"),
        else: &1
      )
    )
    |> auto_expand_breadcrumbs(breadcrumbs)
  end

  defp resolve_folder(folder_uuid, scope) do
    if folder_uuid in [nil, ""] do
      {nil, [], Storage.list_folders(nil, scope), false}
    else
      folder = Storage.get_folder(folder_uuid)

      if folder && Storage.within_scope?(folder.uuid, scope) do
        bc = Storage.folder_breadcrumbs(folder.uuid, scope)
        flds = Storage.list_folders(folder.uuid, scope)
        {folder, bc, flds, false}
      else
        # Folder not found or outside scope — fall back to scope root.
        {nil, [], Storage.list_folders(nil, scope), not is_nil(folder_uuid)}
      end
    end
  end

  defp load_nav_files(scope, page, per_page, q, actual_uuid, filter_orphaned, file_view) do
    cond do
      filter_orphaned -> load_orphaned_files(page, per_page)
      file_view == "all" -> load_all_view_files(scope, page, per_page, q)
      true -> load_scoped_files(scope, page, per_page, actual_uuid, q)
    end
  end

  defp init_socket(socket) do
    scope = scope_folder_id(socket)
    scope_invalid = not is_nil(scope) and is_nil(Storage.get_folder(scope))

    enabled_buckets = Storage.list_enabled_buckets()
    has_buckets = not Enum.empty?(enabled_buckets)

    socket
    |> maybe_allow_upload(has_buckets)
    |> assign(:has_buckets, has_buckets)
    |> assign(:scope_invalid, scope_invalid)
    |> assign(:show_upload, false)
    |> assign(:last_uploaded_file_uuids, [])
    |> assign(:filter_orphaned, false)
    |> assign(:filter_trash, false)
    |> assign(:trash_count, Storage.count_trashed_files(scope_folder_id(socket)))
    |> assign(:file_view, nil)
    |> assign(
      :orphaned_count,
      if(scope_invalid, do: 0, else: Storage.count_orphaned_files(scope))
    )
    |> assign(:current_folder, nil)
    |> assign(:breadcrumbs, [])
    |> assign(:folders, if(scope_invalid, do: [], else: Storage.list_folders(nil, scope)))
    |> assign(:folder_tree, if(scope_invalid, do: [], else: Storage.list_folder_tree(scope)))
    |> assign(:show_new_folder, false)
    |> assign(:sidebar_collapsed, false)
    |> assign(:expanded_folders, MapSet.new())
    |> assign(:renaming_folder, nil)
    |> assign(:renaming_source, nil)
    |> assign(:renaming_text, "")
    |> assign(:view_mode, "grid")
    |> assign(:search_query, "")
    |> assign(:select_mode, false)
    |> assign(:selected_files, MapSet.new())
    |> assign(:selected_folders, MapSet.new())
    |> assign(:show_move_modal, false)
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

  defp maybe_allow_upload(socket, has_buckets) do
    cond do
      socket.assigns[:uploads] ->
        # Idempotency guard: allow_upload was already called — skip.
        socket

      has_buckets ->
        max_size_mb =
          Settings.get_setting_cached("storage_max_upload_size_mb", "500")
          |> String.to_integer()

        socket
        |> assign(:max_upload_size_mb, max_size_mb)
        |> allow_upload(:media_files,
          accept: :any,
          max_entries: 10,
          max_file_size: max_size_mb * 1_000_000,
          auto_upload: true,
          progress: &handle_progress/3
        )

      true ->
        assign(socket, :max_upload_size_mb, 0)
    end
  end

  defp handle_progress(:media_files, entry, socket) do
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
        |> put_flash(flash_type, flash_msg)
        |> assign(:last_uploaded_file_uuids, new_uuids)
      else
        socket
      end

    {:noreply, socket}
  end

  # ──────────────────────────────────────────────────────────────
  # Function components
  # ──────────────────────────────────────────────────────────────

  attr :node, :map, required: true
  attr :current_folder, :any, required: true
  attr :expanded_folders, :any, required: true
  attr :renaming_folder, :any, required: true
  attr :renaming_text, :string, default: ""
  attr :show_new_folder, :boolean, default: false
  attr :renaming_source, :any, required: true
  attr :depth, :integer, default: 0
  attr :myself, :any, required: true

  def folder_tree_node(assigns) do
    assigns =
      assign(
        assigns,
        :is_active,
        assigns.current_folder && assigns.current_folder.uuid == assigns.node.folder.uuid
      )

    assigns =
      assign(
        assigns,
        :is_expanded,
        MapSet.member?(assigns.expanded_folders, assigns.node.folder.uuid)
      )

    assigns = assign(assigns, :has_children, assigns.node.children != [])

    assigns =
      assign(
        assigns,
        :is_renaming,
        assigns.renaming_folder == assigns.node.folder.uuid &&
          assigns.renaming_source == "sidebar"
      )

    ~H"""
    <li class="overflow-hidden">
      <div
        class={[
          "flex items-center gap-0.5 rounded-lg px-1 py-1 hover:bg-base-200 transition-colors group overflow-hidden min-w-0",
          @is_active && "font-semibold"
        ]}
        style={
          if @is_active,
            do: "background-color: #{folder_color_hex(@node.folder.color) || "oklch(var(--p))"}25"
        }
      >
        <%!-- Chevron (expand/collapse) --%>
        <%= if @has_children do %>
          <button
            phx-click="toggle_folder_expand"
            phx-target={@myself}
            phx-value-folder-uuid={@node.folder.uuid}
            class="btn btn-ghost btn-xs p-0 min-h-0 h-5 w-5"
          >
            <.icon
              name={if @is_expanded, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
              class="w-4 h-4 text-base-content/40"
            />
          </button>
        <% else %>
          <span class="w-5"></span>
        <% end %>

        <%= if @is_renaming do %>
          <%!-- Inline rename form --%>
          <form
            phx-submit="rename_folder"
            phx-change="rename_folder_input"
            phx-target={@myself}
            class="flex items-center gap-1.5 flex-1 min-w-0"
          >
            <input type="hidden" name="folder_uuid" value={@node.folder.uuid} />
            <span style={folder_icon_style(@node.folder.color)}>
              <.icon name="hero-folder" class="w-4 h-4 shrink-0" />
            </span>
            <input
              type="text"
              name="name"
              value={@renaming_text}
              class="bg-transparent border-none outline-none text-sm flex-1 min-w-0 p-0 h-auto focus:outline-none focus:ring-0"
              phx-mounted={JS.focus()}
              required
              phx-keydown="cancel_rename_folder"
              phx-target={@myself}
              phx-key="Escape"
              phx-debounce="50"
            />
          </form>
        <% else %>
          <%!-- Folder button (uncontrolled: phx-click instead of .link navigate) --%>
          <button
            phx-click="navigate_folder"
            phx-target={@myself}
            phx-value-folder-uuid={@node.folder.uuid}
            data-drop-folder={@node.folder.uuid}
            class="flex items-center gap-1.5 flex-1 min-w-0 overflow-hidden text-sm text-left"
          >
            <span style={folder_icon_style(@node.folder.color, @is_active)}>
              <.icon
                name={if @is_expanded, do: "hero-folder-open", else: "hero-folder"}
                class="w-4 h-4 shrink-0"
              />
            </span>
            <span
              class={[
                "truncate block min-w-0",
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
            phx-click="start_rename_folder"
            phx-target={@myself}
            phx-value-folder-uuid={@node.folder.uuid}
            phx-value-source="sidebar"
            class="btn btn-ghost btn-xs p-0 min-h-0 h-5 w-5 opacity-0 group-hover:opacity-100"
            title="Rename"
          >
            <.icon name="hero-pencil" class="w-3 h-3 text-base-content/40" />
          </button>
        <% end %>
      </div>

      <%!-- Children (expanded or active with new folder form) --%>
      <%= if (@has_children && @is_expanded) || (@is_active && @show_new_folder) do %>
        <ul
          class="ml-3 border-l-2 pl-1 overflow-hidden"
          style={"border-color: #{folder_color_hex(@node.folder.color) || "oklch(var(--bc) / 0.15)"}"}
        >
          <%= for child <- @node.children do %>
            <.folder_tree_node
              node={child}
              current_folder={@current_folder}
              expanded_folders={@expanded_folders}
              renaming_folder={@renaming_folder}
              renaming_source={@renaming_source}
              renaming_text={@renaming_text}
              show_new_folder={@show_new_folder}
              depth={@depth + 1}
              myself={@myself}
            />
          <% end %>
          <%= if @is_active && @show_new_folder do %>
            <li>
              <form
                phx-submit="create_folder"
                phx-target={@myself}
                class="flex items-center gap-0.5 rounded-lg px-1 py-1"
              >
                <span class="w-5"></span>
                <span class="text-warning">
                  <.icon name="hero-folder-plus" class="w-4 h-4" />
                </span>
                <input
                  type="text"
                  name="name"
                  placeholder="Folder name"
                  class="input input-bordered input-xs flex-1 min-w-0"
                  phx-mounted={JS.focus()}
                  required
                  phx-keydown="toggle_new_folder"
                  phx-target={@myself}
                  phx-key="Escape"
                />
              </form>
            </li>
          <% end %>
        </ul>
      <% end %>
    </li>
    """
  end

  attr :node, :map, required: true
  attr :depth, :integer, default: 0
  attr :myself, :any, required: true

  def move_folder_option(assigns) do
    ~H"""
    <li>
      <button
        phx-click="move_selected_to_folder"
        phx-target={@myself}
        phx-value-folder_uuid={@node.folder.uuid}
        style={"padding-left: #{(@depth + 1) * 16}px"}
      >
        <.icon name="hero-folder" class="w-4 h-4" /> {@node.folder.name}
      </button>
      <%= for child <- @node.children do %>
        <.move_folder_option node={child} depth={@depth + 1} myself={@myself} />
      <% end %>
    </li>
    """
  end

  # ──────────────────────────────────────────────────────────────
  # Event handlers
  # ──────────────────────────────────────────────────────────────

  def handle_event("toggle_new_folder", _params, socket) do
    {:noreply, assign(socket, :show_new_folder, !socket.assigns.show_new_folder)}
  end

  def handle_event("create_folder", %{"name" => name}, socket) do
    folder_uuid = current_folder_uuid(socket)
    user = socket.assigns[:phoenix_kit_current_user]
    scope = scope_folder_id(socket)

    case Storage.create_folder(
           %{name: name, parent_uuid: folder_uuid, user_uuid: user && user.uuid},
           scope
         ) do
      {:ok, _folder} ->
        {:noreply,
         socket
         |> assign(:show_new_folder, false)
         |> assign(:folders, Storage.list_folders(folder_uuid, scope))
         |> assign(:folder_tree, Storage.list_folder_tree(scope))
         |> put_flash(:info, "Folder created")}

      {:error, :out_of_scope} ->
        {:noreply, put_flash(socket, :error, "Cannot create folder outside the allowed scope")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create folder")}
    end
  end

  def handle_event("delete_folder", %{"id" => folder_uuid}, socket) do
    folder = Storage.get_folder(folder_uuid)
    scope = scope_folder_id(socket)

    if folder do
      case Storage.delete_folder(folder, scope) do
        {:error, :out_of_scope} ->
          {:noreply, put_flash(socket, :error, "Cannot delete folder outside the allowed scope")}

        _ ->
          parent_uuid = current_folder_uuid(socket)

          {:noreply,
           socket
           |> assign(:folders, Storage.list_folders(parent_uuid, scope))
           |> assign(:folder_tree, Storage.list_folder_tree(scope))
           |> put_flash(:info, "Folder deleted")}
      end
    else
      {:noreply, put_flash(socket, :error, "Folder not found")}
    end
  end

  def handle_event(
        "move_file_to_folder",
        %{"file_uuid" => file_uuid, "folder_uuid" => folder_uuid},
        socket
      ) do
    target = if folder_uuid == "", do: nil, else: folder_uuid
    scope = scope_folder_id(socket)

    case Storage.move_file_to_folder(file_uuid, target, scope) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "File moved") |> reload_current_page()}

      {:error, :out_of_scope} ->
        {:noreply, put_flash(socket, :error, "Cannot move file outside the allowed scope")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to move file")}
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
          load_all_view_files(scope, 1, per_page, query)
        else
          load_scoped_files(scope, 1, per_page, folder_uuid, query)
        end

      folders =
        cond do
          file_view == "all" -> []
          query != "" -> []
          true -> Storage.list_folders(folder_uuid, scope)
        end

      {:noreply,
       socket
       |> assign(:search_query, query)
       |> assign(:folders, folders)
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, ceil(total_count / per_page))}
    end
  end

  def handle_event("clear_search", _params, socket) do
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
          load_all_view_files(scope, 1, per_page, "")
        else
          load_scoped_files(scope, 1, per_page, folder_uuid, "")
        end

      folders =
        if file_view == "all",
          do: [],
          else: Storage.list_folders(folder_uuid, scope)

      {:noreply,
       socket
       |> assign(:search_query, "")
       |> assign(:folders, folders)
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, ceil(total_count / per_page))}
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
      {files, total_count} = load_all_view_files(scope, 1, per_page, q)

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
       |> assign(:total_pages, ceil(total_count / per_page))}
    end
  end

  def handle_event("set_view_mode", %{"mode" => mode}, socket) when mode in ["grid", "list"] do
    {:noreply, assign(socket, :view_mode, mode)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    socket = assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)
    {:noreply, push_tree_state(socket)}
  end

  def handle_event("restore_tree_state", params, socket) do
    expanded = (params["expanded"] || []) |> MapSet.new()
    sidebar_collapsed = params["sidebar_collapsed"] == true

    {:noreply,
     socket
     |> assign(:expanded_folders, MapSet.union(socket.assigns.expanded_folders, expanded))
     |> assign(:sidebar_collapsed, sidebar_collapsed)}
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

  def handle_event("rename_folder", %{"folder_uuid" => folder_uuid, "name" => name}, socket) do
    folder = Storage.get_folder(folder_uuid)

    scope = scope_folder_id(socket)

    if folder && name != "" do
      case Storage.update_folder(folder, %{name: String.trim(name)}, scope) do
        {:ok, _} ->
          parent_uuid = current_folder_uuid(socket)

          {:noreply,
           socket
           |> assign(:renaming_folder, nil)
           |> assign(:renaming_source, nil)
           |> assign(:renaming_text, "")
           |> assign(:folders, Storage.list_folders(parent_uuid, scope))
           |> assign(:folder_tree, Storage.list_folder_tree(scope))}

        {:error, :out_of_scope} ->
          {:noreply, put_flash(socket, :error, "Cannot rename folder outside the allowed scope")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to rename folder")}
      end
    else
      {:noreply,
       socket
       |> assign(:renaming_folder, nil)
       |> assign(:renaming_source, nil)
       |> assign(:renaming_text, "")}
    end
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
           |> assign(:folders, Storage.list_folders(parent_uuid, scope))
           |> assign(:folder_tree, Storage.list_folder_tree(scope))}

        {:error, :out_of_scope} ->
          {:noreply, put_flash(socket, :error, "Cannot change folder outside the allowed scope")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to change color")}
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
    {:noreply, push_tree_state(socket)}
  end

  def handle_event("toggle_select_mode", _params, socket) do
    if socket.assigns.select_mode do
      {:noreply,
       socket
       |> assign(:select_mode, false)
       |> assign(:selected_files, MapSet.new())
       |> assign(:selected_folders, MapSet.new())}
    else
      {:noreply, assign(socket, :select_mode, true)}
    end
  end

  def handle_event("click_file", %{"file-uuid" => file_uuid}, socket) do
    if socket.assigns.select_mode do
      selected = socket.assigns.selected_files

      selected =
        if MapSet.member?(selected, file_uuid),
          do: MapSet.delete(selected, file_uuid),
          else: MapSet.put(selected, file_uuid)

      {:noreply, assign(socket, :selected_files, selected)}
    else
      {:noreply, push_navigate(socket, to: Routes.path("/admin/media/#{file_uuid}"))}
    end
  end

  def handle_event("toggle_select_folder", %{"folder-uuid" => folder_uuid}, socket) do
    selected = socket.assigns.selected_folders

    selected =
      if MapSet.member?(selected, folder_uuid),
        do: MapSet.delete(selected, folder_uuid),
        else: MapSet.put(selected, folder_uuid)

    {:noreply, assign(socket, :selected_folders, selected)}
  end

  def handle_event("toggle_select", %{"file-uuid" => file_uuid}, socket) do
    selected = socket.assigns.selected_files

    selected =
      if MapSet.member?(selected, file_uuid),
        do: MapSet.delete(selected, file_uuid),
        else: MapSet.put(selected, file_uuid)

    {:noreply, assign(socket, :selected_files, selected)}
  end

  def handle_event("select_all", _params, socket) do
    all_file_uuids = Enum.map(socket.assigns.uploaded_files, & &1.file_uuid)
    all_folder_uuids = Enum.map(socket.assigns.folders, & &1.uuid)

    {:noreply,
     socket
     |> assign(:selected_files, MapSet.new(all_file_uuids))
     |> assign(:selected_folders, MapSet.new(all_folder_uuids))}
  end

  def handle_event("deselect_all", _params, socket) do
    {:noreply,
     socket
     |> assign(:select_mode, false)
     |> assign(:selected_files, MapSet.new())
     |> assign(:selected_folders, MapSet.new())}
  end

  def handle_event("show_move_modal", _params, socket) do
    {:noreply, assign(socket, :show_move_modal, true)}
  end

  def handle_event("close_move_modal", _params, socket) do
    {:noreply, assign(socket, :show_move_modal, false)}
  end

  def handle_event("move_selected_to_folder", %{"folder_uuid" => folder_uuid}, socket) do
    target = if folder_uuid == "", do: nil, else: folder_uuid
    scope = scope_folder_id(socket)

    Enum.each(socket.assigns.selected_files, fn file_uuid ->
      Storage.move_file_to_folder(file_uuid, target, scope)
    end)

    Enum.each(socket.assigns.selected_folders, fn sel_folder_uuid ->
      if sel_folder_uuid != target do
        folder = Storage.get_folder(sel_folder_uuid)
        if folder, do: Storage.update_folder(folder, %{parent_uuid: target}, scope)
      end
    end)

    file_count = MapSet.size(socket.assigns.selected_files)
    folder_count = MapSet.size(socket.assigns.selected_folders)

    {:noreply,
     socket
     |> assign(:select_mode, false)
     |> assign(:selected_files, MapSet.new())
     |> assign(:selected_folders, MapSet.new())
     |> assign(:show_move_modal, false)
     |> put_flash(:info, "#{file_count + folder_count} item(s) moved")
     |> reload_current_page()}
  end

  def handle_event("delete_selected", _params, socket) do
    scope = scope_folder_id(socket)
    repo = PhoenixKit.Config.get_repo()

    if socket.assigns.filter_trash do
      # Permanent delete from trash (with scope guard)
      Enum.each(socket.assigns.selected_files, fn file_uuid ->
        file = repo.get(Storage.File, file_uuid)

        if file && Storage.within_scope?(file.folder_uuid, scope) do
          Storage.delete_file_completely(file)
        end
      end)
    else
      # Soft-delete to trash
      Enum.each(socket.assigns.selected_files, fn file_uuid ->
        file = repo.get(Storage.File, file_uuid)

        if file && Storage.within_scope?(file.folder_uuid, scope) do
          Storage.trash_file(file)
        end
      end)
    end

    # Folders are always permanently deleted (no trash for folders)
    Enum.each(socket.assigns.selected_folders, fn folder_uuid ->
      folder = Storage.get_folder(folder_uuid)
      if folder, do: Storage.delete_folder(folder, scope)
    end)

    file_count = MapSet.size(socket.assigns.selected_files)
    folder_count = MapSet.size(socket.assigns.selected_folders)

    flash =
      if socket.assigns.filter_trash,
        do: "#{file_count + folder_count} item(s) permanently deleted",
        else: "#{file_count + folder_count} item(s) moved to trash"

    {:noreply,
     socket
     |> assign(:select_mode, false)
     |> assign(:selected_files, MapSet.new())
     |> assign(:selected_folders, MapSet.new())
     |> put_flash(:info, flash)
     |> reload_current_page()}
  end

  def handle_event("toggle_trash_filter", _params, socket) do
    filter_trash = !socket.assigns.filter_trash

    {files, total_count} =
      if filter_trash do
        load_trashed_files(scope_folder_id(socket), 1, socket.assigns.per_page)
      else
        scope = scope_folder_id(socket)
        folder_uuid = current_folder_uuid(socket)
        load_scoped_files(scope, 1, socket.assigns.per_page, folder_uuid, "")
      end

    {:noreply,
     socket
     |> assign(:filter_trash, filter_trash)
     |> assign(:filter_orphaned, false)
     |> assign(:folders, if(filter_trash, do: [], else: socket.assigns.folders))
     |> assign(:uploaded_files, files)
     |> assign(:total_count, total_count)
     |> assign(:total_pages, ceil(total_count / socket.assigns.per_page))
     |> assign(:current_page, 1)
     |> assign(:trash_count, Storage.count_trashed_files(scope_folder_id(socket)))}
  end

  def handle_event("restore_selected", _params, socket) do
    scope = scope_folder_id(socket)
    repo = PhoenixKit.Config.get_repo()

    restored =
      Enum.reduce(socket.assigns.selected_files, 0, fn file_uuid, acc ->
        file = repo.get(Storage.File, file_uuid)

        if file && Storage.within_scope?(file.folder_uuid, scope) do
          case Storage.restore_file(file) do
            {:ok, _} -> acc + 1
            _ -> acc
          end
        else
          acc
        end
      end)

    {:noreply,
     socket
     |> assign(:select_mode, false)
     |> assign(:selected_files, MapSet.new())
     |> put_flash(:info, "#{restored} file(s) restored")
     |> reload_current_page()}
  end

  def handle_event("empty_trash", _params, socket) do
    {:ok, count} = Storage.empty_trash(scope_folder_id(socket))

    {:noreply,
     socket
     |> assign(:filter_trash, false)
     |> put_flash(:info, "#{count} file(s) permanently deleted")
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
          load_orphaned_files(1, per_page)
        else
          load_scoped_files(scope, 1, per_page, folder_uuid, search)
        end

      orphaned_count =
        if filter_orphaned,
          do: total_count,
          else: Storage.count_orphaned_files(scope_folder_id(socket))

      {:noreply,
       socket
       |> assign(:filter_orphaned, filter_orphaned)
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_pages, ceil(total_count / per_page))
       |> assign(:total_count, total_count)
       |> assign(:orphaned_count, orphaned_count)}
    end
  end

  def handle_event("delete_all_orphaned", _params, socket) do
    orphan_uuids = Storage.find_orphaned_files() |> Enum.map(& &1.uuid)
    Storage.queue_file_cleanup(orphan_uuids)

    {:noreply,
     put_flash(socket, :info, "#{length(orphan_uuids)} orphaned files queued for deletion")}
  end

  def handle_event("toggle_upload", _params, socket) do
    {:noreply, assign(socket, :show_upload, !socket.assigns.show_upload)}
  end

  def handle_event("show_upload", _params, socket) do
    {:noreply, assign(socket, :show_upload, true)}
  end

  def handle_event("validate", _params, socket) do
    # Upload progress is handled via the progress: &handle_progress/3 callback.
    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media_files, ref)}
  end

  def handle_event("set_page", %{"page" => page_str}, socket) do
    page =
      case Integer.parse(page_str) do
        {n, _} when n > 0 -> n
        _ -> 1
      end

    if controlled_mode?(socket) do
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
      folder_uuid = current_folder_uuid(socket)
      per_page = socket.assigns.per_page
      search = socket.assigns.search_query
      scope = scope_folder_id(socket)
      file_view = socket.assigns.file_view

      {files, total_count} =
        cond do
          socket.assigns.filter_orphaned -> load_orphaned_files(page, per_page)
          file_view == "all" -> load_all_view_files(scope, page, per_page, search)
          true -> load_scoped_files(scope, page, per_page, folder_uuid, search)
        end

      {:noreply,
       socket
       |> assign(:uploaded_files, files)
       |> assign(:current_page, page)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, ceil(total_count / per_page))}
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Navigation helpers
  # ──────────────────────────────────────────────────────────────

  defp navigate_to_folder(socket, folder_uuid) when folder_uuid in [nil, ""] do
    if controlled_mode?(socket) do
      send(self(), {__MODULE__, socket.assigns.id, {:navigate, %{folder: nil, q: "", page: 1}}})
      {:noreply, socket}
    else
      scope = scope_folder_id(socket)
      per_page = socket.assigns.per_page
      {files, total_count} = load_scoped_files(scope, 1, per_page, nil, "")

      {:noreply,
       socket
       |> assign(:file_view, nil)
       |> assign(:filter_trash, false)
       |> assign(:filter_orphaned, false)
       |> assign(:current_folder, nil)
       |> assign(:breadcrumbs, [])
       |> assign(:folders, Storage.list_folders(nil, scope))
       |> assign(:search_query, "")
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, ceil(total_count / per_page))}
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
      folders = Storage.list_folders(actual_uuid, scope)
      per_page = socket.assigns.per_page
      {files, total_count} = load_scoped_files(scope, 1, per_page, actual_uuid, "")

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
       |> assign(:total_pages, ceil(total_count / per_page))
       |> auto_expand_breadcrumbs(breadcrumbs)}
    end
  end

  defp reload_current_page(socket) do
    folder_uuid = current_folder_uuid(socket)
    page = socket.assigns.current_page
    per_page = socket.assigns.per_page
    search = socket.assigns.search_query
    scope = scope_folder_id(socket)
    file_view = socket.assigns[:file_view]

    {files, total_count} =
      cond do
        socket.assigns[:filter_trash] -> load_trashed_files(scope, page, per_page)
        socket.assigns.filter_orphaned -> load_orphaned_files(page, per_page)
        file_view == "all" -> load_all_view_files(scope, page, per_page, search)
        true -> load_scoped_files(scope, page, per_page, folder_uuid, search)
      end

    socket
    |> assign(:uploaded_files, files)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, ceil(total_count / per_page))
    |> assign(:trash_count, Storage.count_trashed_files(scope_folder_id(socket)))
  end

  defp current_folder_uuid(socket) do
    socket.assigns.current_folder && socket.assigns.current_folder.uuid
  end

  defp scope_folder_id(socket), do: socket.assigns[:scope_folder_id]

  defp controlled_mode?(socket), do: socket.assigns[:on_navigate] != nil

  # ──────────────────────────────────────────────────────────────
  # Data loading
  # ──────────────────────────────────────────────────────────────

  defp load_trashed_files(scope, page, per_page) do
    repo = PhoenixKit.Config.get_repo()
    offset = (page - 1) * per_page
    total_count = Storage.count_trashed_files(scope)
    files = Storage.list_trashed_files(scope, limit: per_page, offset: offset)
    file_uuids = Enum.map(files, & &1.uuid)

    instances_by_file =
      if file_uuids != [] do
        from(fi in FileInstance, where: fi.file_uuid in ^file_uuids)
        |> repo.all()
        |> Enum.group_by(& &1.file_uuid)
      else
        %{}
      end

    existing_files =
      Enum.map(files, fn file ->
        instances = Map.get(instances_by_file, file.uuid, [])
        urls = generate_urls_from_instances(instances, file.uuid)

        %{
          file_uuid: file.uuid,
          filename: file.original_file_name || file.file_name || "Unknown",
          file_type: file.file_type,
          mime_type: file.mime_type,
          size: file.size || 0,
          status: file.status,
          inserted_at: file.inserted_at,
          trashed_at: file.trashed_at,
          urls: urls
        }
      end)

    {existing_files, total_count}
  end

  defp load_orphaned_files(page, per_page) do
    repo = PhoenixKit.Config.get_repo()
    offset = (page - 1) * per_page
    total_count = Storage.count_orphaned_files()
    files = Storage.find_orphaned_files(limit: per_page, offset: offset)
    file_uuids = Enum.map(files, & &1.uuid)

    instances_by_file =
      if file_uuids != [] do
        from(fi in FileInstance, where: fi.file_uuid in ^file_uuids)
        |> repo.all()
        |> Enum.group_by(& &1.file_uuid)
      else
        %{}
      end

    existing_files =
      Enum.map(files, fn file ->
        instances = Map.get(instances_by_file, file.uuid, [])
        urls = generate_urls_from_instances(instances, file.uuid)

        %{
          file_uuid: file.uuid,
          filename: file.original_file_name || file.file_name || "Unknown",
          original_filename: file.original_file_name,
          file_type: file.file_type,
          mime_type: file.mime_type,
          size: file.size || 0,
          status: file.status,
          inserted_at: file.inserted_at,
          urls: urls
        }
      end)

    {existing_files, total_count}
  end

  # Loads files within scope with optional folder/search filters.
  # When scope=nil AND folder_uuid=nil AND search="", passes include_orphaned: true
  # to preserve the /admin/media root view behavior of showing only orphan files.
  defp load_scoped_files(scope, page, per_page, folder_uuid, search) do
    at_real_root = is_nil(scope) and is_nil(folder_uuid) and search in [nil, ""]

    opts = [page: page, per_page: per_page]

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
  defp load_all_view_files(scope, page, per_page, search) do
    opts = [page: page, per_page: per_page]
    opts = if search && search != "", do: [{:search, search} | opts], else: opts

    case Storage.list_files_in_scope(scope, opts) do
      {:error, :out_of_scope} -> {[], 0}
      {files, total_count} -> {enrich_files(files), total_count}
    end
  end

  # Enriches raw Storage.File structs with URLs, folder paths, and display fields.
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

    folder_paths =
      Map.new(folder_uuids, fn fuuid ->
        path = Storage.folder_breadcrumbs(fuuid) |> Enum.map_join(" / ", & &1.name)
        {fuuid, path}
      end)

    Enum.map(files, fn file ->
      instances = Map.get(instances_by_file, file.uuid, [])
      urls = generate_urls_from_instances(instances, file.uuid)

      %{
        file_uuid: file.uuid,
        filename: file.original_file_name || file.file_name || "Unknown",
        original_filename: file.original_file_name,
        file_type: file.file_type,
        mime_type: file.mime_type,
        size: file.size || 0,
        status: file.status,
        inserted_at: file.inserted_at,
        folder_path: Map.get(folder_paths, file.folder_uuid),
        urls: urls
      }
    end)
  end

  # ──────────────────────────────────────────────────────────────
  # Upload processing
  # ──────────────────────────────────────────────────────────────

  defp process_single_upload(socket, path, entry) do
    ext = Path.extname(entry.client_name) |> String.replace_leading(".", "")
    mime_type = entry.client_type || MIME.from_path(entry.client_name)
    file_type = determine_file_type(mime_type)
    current_user = socket.assigns[:phoenix_kit_current_user]
    user_uuid = if current_user, do: current_user.uuid, else: nil
    {:ok, stat} = Elixir.File.stat(path)
    file_size = stat.size
    file_hash = Auth.calculate_file_hash(path)

    case Storage.store_file_in_buckets(
           path,
           file_type,
           user_uuid,
           file_hash,
           ext,
           entry.client_name
         ) do
      {:ok, file, :duplicate} ->
        maybe_set_folder(file, socket)
        build_upload_result(file, entry, file_type, mime_type, file_size, true)

      {:ok, file} ->
        maybe_set_folder(file, socket)
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
      file_type: file_type,
      mime_type: mime_type,
      size: file_size,
      status: file.status,
      urls: %{}
    }

    result = if is_duplicate, do: Map.put(result, :duplicate, true), else: result
    {:ok, result}
  end

  defp build_upload_flash_message(uploaded_files) do
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
        {:info, "Upload processed"}
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
     "Upload failed: No storage buckets configured. Please configure at least one storage bucket before uploading files."}
  end

  defp build_partial_success_message(new_count, error_count) do
    {:warning,
     "Partially successful: #{new_count} file(s) uploaded, #{error_count} failed due to missing storage buckets."}
  end

  defp build_only_duplicates_message(duplicate_count) do
    {:info, "Already have #{duplicate_count} duplicate file(s). No new files were added."}
  end

  defp build_new_files_only_message(new_count) do
    {:info, "Upload successful! #{new_count} new file(s) processed"}
  end

  defp build_new_and_duplicates_message(new_count, duplicate_count) do
    {:info,
     "Upload successful! #{new_count} new file(s) added. #{duplicate_count} file(s) were already uploaded."}
  end

  defp maybe_set_folder(file, socket) do
    scope = scope_folder_id(socket)
    folder_uuid = current_folder_uuid(socket) || scope

    if folder_uuid, do: Storage.move_file_to_folder(file.uuid, folder_uuid, scope)
  end

  # ──────────────────────────────────────────────────────────────
  # Style / icon helpers
  # ──────────────────────────────────────────────────────────────

  defp generate_urls_from_instances(instances, file_uuid) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      url = URLSigner.signed_url(file_uuid, instance.variant_name)
      Map.put(acc, instance.variant_name, url)
    end)
  end

  defp determine_file_type(mime_type) do
    cond do
      String.starts_with?(mime_type, "image/") -> "image"
      String.starts_with?(mime_type, "video/") -> "video"
      mime_type == "application/pdf" -> "pdf"
      true -> "document"
    end
  end

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 2)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 2)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp folder_bg_style(color) do
    case folder_color_hex(color) do
      nil -> nil
      hex -> "background-color: #{hex}15"
    end
  end

  defp folder_icon_style(color, _active? \\ false) do
    case folder_color_hex(color) do
      nil -> "color: oklch(var(--wa))"
      hex -> "color: #{hex}"
    end
  end

  defp folder_color_hex("red"), do: "#ef4444"
  defp folder_color_hex("orange"), do: "#f97316"
  defp folder_color_hex("amber"), do: "#f59e0b"
  defp folder_color_hex("yellow"), do: "#eab308"
  defp folder_color_hex("lime"), do: "#84cc16"
  defp folder_color_hex("green"), do: "#22c55e"
  defp folder_color_hex("emerald"), do: "#10b981"
  defp folder_color_hex("teal"), do: "#14b8a6"
  defp folder_color_hex("cyan"), do: "#06b6d4"
  defp folder_color_hex("sky"), do: "#0ea5e9"
  defp folder_color_hex("blue"), do: "#3b82f6"
  defp folder_color_hex("violet"), do: "#8b5cf6"
  defp folder_color_hex("purple"), do: "#a855f7"
  defp folder_color_hex("fuchsia"), do: "#d946ef"
  defp folder_color_hex("pink"), do: "#ec4899"
  defp folder_color_hex("rose"), do: "#f43f5e"
  defp folder_color_hex(_), do: nil

  defp file_icon("image"), do: "hero-photo"
  defp file_icon("video"), do: "hero-play-circle"
  defp file_icon("pdf"), do: "hero-document-text"
  defp file_icon("document"), do: "hero-document"
  defp file_icon(_), do: "hero-document-arrow-down"

  defp auto_expand_breadcrumbs(socket, breadcrumbs) do
    ancestor_uuids = Enum.map(breadcrumbs, & &1.uuid)
    expanded = Enum.reduce(ancestor_uuids, socket.assigns.expanded_folders, &MapSet.put(&2, &1))
    assign(socket, :expanded_folders, expanded)
  end

  defp push_tree_state(socket) do
    push_event(socket, "save_tree_state", %{
      expanded: MapSet.to_list(socket.assigns.expanded_folders),
      sidebar_collapsed: socket.assigns.sidebar_collapsed
    })
  end
end
