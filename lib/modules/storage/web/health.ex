defmodule PhoenixKitWeb.Live.Modules.Storage.Health do
  @moduledoc """
  Media health check LiveView.

  Compares file instance location counts against the configured redundancy
  target and reports under-replicated files.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale]
    project_title = Settings.get_project_title()

    socket =
      socket
      |> assign(:current_path, Routes.path("/admin/settings/media/health"))
      |> assign(:page_title, gettext("Media Health"))
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:url_path, Routes.path("/admin/settings/media/health"))
      |> load_health_report()

    {:ok, socket}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_health_report(socket)}
  end

  defp load_health_report(socket) do
    redundancy_target =
      Settings.get_setting_cached("storage_redundancy_copies", "1")
      |> String.to_integer()

    report = Storage.get_health_report(redundancy_target)

    assign(socket, :report, report)
  end
end
