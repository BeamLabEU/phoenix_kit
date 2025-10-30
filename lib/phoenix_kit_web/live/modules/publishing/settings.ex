defmodule PhoenixKitWeb.Live.Modules.Publishing.Settings do
  @moduledoc """
  Admin configuration for publishing content types.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitWeb.Live.Modules.Publishing
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, gettext("Manage Types"))
      |> assign(:current_path, Routes.path("/admin/settings/publishing", locale: locale))
      |> assign(:module_enabled, Publishing.enabled?())
      |> assign(:types, Publishing.list_types())
      |> assign(:new_type, "")

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("update_new_type", %{"new_type" => value} = _params, socket) do
    {:noreply, assign(socket, :new_type, value)}
  end

  def handle_event("update_new_type", %{"value" => value}, socket) do
    {:noreply, assign(socket, :new_type, value)}
  end

  def handle_event("add_type", _params, socket) do
    case Publishing.add_type(socket.assigns.new_type) do
      {:ok, _type} ->
        {:noreply,
         socket
         |> assign(:types, Publishing.list_types())
         |> assign(:new_type, "")
         |> put_flash(:info, gettext("Publishing type added"))}

      {:error, :already_exists} ->
        {:noreply, put_flash(socket, :error, gettext("That publishing type already exists"))}

      {:error, :invalid_name} ->
        {:noreply, put_flash(socket, :error, gettext("Please enter a valid type name"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to add publishing type"))}
    end
  end

  def handle_event("remove_type", %{"slug" => slug}, socket) do
    case Publishing.remove_type(slug) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:types, Publishing.list_types())
         |> put_flash(:info, gettext("Publishing type removed"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove publishing type"))}
    end
  end
end
