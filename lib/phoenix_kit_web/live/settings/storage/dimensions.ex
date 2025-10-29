defmodule PhoenixKitWeb.Live.Settings.Storage.Dimensions do
  @moduledoc """
  Storage dimensions management LiveView.

  Provides interface for managing dimension presets for automatic variant generation.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Storage
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load all dimensions
    dimensions = Storage.list_dimensions()

    socket =
      socket
      |> assign(:current_path, Routes.path("/admin/settings/storage/dimensions"))
      |> assign(:page_title, "Storage Dimensions")
      |> assign(:project_title, project_title)
      |> assign(:dimensions, dimensions)
      |> assign(:current_locale, locale)

    {:ok, socket}
  end

  def handle_event("delete_dimension", %{"id" => id}, socket) do
    require Logger
    Logger.info("Dimensions: delete_dimension event triggered for id=#{id}")

    dimension = Storage.get_dimension(id)

    case Storage.delete_dimension(dimension) do
      {:ok, _} ->
        # Reload dimensions
        dimensions = Storage.list_dimensions()

        socket =
          socket
          |> assign(:dimensions, dimensions)
          |> put_flash(:info, "Dimension deleted successfully")

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to delete dimension")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_dimension", %{"id" => id}, socket) do
    require Logger
    Logger.info("Dimensions: toggle_dimension event triggered for id=#{id}")

    dimension = Storage.get_dimension(id)

    case Storage.update_dimension(dimension, %{enabled: !dimension.enabled}) do
      {:ok, _dimension} ->
        # Reload dimensions
        dimensions = Storage.list_dimensions()

        socket =
          socket
          |> assign(:dimensions, dimensions)
          |> put_flash(:info, "Dimension status updated")

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update dimension")
        {:noreply, socket}
    end
  end

  defp format_dimension_size(width, height) when is_integer(width) and is_integer(height) do
    "#{width}×#{height}"
  end

  defp format_dimension_size(width, nil) when is_integer(width) do
    "#{width}px wide"
  end

  defp format_dimension_size(nil, height) when is_integer(height) do
    "#{height}px tall"
  end

  defp format_dimension_size(_, _), do: "Auto"

  defp applies_to_badge("image"), do: "badge-info"
  defp applies_to_badge("video"), do: "badge-warning"
  defp applies_to_badge("both"), do: "badge-success"
  defp applies_to_badge(_), do: "badge-neutral"

  defp applies_to_text("image"), do: "Images"
  defp applies_to_text("video"), do: "Videos"
  defp applies_to_text("both"), do: "Both"
  defp applies_to_text(_), do: "Unknown"
end
