defmodule PhoenixKit.Modules.Pages.Web.Editor do
  @moduledoc """
  Full-screen editor for Pages files.

  Provides a dedicated page for editing markdown content with metadata.
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
      socket =
        socket
        |> assign(:page_title, "Edit Page")
        |> assign(:file_path, nil)
        |> assign(:file_content, "")
        |> assign(:original_content, "")
        |> assign(:has_changes, false)
        |> assign(:project_title, PhoenixKit.Settings.get_project_title())
        |> assign(:current_locale, locale)

      {:ok, socket}
    else
      socket =
        socket
        |> put_flash(:error, "Pages module is not enabled")
        |> redirect(to: Routes.path("/admin/modules"))

      {:ok, socket}
    end
  end

  def handle_params(%{"path" => path}, _uri, socket) do
    case FileOperations.read_file(path) do
      {:ok, content} ->
        # Extract current status from metadata
        current_status =
          case HtmlMetadata.parse(content) do
            {:ok, metadata, _stripped} -> metadata.status
            {:error, :no_metadata} -> "draft"
          end

        socket =
          socket
          |> assign(:file_path, path)
          |> assign(:file_content, content)
          |> assign(:original_content, content)
          |> assign(:has_changes, false)
          |> assign(:current_status, current_status)
          |> assign(:page_title, "Edit: #{Path.basename(path)}")

        # Notify JavaScript hook about initial changes status (no changes)
        {:noreply, push_event(socket, "changes-status", %{has_changes: false})}

      {:error, _reason} ->
        socket =
          socket
          |> put_flash(:error, "File not found: #{path}")
          |> redirect(to: Routes.path("/admin/pages"))

        {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    # No path provided, redirect to file list
    socket =
      socket
      |> put_flash(:error, "No file path provided")
      |> redirect(to: Routes.path("/admin/pages"))

    {:noreply, socket}
  end

  ## Event Handlers

  def handle_event("update_content", %{"value" => content}, socket) do
    has_changes = content != socket.assigns.original_content

    socket =
      socket
      |> assign(:file_content, content)
      |> assign(:has_changes, has_changes)

    # Notify JavaScript hook about changes status
    {:noreply, push_event(socket, "changes-status", %{has_changes: has_changes})}
  end

  def handle_event("save", _params, socket) do
    file_path = socket.assigns.file_path
    content = socket.assigns.file_content

    # Update metadata's updated_at timestamp
    updated_content = update_metadata_timestamp(content)

    try do
      case FileOperations.write_file(file_path, updated_content) do
        :ok ->
          socket =
            socket
            |> assign(:original_content, updated_content)
            |> assign(:file_content, updated_content)
            |> assign(:has_changes, false)
            |> put_flash(:info, "File saved: #{Path.basename(file_path)}")

          # Notify JavaScript hook that changes have been saved
          {:noreply, push_event(socket, "changes-status", %{has_changes: false})}

        {:error, _reason} ->
          socket = put_flash(socket, :error, "Failed to save file")
          {:noreply, socket}
      end
    rescue
      e ->
        require Logger
        Logger.error("Page editor save failed: #{Exception.message(e)}")
        {:noreply, put_flash(socket, :error, "Something went wrong. Please try again.")}
    end
  end

  def handle_event("attempt_cancel", _params, socket) do
    if socket.assigns.has_changes do
      # Show browser's native confirm dialog via JavaScript
      {:noreply,
       push_event(socket, "confirm-navigation", %{
         message: "You have unsaved changes. Are you sure you want to leave without saving?",
         target: "/admin/pages"
       })}
    else
      # No changes, navigate immediately
      {:noreply, redirect(socket, to: Routes.path("/admin/pages"))}
    end
  end

  def handle_event("cancel", _params, socket) do
    # User confirmed via JavaScript, navigate away
    {:noreply, redirect(socket, to: Routes.path("/admin/pages"))}
  end

  def handle_event("change_status", %{"status" => new_status}, socket) do
    content = socket.assigns.file_content
    file_path = socket.assigns.file_path

    # Update metadata with new status and timestamp
    updated_content = update_metadata_status(content, new_status)

    case FileOperations.write_file(file_path, updated_content) do
      :ok ->
        socket =
          socket
          |> assign(:file_content, updated_content)
          |> assign(:original_content, updated_content)
          |> assign(:current_status, new_status)
          |> assign(:has_changes, false)
          |> put_flash(:info, "Status changed to: #{new_status}")

        {:noreply, socket}

      {:error, _reason} ->
        socket = put_flash(socket, :error, "Failed to update status")
        {:noreply, socket}
    end
  end

  ## Private Helpers

  defp update_metadata_timestamp(content) do
    case HtmlMetadata.parse(content) do
      {:ok, metadata, _stripped_content} ->
        # Update the updated_at timestamp
        updated_metadata = Map.put(metadata, :updated_at, UtilsDate.utc_now())
        HtmlMetadata.update_metadata(content, updated_metadata)

      {:error, :no_metadata} ->
        # No metadata, return content as-is
        content
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
