defmodule PhoenixKitWeb.Live.Users.MediaDetail do
  @moduledoc """
  Single media file detail view for PhoenixKit admin panel.

  Provides a shareable view for a specific uploaded media file by file_id.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Storage.File
  alias PhoenixKit.Storage.FileInstance
  alias PhoenixKit.Storage.URLSigner
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.Date, as: UtilsDate

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Get file_id from params
    file_id = params["file_id"]

    # Batch load all settings needed for this page
    settings =
      Settings.get_settings_cached(
        ["project_title"],
        %{"project_title" => "PhoenixKit"}
      )

    socket =
      socket
      |> assign(:page_title, "Media Detail")
      |> assign(:project_title, settings["project_title"])
      |> assign(:current_locale, locale)
      |> assign(:file_id, file_id)
      |> load_file_data(file_id)

    {:ok, socket}
  end

  defp load_file_data(socket, file_id) do
    repo = Application.get_env(:phoenix_kit, :repo)
    import Ecto.Query

    case repo.get(File, file_id) do
      nil ->
        socket
        |> assign(:file, nil)
        |> assign(:file_data, nil)

      file ->
        # Load file instances for this file
        instances =
          FileInstance
          |> where([fi], fi.file_id == ^file_id)
          |> repo.all()

        # Generate URLs from instances
        urls = generate_urls_from_instances(instances, file_id)

        # Build file data map
        file_data = %{
          file_id: file.id,
          filename: file.original_file_name || file.file_name || "Unknown",
          original_filename: file.original_file_name,
          file_type: file.file_type,
          mime_type: file.mime_type,
          size: file.size || 0,
          status: file.status,
          urls: urls,
          inserted_at: file.inserted_at,
          updated_at: file.updated_at
        }

        socket
        |> assign(:file, file)
        |> assign(:file_data, file_data)
    end
  end

  # Generate URLs from pre-loaded instances (no database query needed)
  defp generate_urls_from_instances(instances, file_id) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      url = URLSigner.signed_url(file_id, instance.variant_name)
      Map.put(acc, instance.variant_name, url)
    end)
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
end
