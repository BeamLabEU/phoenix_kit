defmodule PhoenixKitWeb.Live.Modules.Connections.Connections do
  @moduledoc """
  Admin LiveView for the Connections module.

  Provides an overview of all social relationships in the system,
  statistics, and moderation capabilities.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Connections
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns[:phoenix_kit_current_user]

    if can_access?(current_user) do
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      socket =
        socket
        |> assign(:page_title, "Connections")
        |> assign(:project_title, project_title)
        |> assign(:current_user, current_user)
        |> load_stats()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Access denied")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, :url_path, URI.parse(uri).path)}
  end

  @impl true
  def handle_event("toggle_enabled", _params, socket) do
    new_value = !socket.assigns.enabled

    result =
      if new_value do
        Connections.enable_system()
      else
        Connections.disable_system()
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           if(new_value, do: "Connections enabled", else: "Connections disabled")
         )
         |> assign(:enabled, new_value)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update setting")}
    end
  end

  defp can_access?(nil), do: false

  defp can_access?(user) do
    Roles.user_has_role_owner?(user) or Roles.user_has_role_admin?(user)
  end

  defp load_stats(socket) do
    socket
    |> assign(:enabled, Connections.enabled?())
    |> assign(:stats, Connections.get_stats())
  end
end
