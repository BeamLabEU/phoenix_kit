defmodule PhoenixKitWeb.Live.Modules.Connections.UserConnections do
  @moduledoc """
  User-facing LiveView for managing personal connections.

  Provides tabs for:
  - Followers - Users who follow the current user
  - Following - Users the current user follows
  - Connections - Mutual connections
  - Requests - Pending incoming/outgoing connection requests
  - Blocked - Users blocked by the current user
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Connections
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @tabs ~w(followers following connections requests blocked)
  @default_tab "connections"

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns[:phoenix_kit_current_user]

    if current_user && Connections.enabled?() do
      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:page_title, "My Connections")
        |> assign(:project_title, project_title)
        |> assign(:current_user, current_user)
        |> assign(:tab, @default_tab)
        |> load_counts()
        |> load_tab_data(@default_tab)

      {:ok, socket}
    else
      message = if current_user, do: "Connections module is disabled", else: "Please log in"

      {:ok,
       socket
       |> put_flash(:error, message)
       |> push_navigate(to: Routes.path("/"))}
    end
  end

  @impl true
  def handle_params(%{"tab" => tab}, uri, socket) when tab in @tabs do
    socket =
      socket
      |> assign(:url_path, URI.parse(uri).path)
      |> assign(:tab, tab)
      |> load_tab_data(tab)

    {:noreply, socket}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply,
     socket
     |> assign(:url_path, URI.parse(uri).path)
     |> assign(:tab, @default_tab)
     |> load_tab_data(@default_tab)}
  end

  @impl true
  def handle_event("unfollow", %{"uuid" => user_uuid}, socket) do
    case Connections.unfollow(socket.assigns.current_user, user_uuid) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Unfollowed successfully")
         |> load_counts()
         |> load_tab_data(socket.assigns.tab)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unfollow")}
    end
  end

  @impl true
  def handle_event("remove_follower", %{"uuid" => _user_uuid}, socket) do
    # Remove follower by having them unfollow us (via block/unblock or admin action)
    # For now, we just show a message - actual follower removal would need admin rights
    {:noreply, put_flash(socket, :info, "Follower removal requires blocking the user")}
  end

  @impl true
  def handle_event("accept_request", %{"id" => connection_id}, socket) do
    case Connections.accept_connection(connection_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Connection accepted!")
         |> load_counts()
         |> load_tab_data(socket.assigns.tab)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to accept request")}
    end
  end

  @impl true
  def handle_event("reject_request", %{"id" => connection_id}, socket) do
    case Connections.reject_connection(connection_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Connection rejected")
         |> load_counts()
         |> load_tab_data(socket.assigns.tab)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to reject request")}
    end
  end

  @impl true
  def handle_event("remove_connection", %{"uuid" => user_uuid}, socket) do
    case Connections.remove_connection(socket.assigns.current_user, user_uuid) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Connection removed")
         |> load_counts()
         |> load_tab_data(socket.assigns.tab)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to remove connection")}
    end
  end

  @impl true
  def handle_event("unblock", %{"uuid" => user_uuid}, socket) do
    case Connections.unblock(socket.assigns.current_user, user_uuid) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "User unblocked")
         |> load_counts()
         |> load_tab_data(socket.assigns.tab)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unblock user")}
    end
  end

  defp load_counts(socket) do
    user = socket.assigns.current_user

    socket
    |> assign(:followers_count, Connections.followers_count(user))
    |> assign(:following_count, Connections.following_count(user))
    |> assign(:connections_count, Connections.connections_count(user))
    |> assign(:pending_count, Connections.pending_requests_count(user))
    |> assign(:blocked_count, length(Connections.list_blocked(user, preload: false)))
  end

  defp load_tab_data(socket, "followers") do
    followers = Connections.list_followers(socket.assigns.current_user)
    assign(socket, :items, followers)
  end

  defp load_tab_data(socket, "following") do
    following = Connections.list_following(socket.assigns.current_user)
    assign(socket, :items, following)
  end

  defp load_tab_data(socket, "connections") do
    connections = Connections.list_connections(socket.assigns.current_user)
    assign(socket, :items, connections)
  end

  defp load_tab_data(socket, "requests") do
    incoming = Connections.list_pending_requests(socket.assigns.current_user)
    outgoing = Connections.list_sent_requests(socket.assigns.current_user)

    socket
    |> assign(:incoming_requests, incoming)
    |> assign(:outgoing_requests, outgoing)
    |> assign(:items, [])
  end

  defp load_tab_data(socket, "blocked") do
    blocked = Connections.list_blocked(socket.assigns.current_user)
    assign(socket, :items, blocked)
  end

  defp load_tab_data(socket, _), do: assign(socket, :items, [])

  # Helper to get the other user from a connection
  def get_other_user(connection, current_user_uuid) do
    if connection.requester_uuid == current_user_uuid do
      connection.recipient
    else
      connection.requester
    end
  end
end
