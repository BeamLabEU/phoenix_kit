defmodule PhoenixKitWeb.Live.Dashboard do
  @moduledoc """
  Admin dashboard LiveView for PhoenixKit.

  Provides real-time system statistics, user metrics, and session monitoring.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Admin.{Events, Presence}
  alias PhoenixKit.Migrations.Postgres, as: Migrations
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Roles, Sessions}
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.Date, as: UtilsDate

  def mount(_params, session, socket) do
    # Subscribe to statistics updates for live data
    if connected?(socket) do
      Events.subscribe_to_stats()
      Events.subscribe_to_sessions()
      Events.subscribe_to_presence()

      # Track authenticated user session if logged in
      track_authenticated_session(socket, session)
    end

    # Load extended statistics including activity and confirmation status (now optimized!)
    stats = Roles.get_extended_stats()
    session_stats = Sessions.get_session_stats()
    presence_stats = Presence.get_presence_stats()

    # Get PhoenixKit version from application specification
    version = Application.spec(:phoenix_kit, :vsn) |> to_string()

    # Get migration versions
    migration_current = Migrations.current_version()
    migration_db = Migrations.migrated_version_runtime(%{prefix: "public"})

    # Get project title from settings cache
    project_title = Settings.get_project_title()

    # Cache user roles from scope to avoid repeated DB queries
    user_roles =
      case socket.assigns[:phoenix_kit_current_scope] do
        %{cached_roles: cached_roles} when is_list(cached_roles) -> cached_roles
        _ -> []
      end

    socket =
      socket
      |> assign(:stats, stats)
      |> assign(:session_stats, session_stats)
      |> assign(:presence_stats, presence_stats)
      |> assign(:phoenix_kit_version, version)
      |> assign(:migration_current, migration_current)
      |> assign(:migration_db, migration_db)
      |> assign(:project_title, project_title)
      |> assign(:page_title, "Dashboard")
      |> assign(:cached_user_roles, user_roles)

    {:ok, socket}
  end

  def handle_event("refresh_stats", _params, socket) do
    # Refresh statistics with optimized single query
    stats = Roles.get_extended_stats()
    session_stats = Sessions.get_session_stats()
    presence_stats = Presence.get_presence_stats()

    socket =
      socket
      |> assign(:stats, stats)
      |> assign(:session_stats, session_stats)
      |> assign(:presence_stats, presence_stats)
      |> assign(:stats_last_updated, :os.system_time(:second))
      |> put_flash(:info, gettext("Statistics refreshed successfully"))

    {:noreply, socket}
  end

  # Handle live statistics updates from PubSub
  def handle_info({:stats_updated, stats}, socket) do
    socket =
      socket
      |> assign(:stats, stats)
      |> assign(:stats_last_updated, :os.system_time(:second))

    {:noreply, socket}
  end

  # Handle live session statistics updates from PubSub
  def handle_info({:sessions_stats_updated, session_stats}, socket) do
    socket =
      socket
      |> assign(:session_stats, session_stats)

    {:noreply, socket}
  end

  # Handle live presence statistics updates from PubSub
  def handle_info({:presence_stats_updated, presence_stats}, socket) do
    socket =
      socket
      |> assign(:presence_stats, presence_stats)

    {:noreply, socket}
  end

  def handle_info({:anonymous_session_connected, _session_id, _metadata}, socket) do
    {:noreply, update_presence_stats(socket)}
  end

  def handle_info({:anonymous_session_disconnected, _session_id}, socket) do
    {:noreply, update_presence_stats(socket)}
  end

  def handle_info({:user_session_connected, _user_id, _metadata}, socket) do
    {:noreply, update_presence_stats(socket)}
  end

  def handle_info({:user_session_disconnected, _user_id, _session_id}, socket) do
    {:noreply, update_presence_stats(socket)}
  end

  defp update_presence_stats(socket) do
    assign(socket, :presence_stats, Presence.get_presence_stats())
  end

  defp track_authenticated_session(socket, session) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.authenticated?(scope) do
      user_id = Scope.user_id(scope)
      user_email = Scope.user_email(scope)

      # Create a user map for tracking (uuid required by SimplePresence)
      user = %{uuid: scope.user.uuid, id: user_id, email: user_email}
      session_id = session["live_socket_id"] || generate_session_id()

      Presence.track_user(user, %{
        connected_at: UtilsDate.utc_now(),
        session_id: session_id,
        ip_address: IpAddress.extract_from_socket(socket),
        user_agent: get_connect_info(socket, :user_agent),
        current_page: Routes.path("/admin")
      })
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end
end
