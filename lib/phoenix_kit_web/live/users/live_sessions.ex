defmodule PhoenixKitWeb.Live.Users.LiveSessions do
  @moduledoc """
  Real-time session monitoring dashboard for the PhoenixKit admin panel.

  This module provides comprehensive real-time monitoring of:
  - All active sessions (anonymous + authenticated)
  - Live session statistics and metrics
  - Real-time connection/disconnection events
  - Session geographic distribution
  - Page activity heatmaps
  - User behavior patterns

  Features real-time updates via Phoenix LiveView and WebSocket connectivity.
  Only accessible to users with Owner or Admin roles.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Admin.{Events, Presence}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope

  # Refresh every 5 seconds
  @refresh_interval 5_000
  @per_page 20

  def mount(_params, session, socket) do
    # Subscribe to presence events for real-time updates
    if connected?(socket) do
      Events.subscribe_to_presence()
      Events.subscribe_to_stats()

      # Start auto-refresh timer
      schedule_refresh()

      # Track authenticated user session if logged in
      track_authenticated_session(socket, session)
    end

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    socket =
      socket
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:search_query, "")
      # all, anonymous, authenticated
      |> assign(:filter_type, "all")
      |> assign(:page_title, "Live Sessions")
      |> assign(:project_title, project_title)
      |> assign(:sort_by, :connected_at)
      |> assign(:sort_order, :desc)
      |> assign(:auto_refresh, true)
      |> assign(:last_updated, DateTime.utc_now())
      |> load_sessions()
      |> load_stats()

    {:ok, socket}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("search", %{"search" => search_query}, socket) do
    socket =
      socket
      |> assign(:search_query, search_query)
      |> assign(:page, 1)
      |> load_sessions()

    {:noreply, socket}
  end

  def handle_event("filter_by", %{"type" => filter_type}, socket) do
    socket =
      socket
      |> assign(:filter_type, filter_type)
      |> assign(:page, 1)
      |> load_sessions()

    {:noreply, socket}
  end

  def handle_event("sort_by", %{"field" => field}, socket) do
    field_atom = String.to_existing_atom(field)

    {sort_by, sort_order} =
      if socket.assigns.sort_by == field_atom do
        {field_atom, toggle_sort_order(socket.assigns.sort_order)}
      else
        {field_atom, :desc}
      end

    socket =
      socket
      |> assign(:sort_by, sort_by)
      |> assign(:sort_order, sort_order)
      |> load_sessions()

    {:noreply, socket}
  end

  def handle_event("toggle_auto_refresh", _params, socket) do
    auto_refresh = !socket.assigns.auto_refresh

    if auto_refresh do
      schedule_refresh()
    end

    socket = assign(socket, :auto_refresh, auto_refresh)
    {:noreply, socket}
  end

  def handle_event("refresh_now", _params, socket) do
    socket =
      socket
      |> assign(:last_updated, DateTime.utc_now())
      |> load_sessions()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info(:refresh, socket) do
    if socket.assigns.auto_refresh do
      socket =
        socket
        |> assign(:last_updated, DateTime.utc_now())
        |> load_sessions()
        |> load_stats()

      schedule_refresh()
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Handle real-time presence events
  def handle_info({:anonymous_session_connected, _session_id, _metadata}, socket) do
    socket =
      socket
      |> assign(:last_updated, DateTime.utc_now())
      |> load_sessions()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:anonymous_session_disconnected, _session_id}, socket) do
    socket =
      socket
      |> assign(:last_updated, DateTime.utc_now())
      |> load_sessions()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:user_session_connected, _user_id, _metadata}, socket) do
    socket =
      socket
      |> assign(:last_updated, DateTime.utc_now())
      |> load_sessions()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:user_session_disconnected, _user_id, _session_id}, socket) do
    socket =
      socket
      |> assign(:last_updated, DateTime.utc_now())
      |> load_sessions()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:presence_stats_updated, stats}, socket) do
    socket =
      socket
      |> assign(:presence_stats, stats)
      |> assign(:last_updated, DateTime.utc_now())

    {:noreply, socket}
  end

  # Ignore other messages
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_sessions(socket) do
    sessions = Presence.list_active_sessions()

    # Apply filters
    filtered_sessions =
      sessions
      |> filter_by_search(socket.assigns.search_query)
      |> filter_by_type(socket.assigns.filter_type)
      |> sort_sessions(socket.assigns.sort_by, socket.assigns.sort_order)

    # Calculate pagination
    total_count = length(filtered_sessions)
    total_pages = max(1, ceil(total_count / socket.assigns.per_page))
    page = min(socket.assigns.page, total_pages)

    # Get page sessions
    page_sessions =
      filtered_sessions
      |> Enum.drop((page - 1) * socket.assigns.per_page)
      |> Enum.take(socket.assigns.per_page)

    socket
    |> assign(:sessions, page_sessions)
    |> assign(:total_sessions, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:page, page)
  end

  defp load_stats(socket) do
    stats = Presence.get_presence_stats()
    assign(socket, :presence_stats, stats)
  end

  defp filter_by_search(sessions, "") do
    sessions
  end

  defp filter_by_search(sessions, search_query) do
    query = String.downcase(search_query)

    Enum.filter(sessions, fn session ->
      String.contains?(String.downcase(session.ip_address || ""), query) ||
        String.contains?(String.downcase(session.user_agent || ""), query) ||
        String.contains?(String.downcase(session.current_page || ""), query) ||
        (session.user_email && String.contains?(String.downcase(session.user_email), query))
    end)
  end

  defp filter_by_type(sessions, "all"), do: sessions
  defp filter_by_type(sessions, "anonymous"), do: Enum.filter(sessions, &(&1.type == :anonymous))

  defp filter_by_type(sessions, "authenticated"),
    do: Enum.filter(sessions, &(&1.type == :authenticated))

  defp sort_sessions(sessions, sort_by, sort_order) do
    sessions
    |> Enum.sort_by(fn session -> Map.get(session, sort_by) end, sort_order)
  end

  defp toggle_sort_order(:asc), do: :desc
  defp toggle_sort_order(:desc), do: :asc

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp track_authenticated_session(socket, session) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.authenticated?(scope) do
      user_id = Scope.user_id(scope)
      user_email = Scope.user_email(scope)

      # Create a user struct for tracking
      user = %{id: user_id, email: user_email}
      session_id = session["live_socket_id"] || generate_session_id()

      Presence.track_user(user, %{
        connected_at: DateTime.utc_now(),
        session_id: session_id,
        ip_address: IpAddress.extract_from_socket(socket),
        user_agent: get_connect_info(socket, :user_agent),
        current_page: Routes.path("/admin/users/live_sessions")
      })
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end
end
