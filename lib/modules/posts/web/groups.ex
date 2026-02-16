defmodule PhoenixKitWeb.Live.Modules.Posts.Groups do
  @moduledoc """
  LiveView for managing user's post groups (collections).

  Groups are user-specific collections for organizing posts (Pinterest-style).
  Each user can create groups with unique slugs within their own collection.

  ## Features

  - **Group Management**: Create, view, edit, delete groups
  - **Post Organization**: See post count for each group
  - **Search & Filter**: Find groups by name or description
  - **Privacy Control**: Public/private group settings
  - **Slug Management**: URL-friendly unique identifiers

  ## Route

  This LiveView is mounted at `{prefix}/admin/posts/groups` and requires
  appropriate permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Modules.Posts
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    # Get current user
    current_user = socket.assigns[:phoenix_kit_current_user]

    # Get project title
    project_title = Settings.get_project_title()

    # Check if groups are enabled
    allow_groups = Settings.get_setting("posts_allow_groups", "true") == "true"

    if allow_groups do
      socket =
        socket
        |> assign(:page_title, "Post Groups")
        |> assign(:project_title, project_title)
        |> assign(:current_user, current_user)
        |> assign(:groups, [])
        |> assign(:search_query, "")
        |> assign(:loading, true)
        |> load_groups()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Groups feature is not enabled")
       |> push_navigate(to: Routes.path("/admin/posts"))}
    end
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> load_groups()}
  end

  @impl true
  def handle_event("clear_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> load_groups()}
  end

  @impl true
  def handle_event("view_group", %{"id" => group_id}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/posts/groups/#{group_id}"))}
  end

  @impl true
  def handle_event("edit_group", %{"id" => group_id}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/posts/groups/#{group_id}/edit"))}
  end

  @impl true
  def handle_event("delete_group", %{"id" => group_id}, socket) do
    case Posts.get_group(group_id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "Group not found")}

      group ->
        # Verify user owns this group
        if group.user_id == socket.assigns.current_user.id do
          case Posts.delete_group(group) do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, "Group deleted successfully")
               |> load_groups()}

            {:error, _} ->
              {:noreply, socket |> put_flash(:error, "Failed to delete group")}
          end
        else
          {:noreply,
           socket |> put_flash(:error, "You don't have permission to delete this group")}
        end
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_groups()
     |> put_flash(:info, "Groups refreshed")}
  end

  ## --- Private Helper Functions ---

  defp load_groups(socket) do
    opts = [
      user_id: socket.assigns.current_user.uuid,
      preload: [:posts]
    ]

    # Add search filter if query is present
    opts =
      if socket.assigns.search_query != "" do
        Keyword.put(opts, :search, socket.assigns.search_query)
      else
        opts
      end

    groups = Posts.list_user_groups(socket.assigns.current_user.uuid, opts)

    socket
    |> assign(:groups, groups)
    |> assign(:loading, false)
  end

  defp format_visibility("public"), do: "Public"
  defp format_visibility("private"), do: "Private"
  defp format_visibility(_), do: "Unknown"

  defp visibility_badge_class("public"), do: "badge-success"
  defp visibility_badge_class("private"), do: "badge-warning"
  defp visibility_badge_class(_), do: "badge-ghost"
end
