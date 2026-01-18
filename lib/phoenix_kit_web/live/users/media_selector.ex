defmodule PhoenixKitWeb.Live.Users.MediaSelector do
  @moduledoc """
  Generic media selector LiveView.

  Provides a reusable interface for selecting media files from anywhere in the admin panel.
  Supports both single and multiple selection modes.

  ## Usage

      # Navigate to selector with query params
      /admin/media/selector?return_to=/admin/publishing/edit&mode=single&filter=image

  ## Query Parameters

  - `return_to` - URL to navigate back to (required)
  - `mode` - "single" or "multiple" (default: "single")
  - `selected` - Comma-separated pre-selected file IDs (optional)
  - `filter` - "image", "video", "all" (default: "all")
  - `page` - Page number for pagination (default: "1")
  """
  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, FileInstance, URLSigner}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  import Ecto.Query

  @per_page 30

  def mount(params, _session, socket) do
    # Handle locale
    locale =
      params["locale"] || socket.assigns[:current_locale]

    # Get project title
    project_title = Settings.get_project_title()

    # Parse query parameters
    return_to = params["return_to"] || "/"
    mode = parse_mode(params["mode"])
    selected_ids = parse_selected_ids(params["selected"])
    filter = parse_filter(params["filter"])
    page = String.to_integer(params["page"] || "1")

    # Allow file uploads
    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/media/selector"))
      |> assign(:project_title, project_title)
      |> assign(:page_title, "Select Media")
      |> assign(:return_to, return_to)
      |> assign(:selection_mode, mode)
      |> assign(:selected_ids, selected_ids)
      |> assign(:file_type_filter, filter)
      |> assign(:search_query, "")
      |> assign(:current_page, page)
      |> assign(:per_page, @per_page)
      |> allow_upload(:media_files,
        accept: :any,
        max_entries: 10,
        auto_upload: true,
        progress: &handle_progress/3
      )

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    page = String.to_integer(params["page"] || "1")

    # Load files based on current filters and page
    {files, total_count} = load_files(socket, page)
    total_pages = ceil(total_count / socket.assigns.per_page)

    socket =
      socket
      |> assign(:current_page, page)
      |> assign(:uploaded_files, files)
      |> assign(:total_count, total_count)
      |> assign(:total_pages, total_pages)

    {:noreply, socket}
  end

  def handle_event("toggle_selection", %{"file-id" => file_id}, socket) do
    selected_ids = socket.assigns.selected_ids
    mode = socket.assigns.selection_mode

    new_selected_ids =
      case mode do
        :single ->
          # Single mode: replace selection
          MapSet.new([file_id])

        :multiple ->
          # Multiple mode: toggle selection
          if MapSet.member?(selected_ids, file_id) do
            MapSet.delete(selected_ids, file_id)
          else
            MapSet.put(selected_ids, file_id)
          end
      end

    {:noreply, assign(socket, :selected_ids, new_selected_ids)}
  end

  def handle_event("confirm_selection", _params, socket) do
    return_to = socket.assigns.return_to
    selected_ids = socket.assigns.selected_ids

    # Build return URL with selected_media param
    selected_media_param = selected_ids |> MapSet.to_list() |> Enum.join(",")

    return_url =
      if String.contains?(return_to, "?") do
        "#{return_to}&selected_media=#{selected_media_param}"
      else
        "#{return_to}?selected_media=#{selected_media_param}"
      end

    {:noreply, push_navigate(socket, to: return_url)}
  end

  def handle_event("cancel_selection", _params, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns.return_to)}
  end

  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    socket =
      socket
      |> assign(:search_query, query)
      |> assign(:current_page, 1)

    # Reload files with search query
    {files, total_count} = load_files(socket, 1)
    total_pages = ceil(total_count / socket.assigns.per_page)

    socket =
      socket
      |> assign(:uploaded_files, files)
      |> assign(:total_count, total_count)
      |> assign(:total_pages, total_pages)

    {:noreply, socket}
  end

  def handle_event("filter_type", %{"filter" => filter}, socket) do
    parsed_filter = parse_filter(filter)

    socket =
      socket
      |> assign(:file_type_filter, parsed_filter)
      |> assign(:current_page, 1)

    # Reload files with new filter
    {files, total_count} = load_files(socket, 1)
    total_pages = ceil(total_count / socket.assigns.per_page)

    socket =
      socket
      |> assign(:uploaded_files, files)
      |> assign(:total_count, total_count)
      |> assign(:total_pages, total_pages)

    {:noreply, socket}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save", _params, socket) do
    # Files are auto-uploaded, just reload the list
    {files, total_count} = load_files(socket, 1)
    total_pages = ceil(total_count / socket.assigns.per_page)

    socket =
      socket
      |> assign(:current_page, 1)
      |> assign(:uploaded_files, files)
      |> assign(:total_count, total_count)
      |> assign(:total_pages, total_pages)
      |> put_flash(:info, "Files uploaded successfully")

    {:noreply, socket}
  end

  defp handle_progress(:media_files, entry, socket) do
    if entry.done? do
      # Process the completed upload
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        process_upload(socket, path, entry)
      end)
    end

    {:noreply, socket}
  end

  defp process_upload(socket, path, entry) do
    # Get file info
    ext = Path.extname(entry.client_name) |> String.replace_leading(".", "")
    mime_type = entry.client_type || MIME.from_path(entry.client_name)
    file_type = determine_file_type(mime_type)

    # Get current user
    current_user = socket.assigns[:phoenix_kit_current_user]
    user_id = if current_user, do: current_user.id, else: 1

    # Calculate hash
    file_hash = Auth.calculate_file_hash(path)

    # Store file in storage
    case Storage.store_file_in_buckets(
           path,
           file_type,
           user_id,
           file_hash,
           ext,
           entry.client_name
         ) do
      {:ok, file, :duplicate} ->
        Logger.info("Duplicate file uploaded: #{file.id}")
        {:ok, file.id}

      {:ok, file} ->
        Logger.info("New file uploaded: #{file.id}")
        {:ok, file.id}

      {:error, reason} ->
        Logger.error("Upload failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp load_files(socket, page) do
    repo = PhoenixKit.Config.get_repo()
    per_page = socket.assigns.per_page
    filter = socket.assigns.file_type_filter
    search = socket.assigns.search_query

    # Build query
    query = from(f in File, order_by: [desc: f.inserted_at])

    # Apply file type filter
    query =
      case filter do
        :image -> where(query, [f], f.file_type == "image")
        :video -> where(query, [f], f.file_type == "video")
        :all -> query
      end

    # Apply search filter
    query =
      if search != "" do
        search_pattern = "%#{search}%"
        where(query, [f], ilike(f.original_file_name, ^search_pattern))
      else
        query
      end

    # Get total count
    total_count = repo.aggregate(query, :count, :id)

    # Get paginated files
    offset = (page - 1) * per_page

    files =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> repo.all()

    # Batch load instances to avoid N+1
    file_ids = Enum.map(files, & &1.id)

    instances_by_file =
      if Enum.any?(file_ids) do
        from(fi in FileInstance,
          where: fi.file_id in ^file_ids
        )
        |> repo.all()
        |> Enum.group_by(& &1.file_id)
      else
        %{}
      end

    # Convert to file data maps
    files_with_urls =
      Enum.map(files, fn file ->
        instances = Map.get(instances_by_file, file.id, [])
        urls = generate_urls_from_instances(instances, file.id)

        %{
          file_id: file.id,
          filename: file.original_file_name || file.file_name || "Unknown",
          original_filename: file.original_file_name,
          file_type: file.file_type,
          mime_type: file.mime_type,
          size: file.size || 0,
          status: file.status,
          urls: urls,
          width: get_width_from_instances(instances),
          height: get_height_from_instances(instances)
        }
      end)

    {files_with_urls, total_count}
  end

  defp generate_urls_from_instances(instances, file_id) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      url = URLSigner.signed_url(file_id, instance.variant_name)
      Map.put(acc, instance.variant_name, url)
    end)
  end

  defp get_width_from_instances(instances) do
    case Enum.find(instances, &(&1.variant_name == "original")) do
      nil -> nil
      instance -> instance.width
    end
  end

  defp get_height_from_instances(instances) do
    case Enum.find(instances, &(&1.variant_name == "original")) do
      nil -> nil
      instance -> instance.height
    end
  end

  defp determine_file_type(mime_type) do
    cond do
      String.starts_with?(mime_type, "image/") -> "image"
      String.starts_with?(mime_type, "video/") -> "video"
      true -> "other"
    end
  end

  defp parse_mode(nil), do: :single
  defp parse_mode("single"), do: :single
  defp parse_mode("multiple"), do: :multiple
  defp parse_mode(_), do: :single

  defp parse_selected_ids(nil), do: MapSet.new()

  defp parse_selected_ids(selected_string) when is_binary(selected_string) do
    selected_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp parse_selected_ids(_), do: MapSet.new()

  defp parse_filter(nil), do: :all
  defp parse_filter("image"), do: :image
  defp parse_filter("video"), do: :video
  defp parse_filter("all"), do: :all
  defp parse_filter(_), do: :all

  defp format_file_size(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_file_size(_), do: "0 B"

  defp pagination_range(current_page, total_pages) do
    cond do
      total_pages <= 7 ->
        Enum.to_list(1..total_pages)

      current_page <= 4 ->
        [1, 2, 3, 4, 5, :ellipsis, total_pages]

      current_page >= total_pages - 3 ->
        [1, :ellipsis | Enum.to_list((total_pages - 4)..total_pages)]

      true ->
        [1, :ellipsis, current_page - 1, current_page, current_page + 1, :ellipsis, total_pages]
    end
  end
end
