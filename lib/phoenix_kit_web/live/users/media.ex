defmodule PhoenixKitWeb.Live.Users.Media do
  @moduledoc """
  Media management LiveView for PhoenixKit admin panel.

  Provides interface for viewing and managing user media.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    socket =
      socket
      |> assign(:page_title, "Media")
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:url_path, Routes.path("/admin/users/media"))

    {:ok, socket}
  end
end
