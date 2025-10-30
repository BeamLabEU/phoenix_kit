defmodule PhoenixKitWeb.Live.Modules.Publishing.Index do
  @moduledoc """
  Entry point for the publishing module. Redirects to the first available type
  or prompts the admin to configure types.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKitWeb.Live.Modules.Publishing
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Process.put(:phoenix_kit_current_locale, locale)

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, "Publishing")
      |> assign(:current_path, Routes.path("/admin/publishing", locale: locale))
      |> assign(:types, Publishing.list_types())

    {:ok, socket}
  end

  def handle_params(_params, _uri, %{assigns: %{types: []}} = socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Add a publishing type to get started.")
     |> push_navigate(
       to: Routes.path("/admin/settings/publishing", locale: socket.assigns.current_locale)
     )}
  end

  def handle_params(_params, _uri, %{assigns: %{types: [%{"slug" => slug} | _]}} = socket) do
    {:noreply,
     push_navigate(socket,
       to: Routes.path("/admin/publishing/#{slug}", locale: socket.assigns.current_locale)
     )}
  end
end
