defmodule PhoenixKitWeb.Live.Users.MediaDetail do
  @moduledoc """
  Single media file detail view for PhoenixKit admin panel.

  Provides a shareable view for a specific uploaded media file by file_id.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Storage
  alias PhoenixKit.Storage.File
  alias PhoenixKit.Storage.FileInstance
  alias PhoenixKit.Storage.FileLocation
  alias PhoenixKit.Storage.URLSigner
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

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

  def handle_event("toggle_edit", _params, socket) do
    {:noreply, assign(socket, :edit_mode, !socket.assigns.edit_mode)}
  end

  def handle_event("save_metadata", params, socket) do
    %{"title" => title, "description" => description, "tags" => tags_input} = params

    # Parse tags from comma-separated string
    tags =
      tags_input
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(String.length(&1) > 0))

    # Update metadata
    updated_metadata =
      (socket.assigns.file.metadata || %{})
      |> Map.put("title", title)
      |> Map.put("description", description)
      |> Map.put("tags", tags)

    case Storage.update_file(socket.assigns.file, %{metadata: updated_metadata}) do
      {:ok, updated_file} ->
        # Update file_data with new metadata
        updated_file_data =
          socket.assigns.file_data
          |> Map.put(:title, title)
          |> Map.put(:description, description)
          |> Map.put(:tags, tags)
          |> Map.put(:metadata, updated_metadata)

        socket =
          socket
          |> assign(:file, updated_file)
          |> assign(:file_data, updated_file_data)
          |> assign(:edit_mode, false)
          |> put_flash(:info, "Metadata saved successfully!")

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to save metadata")
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :edit_mode, false)}
  end

  defp load_file_data(socket, file_id) do
    repo = Application.get_env(:phoenix_kit, :repo)

    case repo.get(File, file_id) do
      nil ->
        socket
        |> assign(:file, nil)
        |> assign(:file_data, nil)

      file ->
        instances = load_file_instances(file_id, repo)
        urls = generate_urls_from_instances(instances, file_id)
        locations = load_original_locations(instances, repo)
        {title, description, tags} = extract_metadata_fields(file.metadata)
        user_name = get_user_name(file.user_id, repo)

        file_data =
          build_file_data(file, urls, locations, {title, description, tags}, user_name)

        socket
        |> assign(:file, file)
        |> assign(:file_data, file_data)
        |> assign(:edit_mode, false)
    end
  end

  defp load_file_instances(file_id, repo) do
    import Ecto.Query

    FileInstance
    |> where([fi], fi.file_id == ^file_id)
    |> repo.all()
  end

  defp load_original_locations(instances, repo) do
    case Enum.find(instances, &(&1.variant_name == "original")) do
      nil -> []
      original_instance -> load_file_locations(original_instance.id, repo)
    end
  end

  defp extract_metadata_fields(metadata) do
    metadata = metadata || %{}
    title = metadata["title"] || ""
    description = metadata["description"] || ""
    tags = metadata["tags"] || []
    {title, description, tags}
  end

  defp get_user_name(nil, _repo), do: "Unknown"

  defp get_user_name(user_id, repo) do
    alias_module = Application.get_env(:phoenix_kit, :users_module, PhoenixKit.Users.Auth.User)

    case repo.get(alias_module, user_id) do
      nil -> "Unknown"
      user -> user.email
    end
  end

  defp build_file_data(file, urls, locations, {title, description, tags}, user_name) do
    %{
      file_id: file.id,
      filename: file.original_file_name || file.file_name || "Unknown",
      original_filename: file.original_file_name,
      file_type: file.file_type,
      mime_type: file.mime_type,
      size: file.size || 0,
      status: file.status,
      urls: urls,
      title: title,
      description: description,
      tags: tags,
      metadata: file.metadata || %{},
      inserted_at: file.inserted_at,
      updated_at: file.updated_at,
      locations: locations,
      user_name: user_name
    }
  end

  # Generate URLs from pre-loaded instances (no database query needed)
  defp generate_urls_from_instances(instances, file_id) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      url = URLSigner.signed_url(file_id, instance.variant_name)
      Map.put(acc, instance.variant_name, url)
    end)
  end

  # Load file locations with bucket information
  defp load_file_locations(file_instance_id, repo) do
    import Ecto.Query

    FileLocation
    |> where([fl], fl.file_instance_id == ^file_instance_id and fl.status == "active")
    |> preload(:bucket)
    |> repo.all()
    |> Enum.map(fn location ->
      %{
        bucket_name: location.bucket.name,
        bucket_provider: location.bucket.provider,
        path: location.path
      }
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
