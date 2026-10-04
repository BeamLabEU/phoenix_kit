defmodule PhoenixKitWeb.Live.Modules.Storage.Dimensions do
  @moduledoc """
  Variant sets and their sizes (V205).

  One tab per variant set (`?set=<uuid>`; none is the Default). A set says
  which derived files a library's uploads get: its sizes (dimensions), and
  whether sizes and zoomable tiles are made automatically. The standard
  sizes are listed first and cannot be deleted. A new set starts with a copy
  of the Default's standard sizes. Changing a set or a size bumps the set's
  revision and the reconciler brings its files up to date; "Check every
  file" does that without a change (a size a file never got is made).
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Dimension, VariantSet, VariantSets}
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale]

    socket =
      socket
      |> assign(:current_path, Routes.path("/admin/settings/media/dimensions"))
      |> assign(:page_title, gettext("Variant sets"))
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:current_locale, locale)
      |> assign(:new_set_form, to_form(%{"name" => ""}, as: :new_set))

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    set = (params["set"] && VariantSets.get_variant_set(params["set"])) || default_set()
    {:noreply, load_set(socket, set)}
  end

  defp default_set, do: VariantSets.default_variant_set()

  defp load_set(socket, %VariantSet{} = set) do
    socket
    |> assign(:sets, VariantSets.list_variant_sets())
    |> assign(:set, set)
    |> assign(:set_libraries, VariantSets.libraries_using(set.uuid))
    |> assign(:missing_slots, VariantSets.missing_standard_slots(set.uuid))
    |> assign(:set_form, to_form(VariantSet.changeset(set, %{})))
    |> assign(:dimensions, pinned(Storage.list_dimensions(set.uuid)))
  end

  # The standard sizes first, each group in its size order.
  defp pinned(dimensions) do
    {standard, custom} = Enum.split_with(dimensions, &Dimension.standard_slot?/1)
    standard ++ custom
  end

  defp reload(socket), do: load_set(socket, VariantSets.get_variant_set(socket.assigns.set.uuid))

  def handle_event("delete_dimension", %{"id" => id}, socket) do
    dimension = Storage.get_dimension(id)

    case Storage.delete_dimension(dimension, Actor.opts(socket)) do
      {:ok, _} ->
        {:noreply,
         socket |> reload() |> put_flash(:info, gettext("Dimension deleted successfully"))}

      {:error, :standard_slot} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("%{name} is a standard size every variant set has; it cannot be deleted",
             name: dimension.name
           )
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete dimension"))}
    end
  end

  def handle_event("toggle_dimension", %{"id" => id}, socket) do
    dimension = Storage.get_dimension(id)

    case Storage.update_dimension(dimension, %{enabled: !dimension.enabled}, Actor.opts(socket)) do
      {:ok, _dimension} ->
        {:noreply, socket |> reload() |> put_flash(:info, gettext("Dimension status updated"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update dimension"))}
    end
  end

  def handle_event("reset_dimensions_to_defaults", _params, socket) do
    case Storage.reset_dimensions_to_defaults(Actor.opts(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(:info, gettext("Dimensions reset to defaults successfully"))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to reset dimensions: %{reason}", reason: inspect(reason))
         )}
    end
  end

  def handle_event("create_set", %{"new_set" => %{"name" => name}}, socket) do
    case VariantSets.create_variant_set(%{name: name}, Actor.opts(socket)) do
      {:ok, set} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Variant set created"))
         |> push_patch(to: set_path(set))}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, first_error(changeset))}
    end
  end

  def handle_event("save_set", %{"variant_set" => params}, socket) do
    case VariantSets.update_variant_set(socket.assigns.set, params, Actor.opts(socket)) do
      {:ok, _set} ->
        {:noreply, socket |> reload() |> put_flash(:info, gettext("Variant set saved"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :set_form, to_form(changeset))}
    end
  end

  def handle_event("delete_set", _params, socket) do
    case VariantSets.delete_variant_set(socket.assigns.set, Actor.opts(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Variant set deleted"))
         |> push_patch(to: set_path(default_set()))}

      {:error, :in_use} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("A library uses this variant set; it cannot be deleted")
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("This variant set cannot be deleted"))}
    end
  end

  def handle_event("check_set", _params, socket) do
    case VariantSets.check_files(socket.assigns.set, Actor.opts(socket)) do
      :ok ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(
           :info,
           gettext("Every file of this variant set will be checked, and missing sizes made.")
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save"))}
    end
  end

  defp first_error(%Ecto.Changeset{errors: [{field, {message, _}} | _]}),
    do: "#{Phoenix.Naming.humanize(field)} #{message}"

  defp first_error(_changeset), do: gettext("Could not save")

  @doc false
  # This page for `set`: the bare path for the Default.
  def set_path(%VariantSet{is_default: true}), do: Routes.path("/admin/settings/media/dimensions")

  def set_path(%VariantSet{uuid: uuid}),
    do: Routes.path("/admin/settings/media/dimensions?set=#{uuid}")

  @doc false
  # A new-size form for `set` (`kind` is "image" or "video").
  def new_dimension_path(%VariantSet{is_default: true}, kind),
    do: Routes.path("/admin/settings/media/dimensions/new/#{kind}")

  def new_dimension_path(%VariantSet{uuid: uuid}, kind),
    do: Routes.path("/admin/settings/media/dimensions/new/#{kind}?set=#{uuid}")

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
