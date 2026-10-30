defmodule PhoenixKit.Admin.SimplePresence do
  @moduledoc """
  Simple presence tracking system for PhoenixKit admin interface.

  This is a lightweight alternative to Phoenix.Presence that works
  without requiring a full OTP application supervision tree.

  ## Keys and multi-tab tracking

  An authenticated visitor is tracked under `user_key(user_uuid, session_id)`
  (`"user:<uuid>:<session_id>"`), an anonymous one under
  `"anonymous:<session_id>"` — one ETS row per `(identity, session)`, not per
  process. `session_id` is a stable per-login identifier that is the same
  across every LiveView mount sharing one login or one anonymous browser
  session, so opening a second tab, or mounting a second LiveView under the
  same session, tracks the SAME row instead of creating a second one: each
  `track_*` call adds its calling process's monitor to that row's monitor set
  rather than replacing the previous tab's. The row is deleted — and a
  `*_session_disconnected` event broadcast — only once its LAST monitor goes
  down; closing one tab while another is still open just shrinks the monitor
  set.

  For an authenticated visitor tracked through `PhoenixKitWeb.Users.Auth`'s
  on_mount hooks, `session_id` is a SHA-256 digest of the session token
  (`Base.url_encode64/2`, not the raw token or the raw `live_socket_id`
  itself) — stable per login for idempotent keying, but not reversible if it
  ends up somewhere it shouldn't (a log line, a PubSub event payload). A call
  site that still passes a raw `session["live_socket_id"]`
  (`PhoenixKitWeb.Live.Dashboard.Overview`'s own local tracking call, which
  predates this scheme, and `phoenix_kit_entities`'s own hook, a separate
  package) produces a DIFFERENT `session_id` for the same login until it is
  updated to match — a second, otherwise-idempotent row rather than a merge.

  `connected_at` is pinned to the row's first appearance: a second tab
  merges its metadata into the existing row without resetting the timestamp.

  This table is local to the BEAM node it runs on — presence does not merge
  across nodes in a multi-node deployment, so a visitor connected to node A is
  invisible to a "Live sessions" page served from node B.
  """

  use GenServer
  require Logger

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate

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
  Builds the idempotent ETS key for a user's presence row.

  `session_id: nil` falls back to one row per user (pre-session-keying
  behavior) — a caller that tracks a user without a session_id still collides
  across tabs on that single row.
  """
  @spec user_key(String.t(), String.t() | nil) :: String.t()
  def user_key(user_uuid, session_id)
  def user_key(user_uuid, nil), do: "user:#{user_uuid}"
  def user_key(user_uuid, session_id), do: "user:#{user_uuid}:#{session_id}"

  @doc """
  Tracks an anonymous session.
  """
  def track_anonymous(session_id, metadata \\ %{}) do
    key = "anonymous:#{session_id}"

    metadata =
      metadata
      |> Map.put(:type, :anonymous)
      |> Map.put(:session_id, session_id)
      |> Map.put_new(:connected_at, UtilsDate.utc_now())

    case GenServer.call(@server_name, {:track, key, metadata}) do
      {:ok, :new} ->
        Events.broadcast_anonymous_session_connected(session_id, metadata)
        broadcast_presence_stats()
        :ok

      {:ok, :existing} ->
        broadcast_presence_stats()
        :ok

      error ->
        error
    end
  rescue
    error ->
      Logger.error("Failed to track anonymous session: #{inspect(error)}")
      {:error, error}
  catch
    # A dead/not-yet-started SimplePresence EXITS the caller rather than
    # raising — `rescue` alone does not see it (see AGENTS.md's "Soft-failure
    # paths need rescue AND catch :exit"). Presence is best-effort observability,
    # never a gate a visitor's page should fail behind.
    #
    # Logging `reason` itself (not just its class) would log the full
    # `GenServer.call` request — `{:noproc, {GenServer, :call, [__MODULE__,
    # {:track, key, metadata}, timeout]}}` — and `metadata`/`key` carry
    # `session_id`, `ip_address`, `user_agent`. `exit_class/1` keeps only the
    # class (`:noproc`, `:timeout`, ...) out of that tuple.
    :exit, reason ->
      class = exit_class(reason)
      Logger.error("Failed to track anonymous session: #{inspect(class)}")
      {:error, class}
  end

  @doc """
  Tracks an authenticated user session.

  Idempotent by `(user.uuid, metadata.session_id)` — a second `track_user/2`
  call for the same user and session (e.g. a second open tab, or another
  LiveView mounted under the same login) merges into the existing presence
  row instead of creating a second one or replacing the first tab's monitor.
  """
  def track_user(user, metadata \\ %{}) do
    key = user_key(user.uuid, Map.get(metadata, :session_id))

    metadata =
      metadata
      |> Map.put(:type, :authenticated)
      |> Map.put(:user_uuid, user.uuid)
      |> Map.put(:user_email, User.delivery_email(user))
      |> Map.put_new(:connected_at, UtilsDate.utc_now())

    case GenServer.call(@server_name, {:track, key, metadata}) do
      {:ok, :new} ->
        Events.broadcast_user_session_connected(user.uuid, metadata)
        broadcast_presence_stats()
        :ok

      {:ok, :existing} ->
        broadcast_presence_stats()
        :ok

      error ->
        error
    end
  rescue
    error ->
      Logger.error("Failed to track user session: #{inspect(error)}")
      {:error, error}
  catch
    # See track_anonymous/2 above: `reason` itself carries the request
    # (`metadata`, including `session_id`/`ip_address`/`user_agent`) — log
    # only its class.
    :exit, reason ->
      class = exit_class(reason)
      Logger.error("Failed to track user session: #{inspect(class)}")
      {:error, class}
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
  catch
    # Same reasoning as track_user/track_anonymous above: a dead/not-yet-started
    # SimplePresence must not take an in-flight navigation down with it, and
    # `reason` carries the request (`key`, which embeds `session_id`) — log
    # only its class.
    :exit, reason ->
      class = exit_class(reason)
      Logger.error("Failed to update presence metadata: #{inspect(class)}")
      {:error, class}
  end

  @doc """
  Lists all active sessions.
  """
  def list_active_sessions do
    @table_name
    |> :ets.tab2list()
    |> Enum.map(fn {_key, %{metadata: metadata}} -> metadata end)
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
      active_authenticated_users: length(Enum.uniq_by(authenticated_sessions, & &1.user_uuid)),
      top_pages: page_stats,
      last_updated: UtilsDate.utc_now()
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
    # One monitor per tracking call, all folded into the row's monitor set —
    # the row survives until the LAST of them goes down (see moduledoc).
    monitor_ref = Process.monitor(pid)

    status =
      case :ets.lookup(@table_name, key) do
        [] ->
          entry = %{metadata: metadata, monitors: MapSet.new([monitor_ref])}
          :ets.insert(@table_name, {key, entry})
          :new

        [{^key, existing}] ->
          merged_metadata =
            existing.metadata
            |> Map.merge(metadata)
            |> Map.put(:connected_at, existing.metadata.connected_at)

          entry = %{
            metadata: merged_metadata,
            monitors: MapSet.put(existing.monitors, monitor_ref)
          }

          :ets.insert(@table_name, {key, entry})
          :existing
      end

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call({:update, key, metadata_updates}, _from, state) do
    case :ets.lookup(@table_name, key) do
      [{^key, existing}] ->
        updated = %{existing | metadata: Map.merge(existing.metadata, metadata_updates)}
        :ets.insert(@table_name, {key, updated})
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

  # The class of a `GenServer.call` exit (`:noproc`, `:timeout`, `:killed`,
  # ...) without the request it was carrying — used by the `catch :exit`
  # clauses above, each of which would otherwise log a presence row's
  # session_id/ip_address/user_agent as part of the raw exit reason. A crash
  # inside the callback arrives as `{{exception, stacktrace}, call}`; the
  # stacktrace's top frame carries the BIF args (the ETS key and metadata),
  # so only the exception module is kept from that shape.
  defp exit_class({class, _call}) when is_atom(class), do: class
  defp exit_class({{:shutdown, _}, _call}), do: :shutdown
  defp exit_class({{%{__struct__: module}, _stacktrace}, _call}), do: module
  defp exit_class(reason) when is_atom(reason), do: reason
  defp exit_class(_reason), do: :unknown

  defp broadcast_presence_stats do
    stats = get_presence_stats()
    Events.broadcast_presence_stats_updated(stats)
  end

  defp schedule_cleanup do
    # 5 minutes
    Process.send_after(self(), :cleanup, 5 * 60 * 1000)
  end

  defp cleanup_session_by_monitor(monitor_ref) do
    # Find the row this monitor belongs to (small table — linear scan is fine)
    @table_name
    |> :ets.tab2list()
    |> Enum.find(fn {_key, entry} -> MapSet.member?(entry.monitors, monitor_ref) end)
    |> case do
      {key, entry} ->
        remaining_monitors = MapSet.delete(entry.monitors, monitor_ref)

        if MapSet.size(remaining_monitors) == 0 do
          :ets.delete(@table_name, key)
          broadcast_disconnect(entry.metadata)
        else
          # Another tab/mount is still tracking this session — keep the row.
          :ets.insert(@table_name, {key, %{entry | monitors: remaining_monitors}})
        end

      nil ->
        :ok
    end
  end

  defp broadcast_disconnect(%{type: :anonymous} = metadata),
    do: Events.broadcast_anonymous_session_disconnected(metadata.session_id)

  defp broadcast_disconnect(%{type: :authenticated} = metadata),
    do: Events.broadcast_user_session_disconnected(metadata.user_uuid, metadata.session_id)

  # A row's own `:DOWN` handling (`cleanup_session_by_monitor/1`) is now the
  # reliable way a row disappears — it fires the moment the row's LAST
  # monitor goes down, whatever `connected_at` says. This sweep exists only
  # for a row that somehow never got a `:DOWN` it was owed (the tracking
  # process's monitor firing lost, or a row this ETS table has held onto
  # across an event this module doesn't otherwise know how to recover from) —
  # it must NOT also evict a row a live monitor set still vouches for, or an
  # ordinary session open longer than an hour (a perfectly normal work
  # session on a host app's own page) would flicker: vanish from "Live
  # sessions" with a false disconnect, then reappear on its next navigation.
  defp cleanup_old_sessions do
    one_hour_ago = DateTime.add(UtilsDate.utc_now(), -3600, :second)

    @table_name
    |> :ets.tab2list()
    |> Enum.filter(fn {_key, entry} ->
      MapSet.size(entry.monitors) == 0 and
        DateTime.compare(entry.metadata.connected_at, one_hour_ago) == :lt
    end)
    |> Enum.each(fn {key, entry} ->
      :ets.delete(@table_name, key)
      broadcast_disconnect(entry.metadata)
    end)

    if not Enum.empty?(:ets.tab2list(@table_name)) do
      broadcast_presence_stats()
    end
  end
end
