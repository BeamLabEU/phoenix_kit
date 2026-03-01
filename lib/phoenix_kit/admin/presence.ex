defmodule PhoenixKit.Admin.Presence do
  @moduledoc """
  Phoenix.Presence implementation for tracking anonymous and authenticated sessions.

  This module provides real-time tracking of:
  - Anonymous visitors (WebSocket connections without user_uuid)
  - Authenticated users (with user_uuid)
  - Session details like IP, User-Agent, current page, connection time

  ## Usage

  Track anonymous session:
  ```elixir
  PhoenixKit.Admin.Presence.track_anonymous(session_id, %{
    connected_at: DateTime.utc_now(),
    ip_address: get_connect_info(socket, :peer_data).address,
    user_agent: get_connect_info(socket, :user_agent),
    current_page: socket.assigns.current_path
  })
  ```

  Track authenticated session:
  ```elixir
  PhoenixKit.Admin.Presence.track_user(user, %{
    connected_at: DateTime.utc_now(),
    session_id: session_id,
    ip_address: get_connect_info(socket, :peer_data).address
  })
  ```

  ## Events Generated

  - `{:anonymous_session_connected, session_id, session_info}`
  - `{:anonymous_session_disconnected, session_id}`
  - `{:user_session_connected, user_uuid, session_info}`
  - `{:user_session_disconnected, user_uuid, session_id}`
  - `{:presence_stats_updated, stats}`
  """

  use Phoenix.Presence,
    otp_app: :phoenix_kit,
    pubsub_server: :phoenix_kit_internal_pubsub

  alias PhoenixKit.Admin.SimplePresence

  @doc """
  Tracks an anonymous session in Presence.

  ## Parameters
  - `session_id` - Unique session identifier
  - `metadata` - Session metadata map

  ## Metadata Fields
  - `:connected_at` - Connection timestamp
  - `:ip_address` - Client IP address
  - `:user_agent` - Browser User-Agent string
  - `:current_page` - Current page path
  """
  def track_anonymous(session_id, metadata \\ %{}) do
    # Delegate to SimplePresence for now
    SimplePresence.track_anonymous(session_id, metadata)
  end

  @doc """
  Tracks an authenticated user session in Presence.

  ## Parameters
  - `user` - User struct with id and email
  - `metadata` - Session metadata map

  ## Metadata Fields
  - `:connected_at` - Connection timestamp
  - `:session_id` - Session identifier
  - `:ip_address` - Client IP address
  - `:user_agent` - Browser User-Agent string
  - `:current_page` - Current page path
  """
  def track_user(user, metadata \\ %{}) do
    # Delegate to SimplePresence for now
    SimplePresence.track_user(user, metadata)
  end

  @doc """
  Updates metadata for an existing presence.

  Useful for updating current page or other session details.
  """
  def update_metadata(key, metadata_updates) do
    SimplePresence.update_metadata(key, metadata_updates)
  end

  @doc """
  Gets all currently active sessions (anonymous + authenticated).

  Returns a list of session maps with type, metadata, and connection info.
  """
  def list_active_sessions do
    SimplePresence.list_active_sessions()
  end

  @doc """
  Gets all anonymous sessions currently tracked.
  """
  def list_anonymous_sessions do
    SimplePresence.list_anonymous_sessions()
  end

  @doc """
  Gets all authenticated user sessions currently tracked.
  """
  def list_authenticated_sessions do
    SimplePresence.list_authenticated_sessions()
  end

  @doc """
  Gets presence statistics.

  Returns statistics about current active sessions:
  - Total sessions
  - Anonymous sessions count
  - Authenticated sessions count
  - Unique anonymous visitors
  - Active authenticated users
  - Top pages by activity
  """
  def get_presence_stats do
    SimplePresence.get_presence_stats()
  end

  @doc """
  Subscribes to presence events for real-time updates.
  """
  def subscribe do
    SimplePresence.subscribe()
  end

  @doc """
  Gets the presence topic name.
  """
  def get_topic, do: SimplePresence.get_topic()

  @doc """
  Starts the Presence process.
  """
  def start_link(opts \\ []) do
    opts =
      Keyword.merge([otp_app: :phoenix_kit, pubsub_server: :phoenix_kit_internal_pubsub], opts)

    Phoenix.Presence.start_link(__MODULE__, [], opts)
  end
end
