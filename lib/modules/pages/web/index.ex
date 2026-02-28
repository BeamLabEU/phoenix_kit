defmodule PhoenixKit.Modules.Pages.Web.Index do
  @moduledoc """
  LiveView for Pages file management interface.

  Provides tree-based navigation and file editing.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Pages
  alias PhoenixKit.Modules.Pages.FileOperations
  alias PhoenixKit.Modules.Pages.HtmlMetadata
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.Date, as: UtilsDate

  def mount(_params, _session, socket) do
    # Set locale
    locale = socket.assigns[:current_locale] || "en"

    # Check if module is enabled
    if Pages.enabled?() do
      # Initialize root directory
      root_path = Pages.root_path()

      socket =
        socket
        |> assign(:page_title, "Pages")
        |> assign(:current_path, "/")
        |> assign(:items, [])
        # Root expanded by default
        |> assign(:expanded_folders, MapSet.new(["/"]))
        |> assign(:show_new_file_modal, false)
        |> assign(:show_new_folder_modal, false)
        |> assign(:new_item_name, "")
        |> assign(:show_delete_modal, false)
        |> assign(:delete_item_path, nil)
        |> assign(:delete_item_name, nil)
        |> assign(:delete_item_type, nil)
        |> assign(:delete_item_counts, nil)
        |> assign(:show_move_modal, false)
        |> assign(:move_item_path, nil)
        |> assign(:move_item_name, nil)
        |> assign(:available_folders, [])
        |> assign(:selected_destination, "/")
        |> assign(:show_copy_modal, false)
        |> assign(:copy_item_path, nil)
        |> assign(:copy_item_name, nil)
        |> assign(:copy_destination, "/")
        |> assign(:project_title, PhoenixKit.Settings.get_project_title())
        |> assign(:current_locale, locale)
        |> assign(:root_path, root_path)

      {:ok, socket}
    else
      socket =
        socket
        |> put_flash(:error, "Pages module is not enabled")
        |> redirect(to: Routes.path("/admin/modules"))

      {:ok, socket}
    end
  end

  def handle_params(params, _uri, socket) do
    # Get path from URL params, default to root
    path = Map.get(params, "path", "/")

    # Load directory at this path
    case FileOperations.list_directory(path) do
      {:ok, items} ->
        # Filter out items outside sandbox
        root_path = socket.assigns.root_path
        filtered_items = Enum.filter(items, &item_within_sandbox?(&1, root_path))

        # Enrich items with metadata for files
        enriched_items = enrich_items_with_metadata(filtered_items)

        socket =
          socket
          |> assign(:current_path, path)
          |> assign(:items, enriched_items)

        {:noreply, socket}

      {:error, _reason} ->
        # Path doesn't exist, redirect to root
        socket =
          socket
          |> put_flash(:error, "Directory not found: #{path}")
          |> push_patch(to: Routes.path("/admin/pages"))

        {:noreply, socket}
    end
  end

  ## Event Handlers

  def handle_event("toggle_folder", %{"path" => path}, socket) do
    # Use push_patch to update URL instead of directly assigning
    # handle_params will handle the actual directory loading
    {:noreply, push_patch(socket, to: Routes.path("/admin/pages?path=#{path}"))}
  end

  def handle_event("show_new_file_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_new_file_modal, true)
      |> assign(:new_item_name, "")

    {:noreply, socket}
  end

  def handle_event("show_new_folder_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_new_folder_modal, true)
      |> assign(:new_item_name, "")

    {:noreply, socket}
  end

  def handle_event("close_new_file_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_new_file_modal, false)
      |> assign(:new_item_name, "")

    {:noreply, socket}
  end

  def handle_event("close_new_folder_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_new_folder_modal, false)
      |> assign(:new_item_name, "")

    {:noreply, socket}
  end

  def handle_event("update_new_item_name", %{"name" => name}, socket) do
    socket = assign(socket, :new_item_name, name)
    {:noreply, socket}
  end

  def handle_event("create_file", _params, socket) do
    name = socket.assigns.new_item_name
    current_path = socket.assigns.current_path

    if name == "" do
      socket = put_flash(socket, :error, "File name cannot be empty")
      {:noreply, socket}
    else
      file_path = Path.join(current_path, name)

      # Check if anything with this exact name already exists
      if FileOperations.exists?(file_path) do
        socket = put_flash(socket, :error, "A file or folder named '#{name}' already exists")
        {:noreply, socket}
      else
        # Create file with default metadata
        metadata = HtmlMetadata.default_metadata()
        initial_content = HtmlMetadata.serialize(metadata) <> "\n\n"

        case FileOperations.write_file(file_path, initial_content) do
          :ok ->
            socket =
              socket
              |> assign(:show_new_file_modal, false)
              |> assign(:new_item_name, "")
              |> put_flash(:info, "File created: #{name}")
              |> redirect(to: Routes.path("/admin/pages/edit?path=#{file_path}"))

            {:noreply, socket}

          {:error, _reason} ->
            socket = put_flash(socket, :error, "Failed to create file")
            {:noreply, socket}
        end
      end
    end
  end

  def handle_event("create_folder", _params, socket) do
    name = socket.assigns.new_item_name
    current_path = socket.assigns.current_path

    if name == "" do
      socket = put_flash(socket, :error, "Folder name cannot be empty")
      {:noreply, socket}
    else
      folder_path = Path.join(current_path, name)

      # Check if anything with this exact name already exists
      if FileOperations.exists?(folder_path) do
        socket = put_flash(socket, :error, "A file or folder named '#{name}' already exists")
        {:noreply, socket}
      else
        case FileOperations.create_directory(folder_path) do
          :ok ->
            socket =
              socket
              |> assign(:show_new_folder_modal, false)
              |> assign(:new_item_name, "")
              |> refresh_tree()
              |> put_flash(:info, "Folder created: #{name}")

            {:noreply, socket}

          {:error, _reason} ->
            socket = put_flash(socket, :error, "Failed to create folder")
            {:noreply, socket}
        end
      end
    end
  end

  def handle_event("navigate_to", %{"path" => path}, socket) do
    # Use push_patch to update URL instead of directly assigning
    # handle_params will handle the actual directory loading
    {:noreply, push_patch(socket, to: Routes.path("/admin/pages?path=#{path}"))}
  end

  def handle_event("show_delete_modal", %{"path" => path, "name" => name}, socket) do
    # Determine if it's a file or folder and count contents if folder
    item_type = if FileOperations.directory_exists?(path), do: :folder, else: :file

    counts =
      if item_type == :folder do
        FileOperations.count_contents(path)
      else
        nil
      end

    socket =
      socket
      |> assign(:show_delete_modal, true)
      |> assign(:delete_item_path, path)
      |> assign(:delete_item_name, name)
      |> assign(:delete_item_type, item_type)
      |> assign(:delete_item_counts, counts)

    {:noreply, socket}
  end

  def handle_event("close_delete_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_delete_modal, false)
      |> assign(:delete_item_path, nil)
      |> assign(:delete_item_name, nil)
      |> assign(:delete_item_type, nil)
      |> assign(:delete_item_counts, nil)

    {:noreply, socket}
  end

  def handle_event("confirm_delete", _params, socket) do
    path = socket.assigns.delete_item_path
    name = socket.assigns.delete_item_name

    case FileOperations.delete(path) do
      {:ok, _} ->
        socket =
          socket
          |> assign(:show_delete_modal, false)
          |> assign(:delete_item_path, nil)
          |> assign(:delete_item_name, nil)
          |> assign(:delete_item_type, nil)
          |> assign(:delete_item_counts, nil)
          |> refresh_tree()
          |> put_flash(:info, "Deleted: #{name}")

        {:noreply, socket}

      {:error, _reason} ->
        socket =
          socket
          |> put_flash(:error, "Failed to delete: #{name}")
          |> assign(:show_delete_modal, false)
          |> assign(:delete_item_type, nil)
          |> assign(:delete_item_counts, nil)

        {:noreply, socket}
    end
  end

  def handle_event("duplicate", %{"path" => path}, socket) do
    # Generate duplicate name (always start with -1 for first duplicate)
    new_path = generate_duplicate_name(path)

    case FileOperations.copy(path, new_path) do
      {:ok, _} ->
        socket =
          socket
          |> refresh_tree()
          |> put_flash(:info, "Duplicated: #{Path.basename(new_path)}")

        {:noreply, socket}

      {:error, :eisdir} ->
        socket = put_flash(socket, :error, "Cannot duplicate directories")
        {:noreply, socket}

      {:error, _reason} ->
        socket = put_flash(socket, :error, "Failed to duplicate file")
        {:noreply, socket}
    end
  end

  def handle_event("show_move_modal", %{"path" => path, "name" => name}, socket) do
    # Get all available folders for destination selection
    folders = list_all_folders("/")

    socket =
      socket
      |> assign(:show_move_modal, true)
      |> assign(:move_item_path, path)
      |> assign(:move_item_name, name)
      |> assign(:available_folders, folders)
      |> assign(:selected_destination, "/")

    {:noreply, socket}
  end

  def handle_event("close_move_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_move_modal, false)
      |> assign(:move_item_path, nil)
      |> assign(:move_item_name, nil)
      |> assign(:available_folders, [])

    {:noreply, socket}
  end

  def handle_event("update_destination", %{"destination" => destination}, socket) do
    {:noreply, assign(socket, :selected_destination, destination)}
  end

  def handle_event("confirm_move", _params, socket) do
    source_path = socket.assigns.move_item_path
    destination_folder = socket.assigns.selected_destination
    name = socket.assigns.move_item_name

    # Build destination path
    dest_path = Path.join(destination_folder, Path.basename(source_path))

    # Check if destination already exists
    if FileOperations.exists?(dest_path) do
      socket =
        socket
        |> put_flash(:error, "A file or folder with this name already exists in the destination")

      {:noreply, socket}
    else
      case FileOperations.move(source_path, dest_path) do
        :ok ->
          socket =
            socket
            |> assign(:show_move_modal, false)
            |> assign(:move_item_path, nil)
            |> assign(:move_item_name, nil)
            |> refresh_tree()
            |> put_flash(:info, "Moved #{name} to #{destination_folder}")

          {:noreply, socket}

        {:error, _reason} ->
          socket =
            socket
            |> put_flash(:error, "Failed to move #{name}")
            |> assign(:show_move_modal, false)

          {:noreply, socket}
      end
    end
  end

  def handle_event("show_copy_modal", %{"path" => path, "name" => name}, socket) do
    # Get all available folders for destination selection
    folders = list_all_folders("/")

    socket =
      socket
      |> assign(:show_copy_modal, true)
      |> assign(:copy_item_path, path)
      |> assign(:copy_item_name, name)
      |> assign(:available_folders, folders)
      |> assign(:copy_destination, "/")

    {:noreply, socket}
  end

  def handle_event("close_copy_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_copy_modal, false)
      |> assign(:copy_item_path, nil)
      |> assign(:copy_item_name, nil)
      |> assign(:available_folders, [])

    {:noreply, socket}
  end

  def handle_event("update_copy_destination", %{"destination" => destination}, socket) do
    {:noreply, assign(socket, :copy_destination, destination)}
  end

  def handle_event("confirm_copy", _params, socket) do
    source_path = socket.assigns.copy_item_path
    destination_folder = socket.assigns.copy_destination
    name = socket.assigns.copy_item_name

    # Build destination path
    dest_path = Path.join(destination_folder, Path.basename(source_path))

    # Check if destination already exists, if so, generate unique name
    final_dest_path =
      if FileOperations.exists?(dest_path) do
        FileOperations.generate_unique_name(dest_path)
      else
        dest_path
      end

    case FileOperations.copy(source_path, final_dest_path) do
      {:ok, _} ->
        socket =
          socket
          |> assign(:show_copy_modal, false)
          |> assign(:copy_item_path, nil)
          |> assign(:copy_item_name, nil)
          |> refresh_tree()
          |> put_flash(:info, "Copied #{name} to #{destination_folder}")

        {:noreply, socket}

      {:error, :eisdir} ->
        socket =
          socket
          |> put_flash(:error, "Cannot copy directories")
          |> assign(:show_copy_modal, false)

        {:noreply, socket}

      {:error, _reason} ->
        socket =
          socket
          |> put_flash(:error, "Failed to copy #{name}")
          |> assign(:show_copy_modal, false)

        {:noreply, socket}
    end
  end

  def handle_event("change_file_status", %{"path" => path, "status" => new_status}, socket) do
    case FileOperations.read_file(path) do
      {:ok, content} ->
        updated_content = update_metadata_status(content, new_status)

        case FileOperations.write_file(path, updated_content) do
          :ok ->
            socket =
              socket
              |> refresh_tree()
              |> put_flash(:info, "Status changed to: #{new_status}")

            {:noreply, socket}

          {:error, _reason} ->
            socket = put_flash(socket, :error, "Failed to update status")
            {:noreply, socket}
        end

      {:error, _reason} ->
        socket = put_flash(socket, :error, "Failed to read file")
        {:noreply, socket}
    end
  end

  def handle_event("debug_edit_click", %{"path" => path}, socket) do
    # Navigate to the editor
    {:noreply,
     push_navigate(socket, to: Routes.path("/admin/pages/edit?path=#{URI.encode(path)}"))}
  end

  ## Private Helpers

  defp refresh_tree(socket) do
    case FileOperations.list_directory(socket.assigns.current_path) do
      {:ok, items} ->
        enriched_items = enrich_items_with_metadata(items)
        assign(socket, :items, enriched_items)

      {:error, _reason} ->
        socket
    end
  end

  defp enrich_items_with_metadata(items) do
    Enum.map(items, &enrich_single_item/1)
  end

  defp enrich_single_item(%{type: :file} = item) do
    file_info = get_file_info(item.path)
    metadata = get_file_metadata(item.path)

    item
    |> Map.put(:metadata, metadata)
    |> Map.put(:size, file_info.size)
    |> Map.put(:mtime, file_info.mtime)
  end

  defp enrich_single_item(item), do: item

  defp get_file_info(path) do
    case FileOperations.file_info(path) do
      {:ok, info} -> info
      {:error, _} -> %{size: 0, mtime: nil}
    end
  end

  defp get_file_metadata(path) do
    with {:ok, content} <- FileOperations.read_file(path),
         {:ok, meta, _stripped} <- HtmlMetadata.parse(content) do
      meta
    else
      _ -> HtmlMetadata.default_metadata()
    end
  end

  defp list_all_folders(path) do
    root_path = Pages.root_path()

    case FileOperations.list_directory(path) do
      {:ok, items} ->
        folders =
          items
          |> Enum.filter(&(&1.type == :folder and folder_within_sandbox?(&1, root_path)))
          |> Enum.flat_map(fn folder ->
            # Add current folder and all its subfolders
            [folder.path | list_all_folders(folder.path)]
          end)

        # Always include root
        ["/" | folders]
        |> Enum.uniq()
        |> Enum.sort()

      {:error, _reason} ->
        ["/"]
    end
  end

  defp item_within_sandbox?(item, root_path) do
    # Build the full path to verify it's within sandbox
    full_path = Path.join(root_path, String.trim_leading(item.path, "/"))

    # Verify the item actually exists and is what it claims to be
    case item.type do
      :folder ->
        # Verify it's actually a directory
        if File.dir?(full_path) do
          check_path_within_sandbox(full_path, root_path)
        else
          false
        end

      :file ->
        # Verify it's actually a file
        if File.exists?(full_path) and not File.dir?(full_path) do
          check_path_within_sandbox(full_path, root_path)
        else
          false
        end
    end
  end

  defp folder_within_sandbox?(item, root_path) do
    # Build the full path to verify it's within sandbox
    full_path = Path.join(root_path, String.trim_leading(item.path, "/"))

    # First, verify it's actually a directory (not a file misidentified as folder)
    if File.dir?(full_path) do
      check_path_within_sandbox(full_path, root_path)
    else
      false
    end
  end

  defp check_path_within_sandbox(full_path, root_path) do
    # Resolve to absolute path (follows symlinks)
    case File.read_link(full_path) do
      {:ok, link_target} ->
        # It's a symlink - check if target is within sandbox
        resolved_path =
          if String.starts_with?(link_target, "/") do
            link_target
          else
            Path.expand(link_target, Path.dirname(full_path))
          end

        String.starts_with?(resolved_path, root_path)

      {:error, _} ->
        # Not a symlink, verify the path itself is within root
        String.starts_with?(Path.expand(full_path), root_path)
    end
  end

  defp generate_duplicate_name(path) do
    # Extract base and extension
    {base, ext} =
      if Path.extname(path) != "" do
        {Path.rootname(path), Path.extname(path)}
      else
        {path, ""}
      end

    # Start checking from -1
    do_generate_duplicate_name(base, ext, 1)
  end

  defp do_generate_duplicate_name(base, ext, counter) do
    new_path = "#{base}-#{counter}#{ext}"

    if FileOperations.exists?(new_path) do
      do_generate_duplicate_name(base, ext, counter + 1)
    else
      new_path
    end
  end

  defp update_metadata_status(content, new_status) do
    case HtmlMetadata.parse(content) do
      {:ok, metadata, _stripped_content} ->
        # Update both status and updated_at timestamp
        updated_metadata =
          metadata
          |> Map.put(:status, new_status)
          |> Map.put(:updated_at, UtilsDate.utc_now())

        HtmlMetadata.update_metadata(content, updated_metadata)

      {:error, :no_metadata} ->
        # No metadata exists, create new metadata with the status
        metadata =
          HtmlMetadata.default_metadata()
          |> Map.put(:status, new_status)
          |> Map.put(:updated_at, UtilsDate.utc_now())

        # Prepend metadata to content
        HtmlMetadata.serialize(metadata) <> "\n\n" <> content
    end
  end
end
