defmodule PhoenixKitWeb.Live.Activity.Show do
  @moduledoc """
  Admin LiveView for viewing a single activity entry.

  Provides a shareable URL for individual activity entries with full detail.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Activity
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.has_module_access?(scope, "dashboard") do
      case Activity.get_entry(uuid) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "Activity not found")
           |> push_navigate(to: Routes.path("/admin/activity"))}

        entry ->
          project_title = Settings.get_project_title()
          resource_user = resolve_resource_user(entry)

          socket =
            socket
            |> assign(:page_title, "Activity Detail")
            |> assign(:project_title, project_title)
            |> assign(:entry, entry)
            |> assign(:resource_user, resource_user)

          {:ok, socket}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Access denied")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(_params, url, socket) do
    {:noreply, assign(socket, :url_path, URI.parse(url).path)}
  end

  defp resolve_resource_user(entry) do
    if entry.resource_type == "user" && entry.resource_uuid do
      resource_users = Activity.resolve_resource_users([entry])
      Map.get(resource_users, entry.resource_uuid)
    else
      nil
    end
  end

  defp mode_badge_color(mode), do: Activity.mode_badge_color(mode)
  defp action_badge_color(action), do: Activity.action_badge_color(action)
end
