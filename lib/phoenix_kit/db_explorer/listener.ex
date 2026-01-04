defmodule PhoenixKit.DBExplorer.Listener do
  @moduledoc """
  GenServer that listens for PostgreSQL NOTIFY events for live table updates.

  This process uses Postgrex to establish a separate connection to PostgreSQL
  and listens for notifications on the `phoenix_kit_db_changes` channel.

  When a notification is received, it broadcasts via PubSub so LiveViews can
  update in real-time.

  ## Usage

  Since PhoenixKit is a library, the Listener is started lazily on first use.
  Call `ensure_started/0` before subscribing, or use the subscribe functions
  which will ensure it's started automatically.
  """

  use GenServer

  require Logger

  @channel "phoenix_kit_db_changes"

  # Client API

  @doc """
  Starts the listener process.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensures the Listener is started. Called automatically by subscribe functions.

  The Listener is normally started by PhoenixKit.Supervisor. This function
  is a safety check that logs a warning if the Listener isn't running.

  Returns `:ok` if running, or `:ok` with a warning log if not (subscriptions
  will still work but won't receive notifications until the Listener starts).
  """
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        Logger.warning(
          "DBExplorer.Listener is not running. Live updates will not work. " <>
            "Ensure PhoenixKit.Supervisor is started."
        )

        :ok

      _pid ->
        :ok
    end
  end

  @doc """
  Subscribe to changes for a specific table.
  """
  def subscribe(schema, table) do
    ensure_started()
    PhoenixKit.PubSub.Manager.subscribe(topic(schema, table))
  end

  @doc """
  Unsubscribe from changes for a specific table.
  """
  def unsubscribe(schema, table) do
    PhoenixKit.PubSub.Manager.unsubscribe(topic(schema, table))
  end

  @doc """
  Subscribe to all table changes (for the index page).
  """
  def subscribe_all do
    ensure_started()
    PhoenixKit.PubSub.Manager.subscribe("db_explorer:all")
  end

  @doc """
  Unsubscribe from all table changes.
  """
  def unsubscribe_all do
    PhoenixKit.PubSub.Manager.unsubscribe("db_explorer:all")
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    case get_connection_config() do
      {:ok, config} ->
        case Postgrex.Notifications.start_link(config) do
          {:ok, pid} ->
            case Postgrex.Notifications.listen(pid, @channel) do
              {:ok, _ref} ->
                {:ok, %{conn: pid}}

              {:error, reason} ->
                Logger.warning("DBExplorer.Listener failed to LISTEN: #{inspect(reason)}")
                {:ok, %{conn: nil}}
            end

          {:error, reason} ->
            Logger.warning("DBExplorer.Listener failed to connect: #{inspect(reason)}")
            {:ok, %{conn: nil}}
        end

      {:error, reason} ->
        Logger.warning("DBExplorer.Listener could not get DB config: #{inspect(reason)}")
        {:ok, %{conn: nil}}
    end
  end

  @impl true
  def handle_info({:notification, _conn, _ref, @channel, payload}, state) do
    # Payload format: "schema.table:OPERATION" (e.g., "public.users:INSERT")
    case parse_payload(payload) do
      {schema, table, operation} ->
        Logger.info("DBExplorer: #{schema}.#{table} - #{operation}")

        # Broadcast to specific table subscribers
        PhoenixKit.PubSub.Manager.broadcast(
          topic(schema, table),
          {:table_changed, schema, table, operation}
        )

        # Broadcast to "all tables" subscribers (for index page)
        PhoenixKit.PubSub.Manager.broadcast(
          "db_explorer:all",
          {:table_changed, schema, table, operation}
        )

      :error ->
        Logger.warning("DBExplorer: Invalid notification payload: #{payload}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp parse_payload(payload) do
    case String.split(payload, ":") do
      [table_part, operation] ->
        case String.split(table_part, ".", parts: 2) do
          [schema, table] -> {schema, table, operation}
          _ -> :error
        end

      # Legacy format without operation (backwards compat)
      [table_part] ->
        case String.split(table_part, ".", parts: 2) do
          [schema, table] -> {schema, table, "UNKNOWN"}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn}) when is_pid(conn) do
    Postgrex.Notifications.unlisten(conn, @channel)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Private functions

  defp topic(schema, table), do: "db_explorer:#{schema}.#{table}"

  defp get_connection_config do
    case PhoenixKit.RepoHelper.repo() do
      nil ->
        {:error, :no_repo}

      repo ->
        config = repo.config()

        # Build Postgrex-compatible config
        # Include socket/socket_dir for local connections, and SSL options
        postgrex_config =
          config
          |> Keyword.take([
            :hostname,
            :port,
            :database,
            :username,
            :password,
            :socket,
            :socket_dir,
            :ssl,
            :ssl_opts
          ])
          |> Keyword.put_new(:hostname, "localhost")
          |> Keyword.put_new(:port, 5432)
          # Auto-reconnect if connection drops
          |> Keyword.put(:auto_reconnect, true)

        {:ok, postgrex_config}
    end
  rescue
    e ->
      Logger.error("DBExplorer.Listener failed to get connection config: #{inspect(e)}")
      {:error, e}
  end
end
