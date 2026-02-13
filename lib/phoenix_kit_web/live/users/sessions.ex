defmodule PhoenixKitWeb.Live.Users.Sessions do
  @moduledoc """
  Live component for managing active user sessions in the PhoenixKit admin panel.

  This module provides functionality to:
  - View all active sessions across the system
  - See session details including user info, creation time, and age
  - Revoke individual sessions
  - Revoke all sessions for a specific user
  - View session statistics

  Only accessible to users with Owner or Admin roles.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, Sessions}
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @per_page 20

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale =
      params["locale"] || socket.assigns[:current_locale]

    # Subscribe to session events for real-time updates
    if connected?(socket) do
      Events.subscribe_to_sessions()
    end

    # Get project title from settings
    project_title = Settings.get_project_title()

    socket =
      socket
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:search_query, "")
      |> assign(:filter_user_status, "all")
      |> assign(:page_title, "Sessions")
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:show_revoke_modal, false)
      |> assign(:selected_session, nil)
      |> assign(:revoke_type, nil)
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

  def handle_event("filter_by_user_status", %{"status" => status}, socket) do
    socket =
      socket
      |> assign(:filter_user_status, status)
      |> assign(:page, 1)
      |> load_sessions()

    {:noreply, socket}
  end

  def handle_event("change_page", %{"page" => page}, socket) do
    page = String.to_integer(page)

    socket =
      socket
      |> assign(:page, page)
      |> load_sessions()

    {:noreply, socket}
  end

  def handle_event("show_revoke_session", %{"token_id" => token_id}, socket) do
    session_info = Sessions.get_session_info(token_id)

    socket =
      socket
      |> assign(:selected_session, session_info)
      |> assign(:revoke_type, :single)
      |> assign(:show_revoke_modal, true)

    {:noreply, socket}
  end

  def handle_event("show_revoke_user_sessions", %{"user_id" => user_id}, socket) do
    user = Auth.get_user!(user_id)
    user_sessions = Sessions.list_user_sessions(user)

    socket =
      socket
      |> assign(:selected_user, user)
      |> assign(:user_sessions_count, length(user_sessions))
      |> assign(:revoke_type, :user_all)
      |> assign(:show_revoke_modal, true)

    {:noreply, socket}
  end

  def handle_event("hide_revoke_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_revoke_modal, false)
      |> assign(:selected_session, nil)
      |> assign(:selected_user, nil)
      |> assign(:revoke_type, nil)

    {:noreply, socket}
  end

  def handle_event("confirm_revoke_session", _params, socket) do
    case socket.assigns.revoke_type do
      :single ->
        handle_single_session_revoke(socket)

      :user_all ->
        handle_user_sessions_revoke(socket)

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid revoke operation")}
    end
  end

  def handle_event("refresh_sessions", _params, socket) do
    socket =
      socket
      |> load_sessions()
      |> load_stats()
      |> put_flash(:info, "Sessions refreshed successfully")

    {:noreply, socket}
  end

  defp handle_single_session_revoke(socket) do
    session = socket.assigns.selected_session

    case Sessions.revoke_session(session.token_id) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, "Session revoked successfully")
          |> assign(:show_revoke_modal, false)
          |> assign(:selected_session, nil)
          |> assign(:revoke_type, nil)
          |> load_sessions()
          |> load_stats()

        {:noreply, socket}

      {:error, :not_found} ->
        socket =
          socket
          |> put_flash(:error, "Session not found or already expired")
          |> assign(:show_revoke_modal, false)
          |> load_sessions()

        {:noreply, socket}
    end
  end

  defp handle_user_sessions_revoke(socket) do
    user = socket.assigns.selected_user

    revoked_count = Sessions.revoke_user_sessions(user)

    socket =
      socket
      |> put_flash(:info, "#{revoked_count} session(s) revoked for user #{user.email}")
      |> assign(:show_revoke_modal, false)
      |> assign(:selected_user, nil)
      |> assign(:revoke_type, nil)
      |> load_sessions()
      |> load_stats()

    {:noreply, socket}
  end

  defp load_sessions(socket) do
    sessions = Sessions.list_active_sessions()

    # Apply filtering
    filtered_sessions =
      sessions
      |> filter_by_search(socket.assigns.search_query)
      |> filter_by_user_status(socket.assigns.filter_user_status)

    # Apply pagination
    total_count = length(filtered_sessions)
    total_pages = div(total_count + @per_page - 1, @per_page)

    page = max(1, min(socket.assigns.page, total_pages))
    offset = (page - 1) * @per_page

    paginated_sessions =
      filtered_sessions
      |> Enum.drop(offset)
      |> Enum.take(@per_page)

    socket
    |> assign(:sessions, paginated_sessions)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:page, page)
  end

  defp load_stats(socket) do
    stats = Sessions.get_session_stats()

    socket
    |> assign(:stats, stats)
  end

  defp filter_by_search(sessions, ""), do: sessions

  defp filter_by_search(sessions, query) do
    query_lower = String.downcase(query)

    Enum.filter(sessions, fn session ->
      String.contains?(String.downcase(session.user_email), query_lower) ||
        String.contains?(String.downcase(session.token_preview), query_lower)
    end)
  end

  defp filter_by_user_status(sessions, "all"), do: sessions

  defp filter_by_user_status(sessions, "active") do
    Enum.filter(sessions, & &1.user_is_active)
  end

  defp filter_by_user_status(sessions, "inactive") do
    Enum.filter(sessions, &(!&1.user_is_active))
  end

  defp filter_by_user_status(sessions, "confirmed") do
    Enum.filter(sessions, &(!is_nil(&1.user_confirmed_at)))
  end

  defp filter_by_user_status(sessions, "pending") do
    Enum.filter(sessions, &is_nil(&1.user_confirmed_at))
  end

  ## Live Event Handlers for Sessions

  def handle_info({:session_created, _user, _token_info}, socket) do
    socket =
      socket
      |> load_sessions()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:session_revoked, _token_id}, socket) do
    socket =
      socket
      |> load_sessions()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:user_sessions_revoked, _user_id, _count}, socket) do
    socket =
      socket
      |> load_sessions()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:sessions_stats_updated, stats}, socket) do
    socket =
      socket
      |> assign(:stats, stats)

    {:noreply, socket}
  end
end
