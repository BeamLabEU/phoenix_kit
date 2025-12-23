defmodule PhoenixKit.Admin.Events do
  @moduledoc """
  PubSub event broadcasting for PhoenixKit admin panels.

  This module provides functions to broadcast changes in users, roles, sessions, and
  dashboard statistics to all connected admin interfaces.

  ## Topics

  - `phoenix_kit:admin:users` - User changes (creation, updates, role changes)
  - `phoenix_kit:admin:roles` - Role changes (creation, updates, deletion)
  - `phoenix_kit:admin:sessions` - Session changes (creation, revocation)
  - `phoenix_kit:admin:presence` - Anonymous and authenticated session presence
  - `phoenix_kit:admin:stats` - Dashboard statistics updates

  ## Events

  ### User Events
  - `{:user_created, user}` - New user registered
  - `{:user_updated, user}` - User profile/status updated
  - `{:user_confirmed, user}` - User email confirmed
  - `{:user_unconfirmed, user}` - User email unconfirmed
  - `{:user_role_assigned, user, role_name}` - Role assigned to user
  - `{:user_role_removed, user, role_name}` - Role removed from user
  - `{:user_roles_synced, user, new_roles}` - User roles synchronized

  ### Role Events
  - `{:role_created, role}` - New role created
  - `{:role_updated, role}` - Role updated
  - `{:role_deleted, role}` - Role deleted

  ### Session Events
  - `{:session_created, user, token_info}` - New session created
  - `{:session_revoked, token_id}` - Session revoked
  - `{:user_sessions_revoked, user_id, count}` - All user sessions revoked
  - `{:sessions_stats_updated, stats}` - Session statistics updated

  ### Presence Events
  - `{:anonymous_session_connected, session_id, session_info}` - Anonymous visitor connected
  - `{:anonymous_session_disconnected, session_id}` - Anonymous visitor disconnected
  - `{:user_session_connected, user_id, session_info}` - Authenticated user connected
  - `{:user_session_disconnected, user_id, session_id}` - Authenticated user disconnected
  - `{:presence_stats_updated, stats}` - Real-time presence statistics updated

  ### Statistics Events
  - `{:stats_updated, stats}` - Dashboard statistics updated

  ## Examples

      # Broadcast user creation
      PhoenixKit.Admin.Events.broadcast_user_created(user)

      # Broadcast role assignment
      PhoenixKit.Admin.Events.broadcast_user_role_assigned(user, "Admin")

      # Broadcast statistics update
      PhoenixKit.Admin.Events.broadcast_stats_updated()
  """

  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.Sessions

  # Topic names
  @topic_users "phoenix_kit:admin:users"
  @topic_roles "phoenix_kit:admin:roles"
  @topic_sessions "phoenix_kit:admin:sessions"
  @topic_presence "phoenix_kit:admin:presence"
  @topic_stats "phoenix_kit:admin:stats"

  ## User Events

  @doc """
  Broadcasts user creation event to admin panels.
  """
  def broadcast_user_created(user) do
    broadcast(@topic_users, {:user_created, user})
    maybe_broadcast_stats_updated()
  end

  @doc """
  Broadcasts user update event to admin panels.
  """
  def broadcast_user_updated(user) do
    broadcast(@topic_users, {:user_updated, user})
    maybe_broadcast_stats_updated()
  end

  @doc """
  Broadcasts user role assignment event to admin panels.
  """
  def broadcast_user_role_assigned(user, role_name) do
    broadcast(@topic_users, {:user_role_assigned, user, role_name})
    maybe_broadcast_stats_updated()
  end

  @doc """
  Broadcasts user role removal event to admin panels.
  """
  def broadcast_user_role_removed(user, role_name) do
    broadcast(@topic_users, {:user_role_removed, user, role_name})
    maybe_broadcast_stats_updated()
  end

  @doc """
  Broadcasts user roles synchronization event to admin panels.
  """
  def broadcast_user_roles_synced(user, new_roles) do
    broadcast(@topic_users, {:user_roles_synced, user, new_roles})
    maybe_broadcast_stats_updated()
  end

  @doc """
  Broadcasts user confirmation event to admin panels.
  """
  def broadcast_user_confirmed(user) do
    broadcast(@topic_users, {:user_confirmed, user})
    maybe_broadcast_stats_updated()
  end

  @doc """
  Broadcasts user unconfirmation event to admin panels.
  """
  def broadcast_user_unconfirmed(user) do
    broadcast(@topic_users, {:user_unconfirmed, user})
    maybe_broadcast_stats_updated()
  end

  ## Role Events

  @doc """
  Broadcasts role creation event to admin panels.
  """
  def broadcast_role_created(role) do
    broadcast(@topic_roles, {:role_created, role})
    maybe_broadcast_stats_updated()
  end

  @doc """
  Broadcasts role update event to admin panels.
  """
  def broadcast_role_updated(role) do
    broadcast(@topic_roles, {:role_updated, role})
  end

  @doc """
  Broadcasts role deletion event to admin panels.
  """
  def broadcast_role_deleted(role) do
    broadcast(@topic_roles, {:role_deleted, role})
    maybe_broadcast_stats_updated()
  end

  ## Session Events

  @doc """
  Broadcasts session creation event to admin panels.
  """
  def broadcast_session_created(user, token_info) do
    broadcast(@topic_sessions, {:session_created, user, token_info})
    broadcast_sessions_stats_updated()
  end

  @doc """
  Broadcasts session revocation event to admin panels.
  """
  def broadcast_session_revoked(token_id) do
    broadcast(@topic_sessions, {:session_revoked, token_id})
    broadcast_sessions_stats_updated()
  end

  @doc """
  Broadcasts user sessions revocation event to admin panels.
  """
  def broadcast_user_sessions_revoked(user_id, count) do
    broadcast(@topic_sessions, {:user_sessions_revoked, user_id, count})
    broadcast_sessions_stats_updated()
  end

  @doc """
  Broadcasts session statistics update event to admin panels.
  """
  def broadcast_sessions_stats_updated do
    stats = Sessions.get_session_stats()
    broadcast(@topic_sessions, {:sessions_stats_updated, stats})
  end

  ## Presence Events

  @doc """
  Broadcasts anonymous session connection event to admin panels.
  """
  def broadcast_anonymous_session_connected(session_id, session_info) do
    broadcast(@topic_presence, {:anonymous_session_connected, session_id, session_info})
  end

  @doc """
  Broadcasts anonymous session disconnection event to admin panels.
  """
  def broadcast_anonymous_session_disconnected(session_id) do
    broadcast(@topic_presence, {:anonymous_session_disconnected, session_id})
  end

  @doc """
  Broadcasts authenticated user session connection event to admin panels.
  """
  def broadcast_user_session_connected(user_id, session_info) do
    broadcast(@topic_presence, {:user_session_connected, user_id, session_info})
  end

  @doc """
  Broadcasts authenticated user session disconnection event to admin panels.
  """
  def broadcast_user_session_disconnected(user_id, session_id) do
    broadcast(@topic_presence, {:user_session_disconnected, user_id, session_id})
  end

  @doc """
  Broadcasts presence statistics update event to admin panels.
  """
  def broadcast_presence_stats_updated(stats) do
    broadcast(@topic_presence, {:presence_stats_updated, stats})
  end

  ## Statistics Events

  @doc """
  Broadcasts statistics update event to admin dashboard.
  """
  def broadcast_stats_updated do
    stats = Roles.get_extended_stats()
    broadcast(@topic_stats, {:stats_updated, stats})
  end

  ## Subscription Functions

  @doc """
  Subscribes to user events for admin panels.
  """
  def subscribe_to_users do
    Manager.subscribe(@topic_users)
  end

  @doc """
  Subscribes to role events for admin panels.
  """
  def subscribe_to_roles do
    Manager.subscribe(@topic_roles)
  end

  @doc """
  Subscribes to session events for admin panels.
  """
  def subscribe_to_sessions do
    Manager.subscribe(@topic_sessions)
  end

  @doc """
  Subscribes to presence events for admin panels.
  """
  def subscribe_to_presence do
    Manager.subscribe(@topic_presence)
  end

  @doc """
  Subscribes to statistics events for admin dashboard.
  """
  def subscribe_to_stats do
    Manager.subscribe(@topic_stats)
  end

  @doc """
  Subscribes to all admin events.
  """
  def subscribe_to_all_admin_events do
    subscribe_to_users()
    subscribe_to_roles()
    subscribe_to_sessions()
    subscribe_to_presence()
    subscribe_to_stats()
  end

  ## Private Functions

  defp broadcast(topic, message) do
    Manager.broadcast(topic, message)
  end

  # Safe version that doesn't crash if no repository configured
  defp maybe_broadcast_stats_updated do
    broadcast_stats_updated()
  rescue
    # No repository configured, skip stats
    RuntimeError -> :ok
    # Any other error, skip stats
    _ -> :ok
  end
end
