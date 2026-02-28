defmodule PhoenixKit.Modules.Sync.SessionStore do
  @moduledoc """
  ETS-based session storage for DB Sync module.

  Stores sync sessions in ETS for fast, ephemeral access.
  Sessions remain valid as long as the owning LiveView process is alive.
  When the LiveView terminates (page closed), the session is automatically deleted.

  ## Architecture

  This module uses a GenServer to manage an ETS table. The ETS table
  provides fast reads while the GenServer handles process monitoring
  and automatic cleanup when LiveView processes terminate.

  ## Future Migration Path

  This module is designed to be easily replaced with database persistence
  if audit logging or sync history is needed. The public API would remain
  the same, only the storage backend would change.

  ## Session Structure

      %{
        code: "A7X9K2M4",
        direction: :send | :receive,
        status: :pending | :connected | :completed | :failed,
        owner_pid: #PID<0.123.0>,     # Session is deleted when this process dies
        created_at: ~U[2025-12-16 12:15:00Z],
        connected_at: nil | ~U[...],
        sender_info: nil | %{...},
        receiver_info: nil | %{...}
      }
  """

  use GenServer
  alias PhoenixKit.Utils.Date, as: UtilsDate
  require Logger

  @table_name :phoenix_kit_sync_sessions
  @monitors_table :phoenix_kit_sync_monitors
  @cleanup_interval :timer.hours(1)

  # ===========================================
  # PUBLIC API
  # ===========================================

  @doc """
  Starts the SessionStore GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new session in the store and monitors the owner process.

  ## Parameters

  - `session` - Map with at least `code` and `owner_pid` fields

  ## Returns

  - `:ok` on success
  - `{:error, :already_exists}` if code already exists
  """
  @spec create(map()) :: :ok | {:error, :already_exists}
  def create(%{code: code, owner_pid: pid} = session) when is_binary(code) and is_pid(pid) do
    case :ets.insert_new(@table_name, {code, session}) do
      true ->
        # Ask GenServer to monitor the owner process
        GenServer.cast(__MODULE__, {:monitor_session, code, pid})
        :ok

      false ->
        {:error, :already_exists}
    end
  end

  def create(%{code: code} = session) when is_binary(code) do
    # Fallback for sessions without owner_pid (backwards compatibility)
    case :ets.insert_new(@table_name, {code, session}) do
      true -> :ok
      false -> {:error, :already_exists}
    end
  end

  @doc """
  Gets a session by its code.

  ## Returns

  - `{:ok, session}` if found
  - `{:error, :not_found}` if not found
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(code) when is_binary(code) do
    case :ets.lookup(@table_name, code) do
      [{^code, session}] -> {:ok, session}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Updates an existing session.

  ## Returns

  - `:ok` on success
  - `{:error, :not_found}` if session doesn't exist
  """
  @spec update(String.t(), map()) :: :ok | {:error, :not_found}
  def update(code, session) when is_binary(code) and is_map(session) do
    case :ets.lookup(@table_name, code) do
      [{^code, _}] ->
        :ets.insert(@table_name, {code, session})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes a session by code.
  """
  @spec delete(String.t()) :: :ok
  def delete(code) when is_binary(code) do
    :ets.delete(@table_name, code)
    :ok
  end

  @doc """
  Counts active sessions.

  All sessions in the store are active (sessions are deleted when owner process terminates).
  """
  @spec count_active() :: non_neg_integer()
  def count_active do
    :ets.info(@table_name, :size)
  end

  @doc """
  Lists all active sessions.
  Useful for debugging and admin interfaces.

  All sessions in the store are active (sessions are deleted when owner process terminates).
  """
  @spec list_active() :: [map()]
  def list_active do
    :ets.tab2list(@table_name)
    |> Enum.map(fn {_code, session} -> session end)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  # ===========================================
  # GENSERVER CALLBACKS
  # ===========================================

  @impl true
  def init(_opts) do
    # Create ETS table with public access for fast reads
    :ets.new(@table_name, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Create monitors table to track ref -> code mappings
    :ets.new(@monitors_table, [
      :set,
      :named_table,
      :protected
    ])

    # Schedule periodic cleanup of orphaned sessions (fallback safety)
    schedule_cleanup()

    Logger.debug("Sync.SessionStore started")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:monitor_session, code, pid}, state) do
    ref = Process.monitor(pid)
    # Store mapping from monitor ref to session code
    :ets.insert(@monitors_table, {ref, code})
    Logger.debug("Sync.SessionStore: Monitoring #{inspect(pid)} for session #{code}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Process died, delete the associated session
    case :ets.lookup(@monitors_table, ref) do
      [{^ref, code}] ->
        :ets.delete(@monitors_table, ref)
        :ets.delete(@table_name, code)

        Logger.debug("Sync.SessionStore: Session #{code} deleted (owner process terminated)")

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_orphaned, state) do
    cleanup_orphaned_sessions()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_orphaned, @cleanup_interval)
  end

  defp cleanup_orphaned_sessions do
    # This is a fallback cleanup for any orphaned sessions
    # (e.g., if monitor somehow failed to fire)
    # Sessions without owner_pid or with dead owner_pid are cleaned up

    orphaned =
      :ets.foldl(
        fn {code, session}, acc ->
          case Map.get(session, :owner_pid) do
            nil ->
              # Session without owner - check if it's very old (created > 24h ago)
              if session_too_old?(session) do
                [code | acc]
              else
                acc
              end

            pid when is_pid(pid) ->
              # Check if the process is still alive
              if Process.alive?(pid) do
                acc
              else
                [code | acc]
              end
          end
        end,
        [],
        @table_name
      )

    # Delete orphaned sessions
    Enum.each(orphaned, &:ets.delete(@table_name, &1))

    if orphaned != [] do
      Logger.debug("Sync.SessionStore: Cleaned up #{length(orphaned)} orphaned sessions")
    end
  end

  defp session_too_old?(session) do
    case Map.get(session, :created_at) do
      nil ->
        true

      created_at ->
        # Consider sessions older than 24 hours as orphaned
        hours_old = DateTime.diff(UtilsDate.utc_now(), created_at, :hour)
        hours_old > 24
    end
  end
end
