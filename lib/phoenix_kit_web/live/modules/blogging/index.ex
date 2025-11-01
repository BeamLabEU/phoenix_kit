defmodule PhoenixKitWeb.Live.Modules.Blogging.Index do
  @moduledoc """
  Entry point for the blogging module. Redirects to the first available blog
  or prompts the admin to configure blogs.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKitWeb.Live.Modules.Blogging
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Process.put(:phoenix_kit_current_locale, locale)

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, "Blogging")
      |> assign(:current_path, Routes.path("/admin/blogging", locale: locale))
      |> assign(:blogs, Blogging.list_blogs())

    {:ok, socket}
  end

  def handle_params(_params, _uri, %{assigns: %{blogs: []}} = socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Add a blog to get started.")
     |> push_navigate(
       to: Routes.path("/admin/settings/blogging", locale: socket.assigns.current_locale)
     )}
  end

  def handle_params(_params, _uri, %{assigns: %{blogs: [%{"slug" => slug} | _]}} = socket) do
    {:noreply,
     push_navigate(socket,
       to: Routes.path("/admin/blogging/#{slug}", locale: socket.assigns.current_locale)
     )}
  end
end
