defmodule PhoenixKitWeb.Live.Settings.Storage.DimensionForm do
  @moduledoc """
  Dimension form LiveView for storage dimension management.

  Provides form interface for creating and editing dimension presets.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Storage
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    dimension_id = params["id"]
    action = socket.assigns[:live_action]

    mode = if dimension_id, do: :edit, else: :new

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:dimension_id, dimension_id)
      |> assign(:current_locale, "en")
      |> assign(:current_path, Routes.path("/admin/settings/storage/dimensions"))
      |> assign(:project_title, project_title)
      |> assign(:dimension, load_dimension_data(mode, dimension_id))
      # Will be set in assign_form
      |> assign(:dimension_type, nil)
      |> assign_form()

    {:ok, socket}
  end

  def handle_event("validate", %{"dimension" => dimension_params}, socket) do
    changeset =
      case socket.assigns.mode do
        :new ->
          Storage.change_dimension(%Storage.Dimension{}, dimension_params)

        :edit ->
          dimension = Storage.get_dimension(socket.assigns.dimension_id)
          Storage.change_dimension(dimension, dimension_params)
      end

    socket =
      socket
      |> assign(:changeset, changeset)

    {:noreply, socket}
  end

  def handle_event("save", %{"dimension" => dimension_params}, socket) do
    case socket.assigns.mode do
      :new -> create_dimension(socket, dimension_params)
      :edit -> update_dimension(socket, dimension_params)
    end
  end

  defp create_dimension(socket, dimension_params) do
    case Storage.create_dimension(dimension_params) do
      {:ok, _dimension} ->
        socket =
          socket
          |> put_flash(:info, "Dimension created successfully")
          |> push_navigate(to: Routes.path("/admin/settings/storage/dimensions"))

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> assign(:changeset, changeset)
          |> put_flash(:error, "Failed to create dimension")

        {:noreply, socket}
    end
  end

  defp update_dimension(socket, dimension_params) do
    dimension = Storage.get_dimension(socket.assigns.dimension_id)

    case Storage.update_dimension(dimension, dimension_params) do
      {:ok, _dimension} ->
        socket =
          socket
          |> put_flash(:info, "Dimension updated successfully")
          |> push_navigate(to: Routes.path("/admin/settings/storage/dimensions"))

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> assign(:changeset, changeset)
          |> put_flash(:error, "Failed to update dimension")

        {:noreply, socket}
    end
  end

  defp load_dimension_data(:new, _dimension_id), do: nil

  defp load_dimension_data(:edit, dimension_id) do
    Storage.get_dimension(dimension_id)
  end

  defp assign_form(%{assigns: %{mode: :new, dimension_type: dimension_type}} = socket) do
    # Set applies_to based on dimension_type
    initial_attrs =
      case dimension_type do
        "image" -> %{applies_to: "image"}
        "video" -> %{applies_to: "video"}
        _ -> %{}
      end

    changeset = Storage.change_dimension(%Storage.Dimension{}, initial_attrs)

    socket
    |> assign(:changeset, changeset)
    |> assign(:page_title, page_title_with_type(:new, dimension_type))
    |> assign(:form_action, page_title_with_type(:new, dimension_type))
  end

  defp assign_form(%{assigns: %{mode: :edit, dimension: dimension}} = socket) do
    changeset = Storage.change_dimension(dimension, %{})
    dimension_type = dimension.applies_to

    socket
    |> assign(:changeset, changeset)
    |> assign(:dimension_type, dimension_type)
    |> assign(:page_title, "Edit Storage Dimension")
    |> assign(:form_action, "Update Dimension")
  end

  defp page_title(:new), do: "Add Storage Dimension"
  defp page_title(:edit), do: "Edit Storage Dimension"

  defp page_title_with_type(:new, "image"), do: "Add Image Dimension"
  defp page_title_with_type(:new, "video"), do: "Add Video Dimension"
  defp page_title_with_type(:edit, _), do: "Edit Storage Dimension"
  defp page_title_with_type(:new, _), do: "Add Storage Dimension"

  # Helper function for input validation styling
  defp input_class(changeset, field) do
    if Keyword.has_key?(changeset.errors, field) do
      "input-error"
    else
      ""
    end
  end

  # Helper function to get field value from changeset or data
  defp get_field_value(changeset, field) do
    case changeset do
      %Ecto.Changeset{changes: changes, data: data} ->
        Map.get(changes, field) || Map.get(data, field)

      _ ->
        nil
    end
  end

  # Helper function to render error messages
  defp render_error(changeset, field) do
    if Keyword.has_key?(changeset.errors, field) do
      errors =
        Keyword.get_values(changeset.errors, field) |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")

      content = """
      <p class="mt-2 flex gap-2 text-sm text-error phx-no-feedback:hidden">
        <svg class="mt-0.5 h-4 w-4 flex-none" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
        </svg>
        #{errors}
      </p>
      """

      Phoenix.HTML.raw(content)
    else
      ""
    end
  end
end
