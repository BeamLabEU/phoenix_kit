defmodule PhoenixKit.Admin.SimplePresence do
  @moduledoc """
  Simple presence tracking system for PhoenixKit admin interface.

  This is a lightweight alternative to Phoenix.Presence that works
  without requiring a full OTP application supervision tree.
  """

  use GenServer
  require Logger

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.PubSub.Manager

  @table_name :phoenix_kit_sessions
  @server_name __MODULE__
  @presence_topic "phoenix_kit:presence"

  ## Public API

  @doc """
  Starts the simple presence system.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @server_name)
  end

  @doc """
  Tracks an anonymous session.
  """
  def track_anonymous(session_id, metadata \\ %{}) do
    key = "anonymous:#{session_id}"

    metadata =
      metadata
      |> Map.put(:type, :anonymous)
      |> Map.put(:session_id, session_id)
      |> Map.put_new(:connected_at, DateTime.utc_now())

    case GenServer.call(@server_name, {:track, key, metadata}) do
      :ok ->
        Events.broadcast_anonymous_session_connected(session_id, metadata)
        broadcast_presence_stats()
        :ok

      error ->
        error
    end
  rescue
    error ->
      Logger.error("Failed to track anonymous session: #{inspect(error)}")
      {:error, error}
  end

  @doc """
  Tracks an authenticated user session.
  """
  def track_user(user, metadata \\ %{}) do
    key = "user:#{user.id}"

    metadata =
      metadata
      |> Map.put(:type, :authenticated)
      |> Map.put(:user_id, user.id)
      |> Map.put(:user_email, user.email)
      |> Map.put_new(:connected_at, DateTime.utc_now())

    case GenServer.call(@server_name, {:track, key, metadata}) do
      :ok ->
        Events.broadcast_user_session_connected(user.id, metadata)
        broadcast_presence_stats()
        :ok

      error ->
        error
    end
  rescue
    error ->
      Logger.error("Failed to track user session: #{inspect(error)}")
      {:error, error}
  end

  @doc """
  Updates metadata for an existing presence.
  """
  def update_metadata(key, metadata_updates) do
    case GenServer.call(@server_name, {:update, key, metadata_updates}) do
      :ok ->
        broadcast_presence_stats()
        :ok

      error ->
        error
    end
  end

  @doc """
  Lists all active sessions.
  """
  def list_active_sessions do
    @table_name
    |> :ets.tab2list()
    |> Enum.map(fn {_key, metadata} -> metadata end)
    |> Enum.sort_by(& &1.connected_at, {:desc, DateTime})
  rescue
    ArgumentError ->
      []
  end

  @doc """
  Lists anonymous sessions only.
  """
  def list_anonymous_sessions do
    list_active_sessions()
    |> Enum.filter(&(&1.type == :anonymous))
  end

  @doc """
  Lists authenticated sessions only.
  """
  def list_authenticated_sessions do
    list_active_sessions()
    |> Enum.filter(&(&1.type == :authenticated))
  end

  @doc """
  Gets presence statistics.
  """
  def get_presence_stats do
    active_sessions = list_active_sessions()

    anonymous_sessions = Enum.filter(active_sessions, &(&1.type == :anonymous))
    authenticated_sessions = Enum.filter(active_sessions, &(&1.type == :authenticated))

    # Calculate page statistics
    page_stats =
      active_sessions
      |> Enum.filter(&(not is_nil(&1.current_page)))
      |> Enum.group_by(& &1.current_page)
      |> Enum.map(fn {page, sessions} -> {page, length(sessions)} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(10)

    %{
      total_sessions: length(active_sessions),
      anonymous_sessions: length(anonymous_sessions),
      authenticated_sessions: length(authenticated_sessions),
      unique_anonymous_visitors: length(Enum.uniq_by(anonymous_sessions, & &1.session_id)),
      active_authenticated_users: length(Enum.uniq_by(authenticated_sessions, & &1.user_id)),
      top_pages: page_stats,
      last_updated: DateTime.utc_now()
    }
  end

  @doc """
  Subscribes to presence events.
  """
  def subscribe do
    Manager.subscribe(@presence_topic)
  end

  @doc """
  Gets the presence topic name.
  """
  def get_topic, do: @presence_topic

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for session tracking
    :ets.new(@table_name, [:named_table, :public, :set])

    # Schedule cleanup of old sessions every 5 minutes
    schedule_cleanup()

    Logger.debug("PhoenixKit.Admin.SimplePresence started")

    {:ok, %{}}
  end

  @impl true
  def handle_call({:track, key, metadata}, {pid, _ref}, state) do
    # Store session with process monitor
    monitor_ref = Process.monitor(pid)
    metadata = Map.put(metadata, :monitor_ref, monitor_ref)

    :ets.insert(@table_name, {key, metadata})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update, key, metadata_updates}, _from, state) do
    case :ets.lookup(@table_name, key) do
      [{^key, existing_metadata}] ->
        updated_metadata = Map.merge(existing_metadata, metadata_updates)
        :ets.insert(@table_name, {key, updated_metadata})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    # Remove session when process dies
    cleanup_session_by_monitor(monitor_ref)
    broadcast_presence_stats()

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_sessions()
    schedule_cleanup()

    {:noreply, state}
  end

  ## Private Functions

  defp broadcast_presence_stats do
    stats = get_presence_stats()
    Events.broadcast_presence_stats_updated(stats)
  end

  defp schedule_cleanup do
    # 5 minutes
    Process.send_after(self(), :cleanup, 5 * 60 * 1000)
  end

  defp cleanup_session_by_monitor(monitor_ref) do
    # Find and remove session by monitor reference
    @table_name
    |> :ets.tab2list()
    |> Enum.find(fn {_key, metadata} ->
      Map.get(metadata, :monitor_ref) == monitor_ref
    end)
    |> case do
      {key, metadata} ->
        :ets.delete(@table_name, key)

        # Broadcast disconnect event
        case metadata.type do
          :anonymous ->
            Events.broadcast_anonymous_session_disconnected(metadata.session_id)

          :authenticated ->
            Events.broadcast_user_session_disconnected(metadata.user_id, metadata.session_id)
        end

      nil ->
        :ok
    end
  end

  defp cleanup_old_sessions do
    # Remove sessions older than 1 hour
    one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

    @table_name
    |> :ets.tab2list()
    |> Enum.filter(fn {_key, metadata} ->
      DateTime.compare(metadata.connected_at, one_hour_ago) == :lt
    end)
    |> Enum.each(fn {key, metadata} ->
      :ets.delete(@table_name, key)

      # Broadcast disconnect event
      case metadata.type do
        :anonymous ->
          Events.broadcast_anonymous_session_disconnected(metadata.session_id)

        :authenticated ->
          Events.broadcast_user_session_disconnected(metadata.user_id, metadata.session_id)
      end
    end)

    if length(@table_name |> :ets.tab2list()) > 0 do
      broadcast_presence_stats()
    end
  end
end
