defmodule PhoenixKitWeb.Live.Components.MediaSelectorModal do
  @moduledoc """
  Media selector modal component.

  A reusable modal component for selecting media files from anywhere in the admin panel.
  Supports both single and multiple selection modes.

  ## Usage

      # In parent LiveView, add to socket assigns
      socket
      |> assign(:show_media_selector, false)
      |> assign(:media_selection_mode, :single)
      |> assign(:media_selected_ids, [])

      # In template (IMPORTANT: Must pass phoenix_kit_current_user for uploads to work)
      <.live_component
        module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
        id="media-selector-modal"
        show={@show_media_selector}
        mode={@media_selection_mode}
        selected_ids={@media_selected_ids}
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />

      # To open the modal
      def handle_event("open_media_selector", _params, socket) do
        {:noreply, assign(socket, :show_media_selector, true)}
      end

      # To receive selected media
      def handle_info({:media_selected, file_uuids}, socket) do
        # Handle the selected file UUIDs
        {:noreply, socket |> assign(:gallery_ids, file_uuids)}
      end
  """
  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, FileInstance, URLSigner}
  alias PhoenixKit.Users.Auth

  import Ecto.Query

  # Import core components
  import PhoenixKitWeb.Components.Core.Icon

  @per_page 30

  def update(assigns, socket) do
    # Check if any enabled buckets exist
    enabled_buckets = Storage.list_enabled_buckets()
    has_buckets = not Enum.empty?(enabled_buckets)

    # Save previous state BEFORE assigning new values
    was_shown = socket.assigns[:show] || false
    previous_selected_ids = socket.assigns[:selected_ids]

    socket =
      socket
      |> assign(assigns)
      |> assign(:has_buckets, has_buckets)
      |> assign_new(:file_type_filter, fn -> :all end)
      |> assign_new(:search_query, fn -> "" end)
      |> assign_new(:current_page, fn -> 1 end)
      |> assign_new(:per_page, fn -> @per_page end)
      |> assign_new(:uploaded_files, fn -> [] end)
      |> assign_new(:total_count, fn -> 0 end)
      |> assign_new(:total_pages, fn -> 0 end)
      |> maybe_allow_upload(has_buckets)

    # Handle selected_ids - only reset when modal is opening, otherwise preserve selection
    socket =
      cond do
        # Modal is opening (show transitions from false to true) - initialize from incoming assigns
        assigns[:show] && !was_shown ->
          selected_ids_list = assigns[:selected_ids] || []
          assign(socket, :selected_ids, MapSet.new(selected_ids_list))

        # Modal already open and has selection state - preserve it
        is_struct(previous_selected_ids, MapSet) ->
          assign(socket, :selected_ids, previous_selected_ids)

        # First mount or no previous state - initialize empty
        true ->
          assign(socket, :selected_ids, MapSet.new([]))
      end

    # Load files if modal is shown
    socket =
      if assigns[:show] do
        {files, total_count} = load_files(socket, socket.assigns.current_page)
        total_pages = ceil(total_count / socket.assigns.per_page)

        socket
        |> assign(:uploaded_files, files)
        |> assign(:total_count, total_count)
        |> assign(:total_pages, total_pages)
      else
        socket
      end

    {:ok, socket}
  end

  defp maybe_allow_upload(socket, has_buckets) do
    cond do
      socket.assigns[:uploads] ->
        socket

      has_buckets ->
        allow_upload(socket, :media_files,
          accept: :any,
          max_entries: 10,
          auto_upload: true,
          progress: &handle_progress/3
        )

      true ->
        # No buckets - don't allow upload
        socket
    end
  end

  def handle_event("noop", _params, socket) do
    # No-op event to prevent click propagation
    {:noreply, socket}
  end

  def handle_event("toggle_selection", %{"file-id" => file_uuid}, socket) do
    selected_ids = socket.assigns.selected_ids
    mode = socket.assigns.mode

    Logger.debug(
      "MediaSelectorModal toggle_selection: mode=#{inspect(mode)}, file_uuid=#{file_uuid}"
    )

    new_selected_ids =
      case mode do
        :single ->
          MapSet.new([file_uuid])

        :multiple ->
          if MapSet.member?(selected_ids, file_uuid) do
            MapSet.delete(selected_ids, file_uuid)
          else
            MapSet.put(selected_ids, file_uuid)
          end

        # Handle string versions in case they come through as strings
        "single" ->
          MapSet.new([file_uuid])

        "multiple" ->
          if MapSet.member?(selected_ids, file_uuid) do
            MapSet.delete(selected_ids, file_uuid)
          else
            MapSet.put(selected_ids, file_uuid)
          end

        # Default to single select for any unexpected value
        _ ->
          MapSet.new([file_uuid])
      end

    {:noreply, assign(socket, :selected_ids, new_selected_ids)}
  end

  def handle_event("confirm_selection", _params, socket) do
    selected_ids = socket.assigns.selected_ids |> MapSet.to_list()

    # Send selected IDs to parent LiveView
    send(self(), {:media_selected, selected_ids})

    # Close modal
    {:noreply, assign(socket, :show, false)}
  end

  def handle_event("close_modal", _params, socket) do
    send(self(), {:media_selector_closed})
    {:noreply, assign(socket, :show, false)}
  end

  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    socket =
      socket
      |> assign(:search_query, query)
      |> assign(:current_page, 1)

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

    {files, total_count} = load_files(socket, 1)
    total_pages = ceil(total_count / socket.assigns.per_page)

    socket =
      socket
      |> assign(:uploaded_files, files)
      |> assign(:total_count, total_count)
      |> assign(:total_pages, total_pages)

    {:noreply, socket}
  end

  def handle_event("change_page", %{"page" => page}, socket) do
    page = String.to_integer(page)
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

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media_files, ref)}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save", _params, socket) do
    {files, total_count} = load_files(socket, 1)
    total_pages = ceil(total_count / socket.assigns.per_page)

    socket =
      socket
      |> assign(:current_page, 1)
      |> assign(:uploaded_files, files)
      |> assign(:total_count, total_count)
      |> assign(:total_pages, total_pages)

    {:noreply, socket}
  end

  defp handle_progress(:media_files, entry, socket) do
    socket =
      if entry.done? do
        # Consume the uploaded entry and capture the file ID
        uploaded_results =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            process_upload(socket, path, entry)
          end)

        # Check if upload failed and handle error
        case uploaded_results do
          file_uuid when is_binary(file_uuid) ->
            # Success - reload files and auto-select
            {files, total_count} = load_files(socket, socket.assigns.current_page)
            total_pages = ceil(total_count / socket.assigns.per_page)

            selected_ids =
              case socket.assigns.mode do
                :single -> MapSet.new([file_uuid])
                :multiple -> MapSet.put(socket.assigns.selected_ids, file_uuid)
              end

            socket
            |> assign(:uploaded_files, files)
            |> assign(:total_count, total_count)
            |> assign(:total_pages, total_pages)
            |> assign(:selected_ids, selected_ids)

          _ ->
            # Upload failed - show error message
            socket
            |> put_flash(
              :error,
              "Upload failed: No storage buckets configured. Please configure at least one storage bucket before uploading files."
            )
        end
      else
        socket
      end

    {:noreply, socket}
  end

  defp process_upload(socket, path, entry) do
    ext = Path.extname(entry.client_name) |> String.replace_leading(".", "")
    mime_type = entry.client_type || MIME.from_path(entry.client_name)
    file_type = determine_file_type(mime_type)

    current_user = socket.assigns[:phoenix_kit_current_user]

    if current_user do
      user_uuid = current_user.uuid
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
          Logger.info("Duplicate file uploaded: #{file.uuid}")
          {:ok, file.uuid}

        {:ok, file} ->
          Logger.info("New file uploaded: #{file.uuid}")
          {:ok, file.uuid}

        {:error, reason} ->
          Logger.error("Upload failed: #{inspect(reason)}")
          {:postpone, :error}
      end
    else
      Logger.error("Upload failed: No authenticated user")
      {:postpone, :error}
    end
  end

  defp load_files(socket, page) do
    repo = PhoenixKit.Config.get_repo()
    per_page = socket.assigns.per_page
    filter = socket.assigns.file_type_filter
    search = socket.assigns.search_query

    query = from(f in File, order_by: [desc: f.inserted_at])

    query =
      case filter do
        :image -> where(query, [f], f.file_type == "image")
        :video -> where(query, [f], f.file_type == "video")
        :all -> query
      end

    query =
      if search != "" do
        search_pattern = "%#{search}%"
        where(query, [f], ilike(f.original_file_name, ^search_pattern))
      else
        query
      end

    total_count = repo.aggregate(query, :count, :uuid)
    offset = (page - 1) * per_page

    files =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> repo.all()

    file_uuids = Enum.map(files, & &1.uuid)

    instances_by_file =
      if Enum.any?(file_uuids) do
        from(fi in FileInstance, where: fi.file_uuid in ^file_uuids)
        |> repo.all()
        |> Enum.group_by(& &1.file_uuid)
      else
        %{}
      end

    files_with_urls =
      Enum.map(files, fn file ->
        instances = Map.get(instances_by_file, file.uuid, [])
        urls = generate_urls_from_instances(instances, file.uuid)

        %{
          file_uuid: file.uuid,
          filename: file.original_file_name || file.file_name || "Unknown",
          file_type: file.file_type,
          mime_type: file.mime_type,
          size: file.size || 0,
          urls: urls,
          width: get_dimension_from_instances(instances, :width),
          height: get_dimension_from_instances(instances, :height)
        }
      end)

    {files_with_urls, total_count}
  end

  defp generate_urls_from_instances(instances, file_uuid) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      url = URLSigner.signed_url(file_uuid, instance.variant_name)
      Map.put(acc, instance.variant_name, url)
    end)
  end

  defp get_dimension_from_instances(instances, field) do
    case Enum.find(instances, &(&1.variant_name == "original")) do
      nil -> nil
      instance -> Map.get(instance, field)
    end
  end

  defp determine_file_type(mime_type) do
    cond do
      String.starts_with?(mime_type, "image/") -> "image"
      String.starts_with?(mime_type, "video/") -> "video"
      true -> "other"
    end
  end

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
