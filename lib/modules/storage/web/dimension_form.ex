defmodule PhoenixKitWeb.Live.Modules.Storage.DimensionForm do
  @moduledoc """
  One rendition on its own page: creating or editing it (its dimensions, quality
  and format). The list of renditions, and their sets, is the Renditions tab of
  Settings → Media (`RenditionsComponent`), which this page returns to.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.VariantSets
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Live.Modules.Storage.RenditionsComponent

  def mount(params, _session, socket) do
    dimension_uuid = params["id"]

    dimension_type =
      case socket.assigns[:live_action] do
        :new_image -> "image"
        :new_video -> "video"
        _ -> nil
      end

    mode = if dimension_uuid, do: :edit, else: :new
    dimension = load_dimension_data(mode, dimension_uuid)

    # The rendition set it is in: the edited rendition's own, or the one the
    # new-rendition link named (V205); the Default when none is named.
    set =
      case dimension do
        %Storage.Dimension{variant_set_uuid: uuid} -> VariantSets.get_variant_set(uuid)
        nil -> params["set"] && VariantSets.get_variant_set(params["set"])
      end || VariantSets.default_variant_set()

    # Get project title from settings
    project_title = Settings.get_project_title()

    socket =
      socket
      |> assign(:set, set)
      |> assign(:mode, mode)
      |> assign(:dimension_uuid, dimension_uuid)
      |> assign(:current_locale, "en")
      |> assign(:current_path, Routes.path("/admin/settings/media"))
      |> assign(:project_title, project_title)
      |> assign(:dimension, dimension)
      |> assign(:dimension_type, dimension_type)
      |> assign_form()

    {:ok, socket}
  end

  def handle_event("validate", %{"dimension" => dimension_params}, socket) do
    dimension_params = normalize_dimension_params(dimension_params)

    changeset =
      case socket.assigns.mode do
        :new ->
          Storage.change_dimension(%Storage.Dimension{}, dimension_params)

        :edit ->
          dimension = Storage.get_dimension(socket.assigns.dimension_uuid)
          Storage.change_dimension(dimension, dimension_params)
      end

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign_format_fields(changeset)

    {:noreply, socket}
  end

  def handle_event("save", %{"dimension" => dimension_params}, socket) do
    dimension_params = normalize_dimension_params(dimension_params)

    case socket.assigns.mode do
      :new -> create_dimension(socket, dimension_params)
      :edit -> update_dimension(socket, dimension_params)
    end
  end

  defp create_dimension(socket, dimension_params) do
    case Storage.create_dimension(dimension_params, socket.assigns.set.uuid, Actor.opts(socket)) do
      {:ok, _dimension} ->
        socket =
          socket
          |> put_flash(:info, gettext("Rendition created"))
          |> push_navigate(to: RenditionsComponent.set_path(socket.assigns.set))

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
    dimension = Storage.get_dimension(socket.assigns.dimension_uuid)

    case Storage.update_dimension(dimension, dimension_params, Actor.opts(socket)) do
      {:ok, _dimension} ->
        socket =
          socket
          |> put_flash(:info, gettext("Rendition updated"))
          |> push_navigate(to: RenditionsComponent.set_path(socket.assigns.set))

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> assign(:changeset, changeset)
          |> put_flash(:error, "Failed to update dimension")

        {:noreply, socket}
    end
  end

  defp load_dimension_data(:new, _dimension_uuid), do: nil

  defp load_dimension_data(:edit, dimension_uuid) do
    Storage.get_dimension(dimension_uuid)
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
    |> assign_format_fields(changeset)
  end

  defp assign_form(%{assigns: %{mode: :edit, dimension: dimension}} = socket) do
    changeset = Storage.change_dimension(dimension, %{})
    dimension_type = dimension.applies_to

    socket
    |> assign(:changeset, changeset)
    |> assign(:dimension_type, dimension_type)
    |> assign(:page_title, gettext("Edit rendition"))
    |> assign(:form_action, gettext("Update rendition"))
    |> assign_format_fields(changeset)
  end

  defp assign_format_fields(socket, changeset) do
    socket
    |> assign(
      :current_alternatives,
      Ecto.Changeset.get_field(changeset, :alternative_formats) || []
    )
    |> assign(:primary_format, Ecto.Changeset.get_field(changeset, :format))
  end

  defp normalize_dimension_params(params) do
    params
    |> then(fn p ->
      case p["maintain_aspect_ratio"] do
        "true" -> Map.put(p, "maintain_aspect_ratio", true)
        "false" -> Map.put(p, "maintain_aspect_ratio", false)
        _ -> p
      end
    end)
    |> then(fn p ->
      alt = p["alternative_formats"] || []
      Map.put(p, "alternative_formats", Enum.reject(alt, &(&1 == "")))
    end)
  end

  defp page_title_with_type(:new, "image"), do: gettext("Add image rendition")
  defp page_title_with_type(:new, "video"), do: gettext("Add video rendition")
  defp page_title_with_type(:new, _), do: gettext("Add rendition")

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
      %Ecto.Changeset{} ->
        Ecto.Changeset.get_field(changeset, field)

      _ ->
        nil
    end
  end

  # Helper function to render error messages
  defp render_error(changeset, field) do
    if Keyword.has_key?(changeset.errors, field) do
      errors =
        changeset.errors
        |> Keyword.get_values(field)
        |> Enum.map_join(", ", &extract_error_message/1)

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

  defp extract_error_message({message, _}), do: message
end
