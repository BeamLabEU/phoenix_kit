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
      |> assign(:last_uploaded_file_ids, [])
      |> assign(:has_buckets, has_buckets)
      |> assign(:filter_orphaned, false)
      |> assign(:orphaned_count, 0)

    {:ok, socket}
  end

  defp maybe_allow_upload(socket, has_buckets) do
    if has_buckets do
      allow_upload(socket, :media_files,
        accept: ["image/*", "video/*", "application/pdf"],
        max_entries: 10,
        max_file_size: 100_000_000,
        auto_upload: true
      )
    else
      socket
    end
  end

  def handle_params(params, _uri, socket) do
    # Pagination setup
    per_page = 50
    page = String.to_integer(params["page"] || "1")

    filter_orphaned = socket.assigns[:filter_orphaned] || false

    {existing_files, total_count} =
      if filter_orphaned do
        load_orphaned_files(page, per_page)
      else
        load_existing_files(page, per_page)
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

    {:noreply, socket}
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

    # Extract file IDs for callbacks (only from successful uploads)
    file_ids = Enum.map(uploaded_files, &get_file_id/1) |> Enum.reject(&is_nil/1)

    # Build flash message based on upload results
    {flash_type, flash_message} = build_upload_flash_message(uploaded_files)

    socket =
      socket
      |> assign(:uploaded_files, refreshed_files)
      |> assign(:total_count, total_count)
      |> assign(:total_pages, total_pages)
      |> assign(:last_uploaded_file_ids, file_ids)
      |> put_flash(flash_type, flash_message)

    {:noreply, socket}
  end

  defp get_file_id({:ok, %{file_id: file_id}}), do: file_id
  defp get_file_id({:postpone, _}), do: nil
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

  # Load orphaned files with pagination
  defp load_orphaned_files(page, per_page) do
    repo = PhoenixKit.Config.get_repo()
    offset = (page - 1) * per_page
    total_count = Storage.count_orphaned_files()

    files = Storage.find_orphaned_files(limit: per_page, offset: offset)
    file_ids = Enum.map(files, & &1.uuid)

    instances_by_file =
      if file_ids != [] do
        from(fi in FileInstance,
          where: fi.file_uuid in ^file_ids
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
          file_id: file.uuid,
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

  # Load existing files from database with pagination
  defp load_existing_files(page, per_page) do
    repo = PhoenixKit.Config.get_repo()

    # Get total count
    total_count = repo.aggregate(Storage.File, :count, :uuid)

    # Calculate offset
    offset = (page - 1) * per_page

    # Query files ordered by most recent first with pagination
    files =
      from(f in Storage.File,
        order_by: [desc: f.inserted_at],
        limit: ^per_page,
        offset: ^offset
      )
      |> repo.all()

    # Batch load ALL file instances in ONE query instead of N queries
    file_ids = Enum.map(files, & &1.uuid)

    instances_by_file =
      if file_ids != [] do
        from(fi in FileInstance,
          where: fi.file_uuid in ^file_ids
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
          file_id: file.uuid,
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
    case Storage.store_file_in_buckets(
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
        {:postpone, reason}
    end
  end

  defp build_upload_result(file, entry, file_type, mime_type, file_size, is_duplicate) do
    result = %{
      file_id: file.uuid,
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
end
