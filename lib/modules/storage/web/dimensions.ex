defmodule PhoenixKitWeb.Live.Modules.Storage.Dimensions do
  @moduledoc """
  Storage dimensions management LiveView.

  Provides interface for managing dimension presets for automatic variant generation.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale =
      params["locale"] || socket.assigns[:current_locale]

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load all dimensions
    dimensions = Storage.list_dimensions()

    socket =
      socket
      |> assign(:current_path, Routes.path("/admin/settings/media/dimensions"))
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

  def handle_event("reset_dimensions_to_defaults", _params, socket) do
    case Storage.reset_dimensions_to_defaults() do
      {:ok, _} ->
        # Reload dimensions
        dimensions = Storage.list_dimensions()

        socket =
          socket
          |> assign(:dimensions, dimensions)
          |> put_flash(:info, "Dimensions reset to defaults successfully")

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to reset dimensions: #{inspect(reason)}")
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
end
