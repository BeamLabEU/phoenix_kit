defmodule PhoenixKitWeb.Live.Users.Media do
  @moduledoc """
  Media management LiveView for PhoenixKit admin panel.

  Provides interface for viewing and managing user media.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import Ecto.Query

  alias PhoenixKit.Settings
  alias PhoenixKit.Storage.FileInstance
  alias PhoenixKit.Storage.URLSigner
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Batch load all settings needed for this page (uses cached settings for performance)
    settings =
      Settings.get_settings_cached(
        ["project_title"],
        %{"project_title" => "PhoenixKit"}
      )

    socket =
      socket
      |> allow_upload(:media_files,
        accept: ["image/*", "video/*", "application/pdf"],
        max_entries: 10,
        max_file_size: 100_000_000,
        auto_upload: true
      )
      |> assign(:page_title, "Media")
      |> assign(:project_title, settings["project_title"])
      |> assign(:current_locale, locale)
      |> assign(:url_path, Routes.path("/admin/users/media"))
      |> assign(:show_upload, false)
      |> assign(:last_uploaded_file_ids, [])

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    # Pagination setup
    per_page = 50
    page = String.to_integer(params["page"] || "1")

    # Load existing files from database with pagination
    {existing_files, total_count} = load_existing_files(page, per_page)
    total_pages = ceil(total_count / per_page)

    socket =
      socket
      |> assign(:uploaded_files, existing_files)
      |> assign(:current_page, page)
      |> assign(:per_page, per_page)
      |> assign(:total_pages, total_pages)
      |> assign(:total_count, total_count)

    {:noreply, socket}
  end

  def handle_event("toggle_upload", _params, socket) do
    {:noreply, assign(socket, :show_upload, !socket.assigns.show_upload)}
  end

  def handle_event("validate", _params, socket) do
    # File selection event - files will auto-upload
    entries = socket.assigns.uploads.media_files.entries
    Logger.info("validate event: entries=#{length(entries)}")

    if entries != [] do
      Logger.info("validate: scheduling check_uploads_complete")
      Process.send_after(self(), :check_uploads_complete, 500)
    end

    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media_files, ref)}
  end

  def handle_info({:file_uploaded, file_id}, socket) do
    # This event can be used by other modules listening to uploaded files
    # For example, avatar upload systems can listen for this event
    Logger.info("File uploaded with ID: #{file_id}")
    {:noreply, socket}
  end

  def handle_info(:check_uploads_complete, socket) do
    entries = socket.assigns.uploads.media_files.entries

    Logger.info(
      "check_uploads_complete: entries=#{length(entries)}, done?=#{inspect(Enum.map(entries, & &1.done?))}"
    )

    # Check if all entries are done uploading
    if entries != [] && Enum.all?(entries, & &1.done?) do
      Logger.info("All uploads done! Processing...")
      # All done - process them
      process_uploads(socket)
    else
      # Still uploading - check again later
      Logger.info("Still uploading, checking again...")
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

    # Extract file IDs for callbacks
    file_ids = Enum.map(uploaded_files, &get_file_id/1)

    # Build flash message based on upload results
    flash_message = build_upload_flash_message(uploaded_files)

    socket =
      socket
      |> assign(:uploaded_files, refreshed_files)
      |> assign(:total_count, total_count)
      |> assign(:total_pages, total_pages)
      |> assign(:last_uploaded_file_ids, file_ids)
      |> put_flash(:info, flash_message)

    {:noreply, socket}
  end

  defp get_file_id({:ok, %{file_id: file_id}}), do: file_id
  defp get_file_id(_), do: nil

  # Generate URLs from pre-loaded instances (no database query needed)
  defp generate_urls_from_instances(instances, file_id) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      url = URLSigner.signed_url(file_id, instance.variant_name)
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

  # Load existing files from database with pagination
  defp load_existing_files(page, per_page) do
    repo = PhoenixKit.Config.get_repo()

    # Get total count
    total_count = repo.aggregate(PhoenixKit.Storage.File, :count, :id)

    # Calculate offset
    offset = (page - 1) * per_page

    # Query files ordered by most recent first with pagination
    files =
      from(f in PhoenixKit.Storage.File,
        order_by: [desc: f.inserted_at],
        limit: ^per_page,
        offset: ^offset
      )
      |> repo.all()

    # Batch load ALL file instances in ONE query instead of N queries
    file_ids = Enum.map(files, & &1.id)

    instances_by_file =
      if file_ids != [] do
        from(fi in FileInstance,
          where: fi.file_id in ^file_ids
        )
        |> repo.all()
        |> Enum.group_by(& &1.file_id)
      else
        %{}
      end

    # Convert to same format as uploaded files
    existing_files =
      Enum.map(files, fn file ->
        # Get pre-loaded instances for this file (no DB query!)
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
    user_id = if current_user, do: current_user.id, else: 1

    # Get file size
    {:ok, stat} = Elixir.File.stat(path)
    file_size = stat.size

    # Calculate hash
    file_hash = Auth.calculate_file_hash(path)

    # Store file in storage
    case PhoenixKit.Storage.store_file_in_buckets(
           path,
           file_type,
           user_id,
           file_hash,
           ext,
           entry.client_name
         ) do
      {:ok, file, :duplicate} ->
        build_upload_result(file, entry, file_type, mime_type, file_size, true)

      {:ok, file} ->
        build_upload_result(file, entry, file_type, mime_type, file_size, false)

      {:error, reason} ->
        Logger.error("Storage Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_upload_result(file, entry, file_type, mime_type, file_size, is_duplicate) do
    result = %{
      file_id: file.id,
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
    duplicate_count =
      Enum.count(uploaded_files, fn
        %{duplicate: true} -> true
        _ -> false
      end)

    new_count = length(uploaded_files) - duplicate_count

    case {new_count, duplicate_count} do
      {0, n} when n > 0 ->
        "Already have #{n} duplicate file(s). No new files were added."

      {n, 0} when n > 0 ->
        "Upload successful! #{n} new file(s) processed"

      {n, d} when n > 0 and d > 0 ->
        "Upload successful! #{n} new file(s) added. #{d} file(s) were already uploaded."

      _ ->
        "Upload processed"
    end
  end
end
