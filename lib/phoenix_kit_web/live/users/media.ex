defmodule PhoenixKitWeb.Live.Users.Media do
  @moduledoc """
  Media management LiveView for PhoenixKit admin panel.

  Provides interface for viewing and managing user media.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Storage.URLSigner
  alias PhoenixKit.Storage.FileInstance

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load existing files from database
    existing_files = load_existing_files()

    socket =
      socket
      |> allow_upload(:media_files,
        accept: ["image/*", "video/*", "application/pdf"],
        max_entries: 10,
        max_file_size: 100_000_000,
        auto_upload: false
      )
      |> assign(:page_title, "Media")
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:url_path, Routes.path("/admin/users/media"))
      |> assign(:uploaded_files, existing_files)
      |> assign(:show_image_modal, false)
      |> assign(:selected_file, nil)

    {:ok, socket}
  end

  def handle_event("validate", _params, socket) do
    # File validation event - called when files are selected
    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media_files, ref)}
  end

  def handle_event("upload", _params, socket) do
    # Process uploaded files when user clicks upload button
    process_uploads(socket)
  end

  def handle_event("show_image_modal", %{"file_id" => file_id}, socket) do
    # Find the file in uploaded_files by file_id
    selected_file = Enum.find(socket.assigns.uploaded_files, &(&1.file_id == file_id))

    socket =
      socket
      |> assign(:selected_file, selected_file)
      |> assign(:show_image_modal, true)

    {:noreply, socket}
  end

  def handle_event("hide_image_modal", _params, socket) do
    socket =
      socket
      |> assign(:selected_file, nil)
      |> assign(:show_image_modal, false)

    {:noreply, socket}
  end

  defp process_uploads(socket) do
    # Process uploaded files
    uploaded_files =
      consume_uploaded_entries(socket, :media_files, fn %{path: path}, entry ->
        # Get file info
        ext = Path.extname(entry.client_name) |> String.replace_leading(".", "")
        mime_type = entry.client_type || MIME.from_path(entry.client_name)
        file_type = determine_file_type(mime_type)

        # Get current user
        current_user = socket.assigns.phoenix_kit_current_user
        user_id = if current_user, do: current_user.id, else: 1

        # Get file size
        {:ok, stat} = File.stat(path)
        file_size = stat.size

        # Calculate hash
        file_hash = calculate_file_hash(path)

        # Store file in storage
        case PhoenixKit.Storage.store_file_in_buckets(path, file_type, user_id, file_hash, ext) do
          {:ok, file} ->
            # Queue background job for processing
            _job =
              %{file_id: file.id, user_id: user_id, filename: entry.client_name}
              |> PhoenixKit.Storage.Workers.ProcessFileJob.new()
              |> Oban.insert()

            # Generate URLs for available variants (start with original)
            urls = generate_file_urls(file.id)

            {:ok,
             %{
               file_id: file.id,
               filename: entry.client_name,
               file_type: file_type,
               mime_type: mime_type,
               size: file_size,
               status: file.status,
               urls: urls
             }}

          {:error, reason} ->
            IO.inspect(reason, label: "Storage Error")
            {:error, reason}
        end
      end)

    socket =
      socket
      |> assign(:uploaded_files, (socket.assigns.uploaded_files || []) ++ uploaded_files)
      |> put_flash(:info, "Upload successful! #{length(uploaded_files)} file(s) processed")

    {:noreply, socket}
  end

  defp generate_file_urls(file_id) do
    # Query all file instances for this file
    import Ecto.Query

    repo = Application.get_env(:phoenix_kit, :repo)

    instances =
      FileInstance
      |> where([fi], fi.file_id == ^file_id)
      |> repo.all()

    # Generate signed URLs for each instance
    Enum.reduce(instances, %{}, fn instance, acc ->
      url = URLSigner.signed_url(file_id, instance.variant_name)
      Map.put(acc, instance.variant_name, url)
    end)
  end

  defp calculate_file_hash(file_path) do
    file_path
    |> File.read!()
    |> then(fn data -> :crypto.hash(:sha256, data) end)
    |> Base.encode16(case: :lower)
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

  # Get badge color for file type
  defp file_type_badge("image"), do: "badge-info"
  defp file_type_badge("video"), do: "badge-warning"
  defp file_type_badge("pdf"), do: "badge-error"
  defp file_type_badge(_), do: "badge-ghost"

  # Get badge color for status
  defp status_badge("active"), do: "badge-success"
  defp status_badge("processing"), do: "badge-info"
  defp status_badge("failed"), do: "badge-error"
  defp status_badge(_), do: "badge-warning"

  # Get icon for file type
  defp file_icon("image"), do: "hero-photo"
  defp file_icon("video"), do: "hero-play-circle"
  defp file_icon("pdf"), do: "hero-document-text"
  defp file_icon("document"), do: "hero-document"
  defp file_icon(_), do: "hero-document-arrow-down"

  # Load existing files from database
  defp load_existing_files do
    import Ecto.Query

    repo = Application.get_env(:phoenix_kit, :repo)

    # Query files ordered by most recent first
    files =
      from(f in PhoenixKit.Storage.File,
        order_by: [desc: f.inserted_at],
        limit: 50
      )
      |> repo.all()

    # Convert to same format as uploaded files
    Enum.map(files, fn file ->
      # Generate URLs for all variants
      urls = generate_file_urls(file.id)

      %{
        file_id: file.id,
        filename: file.original_file_name || "Unknown",
        file_type: file.file_type,
        mime_type: file.mime_type,
        size: file.size || 0,
        status: file.status,
        urls: urls
      }
    end)
  end
end
