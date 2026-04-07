defmodule PhoenixKitWeb.Live.Users.Media do
  @moduledoc """
  Media management LiveView for PhoenixKit admin panel.

  Provides interface for viewing and managing user media.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale =
      params["locale"] || socket.assigns[:current_locale]

    # Batch load all settings needed for this page (uses cached settings for performance)
    settings =
      Settings.get_settings_cached(
        ["project_title"],
        %{"project_title" => PhoenixKit.Config.get(:project_title, "PhoenixKit")}
      )

    # Check if any enabled buckets exist
    enabled_buckets = Storage.list_enabled_buckets()
    has_buckets = not Enum.empty?(enabled_buckets)

    socket =
      socket
      |> maybe_allow_upload(has_buckets)
      |> assign(:page_title, "Media")
      |> assign(:project_title, settings["project_title"])
      |> assign(:current_locale, locale)
      |> assign(:url_path, Routes.path("/admin/media"))
      |> assign(:show_upload, false)
      |> assign(:last_uploaded_file_uuids, [])
      |> assign(:has_buckets, has_buckets)
      |> assign(:filter_orphaned, false)
      |> assign(:orphaned_count, 0)
      |> assign(:current_folder, nil)
      |> assign(:breadcrumbs, [])
      |> assign(:folders, [])
      |> assign(:folder_tree, [])
      |> assign(:show_new_folder, false)
      |> assign(:show_sidebar, true)
      |> assign(:view_mode, "grid")
      |> assign(:select_mode, false)
      |> assign(:selected_files, MapSet.new())
      |> assign(:show_move_modal, false)

    {:ok, socket}
  end

  attr :node, :map, required: true
  attr :current_folder, :any, required: true
  attr :depth, :integer, default: 0

  def folder_tree_node(assigns) do
    ~H"""
    <li>
      <.link
        navigate={PhoenixKit.Utils.Routes.path("/admin/media?folder=#{@node.folder.uuid}")}
        class={
          if @current_folder && @current_folder.uuid == @node.folder.uuid, do: "active", else: ""
        }
      >
        <.icon name="hero-folder" class="w-4 h-4" /> {@node.folder.name}
      </.link>
      <%= if @node.children != [] do %>
        <ul>
          <%= for child <- @node.children do %>
            <.folder_tree_node
              node={child}
              current_folder={@current_folder}
              depth={@depth + 1}
            />
          <% end %>
        </ul>
      <% end %>
    </li>
    """
  end

  attr :node, :map, required: true
  attr :depth, :integer, default: 0

  def move_folder_option(assigns) do
    ~H"""
    <li>
      <button
        phx-click="move_selected_to_folder"
        phx-value-folder_uuid={@node.folder.uuid}
        style={"padding-left: #{(@depth + 1) * 16}px"}
      >
        <.icon name="hero-folder" class="w-4 h-4" /> {@node.folder.name}
      </button>
      <%= for child <- @node.children do %>
        <.move_folder_option node={child} depth={@depth + 1} />
      <% end %>
    </li>
    """
  end

  defp maybe_allow_upload(socket, has_buckets) do
    if has_buckets do
      max_size_mb =
        Settings.get_setting_cached("storage_max_upload_size_mb", "500")
        |> String.to_integer()

      socket
      |> assign(:max_upload_size_mb, max_size_mb)
      |> allow_upload(:media_files,
        accept: :any,
        max_entries: 10,
        max_file_size: max_size_mb * 1_000_000,
        auto_upload: true
      )
    else
      socket
      |> assign(:max_upload_size_mb, 0)
    end
  end

  def handle_params(params, _uri, socket) do
    per_page = 50
    page = String.to_integer(params["page"] || "1")
    folder_uuid = params["folder"]

    filter_orphaned = socket.assigns[:filter_orphaned] || false

    # Load folder context
    current_folder = if folder_uuid, do: Storage.get_folder(folder_uuid), else: nil
    breadcrumbs = Storage.folder_breadcrumbs(folder_uuid)
    folders = Storage.list_folders(folder_uuid)
    folder_tree = Storage.list_all_folders() |> Storage.build_folder_tree()

    {existing_files, total_count} =
      if filter_orphaned do
        load_orphaned_files(page, per_page)
      else
        load_existing_files(page, per_page, folder_uuid)
      end

    total_pages = ceil(total_count / per_page)

    orphaned_count =
      if filter_orphaned do
        total_count
      else
        Storage.count_orphaned_files()
      end

    socket =
      socket
      |> assign(:uploaded_files, existing_files)
      |> assign(:current_page, page)
      |> assign(:per_page, per_page)
      |> assign(:total_pages, total_pages)
      |> assign(:total_count, total_count)
      |> assign(:orphaned_count, orphaned_count)
      |> assign(:current_folder, current_folder)
      |> assign(:breadcrumbs, breadcrumbs)
      |> assign(:folders, folders)
      |> assign(:folder_tree, folder_tree)

    {:noreply, socket}
  end

  def handle_event("toggle_new_folder", _params, socket) do
    {:noreply, assign(socket, :show_new_folder, !socket.assigns.show_new_folder)}
  end

  def handle_event("create_folder", %{"name" => name}, socket) do
    folder_uuid =
      if socket.assigns.current_folder, do: socket.assigns.current_folder.uuid, else: nil

    user = socket.assigns[:phoenix_kit_current_user]

    case Storage.create_folder(%{
           name: name,
           parent_uuid: folder_uuid,
           user_uuid: user && user.uuid
         }) do
      {:ok, _folder} ->
        socket =
          socket
          |> assign(:show_new_folder, false)
          |> assign(:folders, Storage.list_folders(folder_uuid))
          |> assign(:folder_tree, Storage.list_all_folders() |> Storage.build_folder_tree())
          |> put_flash(:info, "Folder created")

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create folder")}
    end
  end

  def handle_event("delete_folder", %{"id" => folder_uuid}, socket) do
    folder = Storage.get_folder(folder_uuid)

    if folder do
      Storage.delete_folder(folder)
      parent_uuid = if socket.assigns.current_folder, do: socket.assigns.current_folder.uuid

      socket =
        socket
        |> assign(:folders, Storage.list_folders(parent_uuid))
        |> assign(:folder_tree, Storage.list_all_folders() |> Storage.build_folder_tree())
        |> put_flash(:info, "Folder deleted")

      {:noreply, socket}
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

    case Storage.move_file_to_folder(file_uuid, target) do
      {:ok, _file} ->
        {:noreply,
         socket
         |> put_flash(:info, "File moved")
         |> push_patch(to: current_media_path(socket))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to move file")}
    end
  end

  def handle_event("navigate_folder", %{"folder-uuid" => folder_uuid}, socket) do
    {:noreply,
     push_navigate(socket,
       to: Routes.path("/admin/media?folder=#{folder_uuid}")
     )}
  end

  def handle_event("set_view_mode", %{"mode" => mode}, socket) when mode in ["grid", "list"] do
    {:noreply, assign(socket, :view_mode, mode)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :show_sidebar, !socket.assigns.show_sidebar)}
  end

  def handle_event("toggle_select_mode", _params, socket) do
    if socket.assigns.select_mode do
      # Exiting select mode — clear selection
      {:noreply,
       socket
       |> assign(:select_mode, false)
       |> assign(:selected_files, MapSet.new())}
    else
      {:noreply, assign(socket, :select_mode, true)}
    end
  end

  def handle_event("click_file", %{"file-uuid" => file_uuid}, socket) do
    if socket.assigns.select_mode do
      # Select mode — toggle selection
      selected = socket.assigns.selected_files

      selected =
        if MapSet.member?(selected, file_uuid),
          do: MapSet.delete(selected, file_uuid),
          else: MapSet.put(selected, file_uuid)

      {:noreply, assign(socket, :selected_files, selected)}
    else
      # Normal mode — navigate to file detail
      {:noreply,
       push_navigate(socket,
         to: Routes.path("/admin/media/#{file_uuid}")
       )}
    end
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
    all_uuids = Enum.map(socket.assigns.uploaded_files, & &1.file_uuid)
    {:noreply, assign(socket, :selected_files, MapSet.new(all_uuids))}
  end

  def handle_event("deselect_all", _params, socket) do
    {:noreply,
     socket
     |> assign(:select_mode, false)
     |> assign(:selected_files, MapSet.new())}
  end

  def handle_event("show_move_modal", _params, socket) do
    {:noreply, assign(socket, :show_move_modal, true)}
  end

  def handle_event("close_move_modal", _params, socket) do
    {:noreply, assign(socket, :show_move_modal, false)}
  end

  def handle_event("move_selected_to_folder", %{"folder_uuid" => folder_uuid}, socket) do
    target = if folder_uuid == "", do: nil, else: folder_uuid

    Enum.each(socket.assigns.selected_files, fn file_uuid ->
      Storage.move_file_to_folder(file_uuid, target)
    end)

    count = MapSet.size(socket.assigns.selected_files)

    {:noreply,
     socket
     |> assign(:select_mode, false)
     |> assign(:selected_files, MapSet.new())
     |> assign(:show_move_modal, false)
     |> put_flash(:info, "#{count} file(s) moved")
     |> push_patch(to: current_media_path(socket))}
  end

  def handle_event("toggle_orphan_filter", _params, socket) do
    filter_orphaned = !socket.assigns.filter_orphaned
    per_page = socket.assigns.per_page || 50

    {files, total_count} =
      if filter_orphaned do
        load_orphaned_files(1, per_page)
      else
        load_existing_files(1, per_page)
      end

    orphaned_count = if filter_orphaned, do: total_count, else: Storage.count_orphaned_files()

    {:noreply,
     socket
     |> assign(:filter_orphaned, filter_orphaned)
     |> assign(:uploaded_files, files)
     |> assign(:current_page, 1)
     |> assign(:total_pages, ceil(total_count / per_page))
     |> assign(:total_count, total_count)
     |> assign(:orphaned_count, orphaned_count)}
  end

  def handle_event("delete_all_orphaned", _params, socket) do
    orphan_uuids =
      Storage.find_orphaned_files()
      |> Enum.map(& &1.uuid)

    Storage.queue_file_cleanup(orphan_uuids)

    {:noreply,
     put_flash(socket, :info, "#{length(orphan_uuids)} orphaned files queued for deletion")}
  end

  def handle_event("toggle_upload", _params, socket) do
    {:noreply, assign(socket, :show_upload, !socket.assigns.show_upload)}
  end

  def handle_event("validate", _params, socket) do
    entries = socket.assigns.uploads.media_files.entries

    if entries != [] do
      Process.send_after(self(), :check_uploads_complete, 500)
    end

    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media_files, ref)}
  end

  def handle_info({:file_uploaded, _file_uuid}, socket) do
    {:noreply, socket}
  end

  def handle_info(:check_uploads_complete, socket) do
    entries = socket.assigns.uploads.media_files.entries

    cond do
      entries == [] ->
        # No entries left (all cancelled or consumed)
        {:noreply, socket}

      Enum.all?(entries, & &1.done?) ->
        process_uploads(socket)

      Enum.any?(entries, & &1.cancelled?) ||
          socket.assigns.uploads.media_files.errors != [] ->
        Logger.warning("Upload rejected: #{inspect(socket.assigns.uploads.media_files.errors)}")

        {:noreply, socket}

      true ->
        Process.send_after(self(), :check_uploads_complete, 500)
        {:noreply, socket}
    end
  end

  defp process_uploads(socket) do
    # Process uploaded files
    uploaded_files =
      consume_uploaded_entries(socket, :media_files, fn %{path: path}, entry ->
        process_single_upload(socket, path, entry)
      end)

    # Reload paginated data from database to show newly uploaded files
    per_page = socket.assigns.per_page || 50
    page = socket.assigns.current_page || 1
    {refreshed_files, total_count} = load_existing_files(page, per_page)
    total_pages = ceil(total_count / per_page)

    # Extract file UUIDs for callbacks (only from successful uploads)
    file_uuids = Enum.map(uploaded_files, &get_file_uuid/1) |> Enum.reject(&is_nil/1)

    # Build flash message based on upload results
    {flash_type, flash_message} = build_upload_flash_message(uploaded_files)

    socket =
      socket
      |> assign(:uploaded_files, refreshed_files)
      |> assign(:total_count, total_count)
      |> assign(:total_pages, total_pages)
      |> assign(:last_uploaded_file_uuids, file_uuids)
      |> put_flash(flash_type, flash_message)

    {:noreply, socket}
  end

  defp get_file_uuid({:ok, %{file_uuid: file_uuid}}), do: file_uuid
  defp get_file_uuid({:postpone, _}), do: nil
  defp get_file_uuid(_), do: nil

  # Generate URLs from pre-loaded instances (no database query needed)
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

  # Format file size in human-readable format
  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 2)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 2)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  # Get icon for file type
  defp file_icon("image"), do: "hero-photo"
  defp file_icon("video"), do: "hero-play-circle"
  defp file_icon("pdf"), do: "hero-document-text"
  defp file_icon("document"), do: "hero-document"
  defp file_icon(_), do: "hero-document-arrow-down"

  # Load orphaned files with pagination
  defp load_orphaned_files(page, per_page) do
    repo = PhoenixKit.Config.get_repo()
    offset = (page - 1) * per_page
    total_count = Storage.count_orphaned_files()

    files = Storage.find_orphaned_files(limit: per_page, offset: offset)
    file_uuids = Enum.map(files, & &1.uuid)

    instances_by_file =
      if file_uuids != [] do
        from(fi in FileInstance,
          where: fi.file_uuid in ^file_uuids
        )
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

  # Load existing files from database with pagination, filtered by folder
  defp load_existing_files(page, per_page, folder_uuid \\ nil) do
    repo = PhoenixKit.Config.get_repo()

    # Base query filtered by folder
    base_query =
      if folder_uuid do
        from(f in Storage.File, where: f.folder_uuid == ^folder_uuid)
      else
        from(f in Storage.File, where: is_nil(f.folder_uuid))
      end

    total_count = repo.aggregate(base_query, :count, :uuid)
    offset = (page - 1) * per_page

    files =
      from(f in base_query,
        order_by: [desc: f.inserted_at],
        limit: ^per_page,
        offset: ^offset
      )
      |> repo.all()

    # Batch load ALL file instances in ONE query instead of N queries
    file_uuids = Enum.map(files, & &1.uuid)

    instances_by_file =
      if file_uuids != [] do
        from(fi in FileInstance,
          where: fi.file_uuid in ^file_uuids
        )
        |> repo.all()
        |> Enum.group_by(& &1.file_uuid)
      else
        %{}
      end

    # Convert to same format as uploaded files
    existing_files =
      Enum.map(files, fn file ->
        # Get pre-loaded instances for this file (no DB query!)
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

  defp process_single_upload(socket, path, entry) do
    # Get file info
    ext = Path.extname(entry.client_name) |> String.replace_leading(".", "")
    mime_type = entry.client_type || MIME.from_path(entry.client_name)
    file_type = determine_file_type(mime_type)

    # Get current user
    current_user = socket.assigns.phoenix_kit_current_user
    user_uuid = if current_user, do: current_user.uuid, else: nil

    # Get file size
    {:ok, stat} = Elixir.File.stat(path)
    file_size = stat.size

    # Calculate hash
    file_hash = Auth.calculate_file_hash(path)

    # Store file in storage
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
        Logger.error("Storage Error: #{inspect(reason)}")
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

  # Build flash message based on upload counts
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

  # Check if all uploads failed
  defp all_failed?(error_count, new_count, duplicate_count) do
    error_count > 0 && new_count == 0 && duplicate_count == 0
  end

  # Check if partial success (some errors, some successful)
  defp partial_success?(error_count, new_count) do
    error_count > 0 && new_count > 0
  end

  # Check if only duplicates (no new files)
  defp only_duplicates?(duplicate_count, new_count) do
    duplicate_count > 0 && new_count == 0
  end

  # Check if only new files (no duplicates)
  defp new_files_only?(new_count, duplicate_count) do
    new_count > 0 && duplicate_count == 0
  end

  # Check if both new files and duplicates
  defp new_and_duplicates?(new_count, duplicate_count) do
    new_count > 0 && duplicate_count > 0
  end

  # Flash message builders
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
    folder_uuid =
      if socket.assigns.current_folder, do: socket.assigns.current_folder.uuid, else: nil

    if folder_uuid do
      Storage.move_file_to_folder(file.uuid, folder_uuid)
    end
  end

  defp current_media_path(socket) do
    base = Routes.path("/admin/media")

    if socket.assigns.current_folder do
      base <> "?folder=#{socket.assigns.current_folder.uuid}"
    else
      base
    end
  end
end
