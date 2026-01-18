defmodule PhoenixKitWeb.Live.Settings.SEO do
  @moduledoc """
  SEO settings management LiveView for PhoenixKit.

  Provides a simple interface for global indexing directives (noindex/nofollow)
  to keep staging or development deployments out of search engines.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.SEO
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(_params, _session, socket) do
    # Attach locale hook for automatic locale handling

    if SEO.module_enabled?() do
      project_title = Settings.get_project_title()
      config = SEO.get_config()

      socket =
        socket
        |> assign(:page_title, "SEO Settings")
        |> assign(:project_title, project_title)
        |> assign(:current_path, get_current_path(socket.assigns.current_locale_base))
        |> assign(:no_index_enabled, config.no_index_enabled)

      {:ok, socket}
    else
      socket =
        socket
        |> put_flash(
          :error,
          gettext(
            "SEO module is disabled. Enable it from the Modules page to configure settings."
          )
        )
        |> redirect(to: Routes.path("/admin/modules", locale: socket.assigns.current_locale_base))

      {:ok, socket}
    end
  end

  def handle_event("toggle_no_index", _params, socket) do
    new_value = !socket.assigns.no_index_enabled

    result =
      if new_value do
        SEO.enable_no_index()
      else
        SEO.disable_no_index()
      end

    case result do
      {:ok, _setting} ->
        message =
          if new_value do
            gettext("Noindex/nofollow enabled. Search engines will not index this site.")
          else
            gettext("Noindex/nofollow disabled. Site can be indexed again.")
          end

        socket =
          socket
          |> assign(:no_index_enabled, new_value)
          |> put_flash(:info, message)

        {:noreply, socket}

      {:error, _changeset} ->
        socket =
          socket
          |> put_flash(:error, gettext("Failed to update SEO settings"))

        {:noreply, socket}
    end
  end

  defp get_current_path(locale) do
    Routes.path("/admin/settings/seo", locale: locale)
  end
end
