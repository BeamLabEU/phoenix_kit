defmodule PhoenixKitWeb.SyncChannel do
  @moduledoc """
  Channel for DB Sync protocol messages.

  Handles communication between sender and receiver sites during
  a data sync session.

  ## Architecture

  The SENDER site hosts this channel (has data to share).
  The RECEIVER connects via WebSocket to pull data.

  **Data Flow:**
  1. Receiver's WebSocketClient connects to this channel
  2. Receiver sends requests (e.g., "request:tables")
  3. Channel handles request by querying local database
  4. Channel sends response back to Receiver

  ## Protocol Messages

  ### From Receiver (requests)
  - `request:capabilities` - Get server capabilities/version
  - `request:tables` - Request list of available tables
  - `request:schema` - Request table schema
  - `request:count` - Request record count for table
  - `request:records` - Request paginated records

  ### To Receiver (responses)
  - `response:capabilities` - Server capabilities
  - `response:tables` - List of available tables
  - `response:schema` - Table schema details
  - `response:count` - Record count
  - `response:records` - Paginated records
  - `response:error` - Error response
  """

  use Phoenix.Channel
  require Logger

  alias PhoenixKit.Sync
  alias PhoenixKit.Sync.DataExporter
  alias PhoenixKit.Sync.SchemaInspector

  @impl true
  def join("transfer:" <> code, _params, socket) do
    # Verify the code matches the socket's session
    if socket.assigns.session_code == code do
      # Update session with channel PID so sender's LiveView can track
      Sync.update_session(code, %{channel_pid: self()})

      # Notify the sender's LiveView that a receiver has joined
      send_to_sender(socket.assigns.session, {:receiver_joined, self()})

      Logger.info("Sync: Receiver joined channel for code #{code}")
      {:ok, socket}
    else
      Logger.warning(
        "Sync: Channel join mismatch - expected #{socket.assigns.session_code}, got #{code}"
      )

      {:error, %{reason: "code_mismatch"}}
    end
  end

  # ===========================================
  # INCOMING REQUESTS FROM RECEIVER
  # ===========================================

  @impl true
  def handle_in("request:capabilities", %{"ref" => ref}, socket) do
    Logger.debug("Sync.Channel: Capabilities requested")

    capabilities = %{
      version: "1.0.0",
      phoenix_kit_version: Application.spec(:phoenix_kit, :vsn) |> to_string(),
      features: ["list_tables", "get_schema", "fetch_records"]
    }

    push(socket, "response:capabilities", %{capabilities: capabilities, ref: ref})
    {:noreply, socket}
  end

  def handle_in("request:tables", %{"ref" => ref}, socket) do
    Logger.debug("Sync.Channel: Tables requested")

    case SchemaInspector.list_tables() do
      {:ok, tables} ->
        push(socket, "response:tables", %{tables: tables, ref: ref})

      {:error, reason} ->
        push(socket, "response:error", %{
          error: "Failed to list tables: #{inspect(reason)}",
          ref: ref
        })
    end

    {:noreply, socket}
  end

  def handle_in("request:schema", %{"table" => table, "ref" => ref}, socket) do
    Logger.info("Sync.Channel: Schema requested for #{table}")

    case SchemaInspector.get_schema(table) do
      {:ok, schema} ->
        Logger.info(
          "Sync.Channel: Schema found for #{table}, columns: #{length(schema.columns)}"
        )

        push(socket, "response:schema", %{schema: schema, ref: ref})

      {:error, :not_found} ->
        Logger.warning("Sync.Channel: Table not found: #{table}")
        push(socket, "response:error", %{error: "Table not found: #{table}", ref: ref})

      {:error, reason} ->
        Logger.error("Sync.Channel: Failed to get schema for #{table}: #{inspect(reason)}")

        push(socket, "response:error", %{
          error: "Failed to get schema: #{inspect(reason)}",
          ref: ref
        })
    end

    {:noreply, socket}
  end

  def handle_in("request:count", %{"table" => table, "ref" => ref}, socket) do
    Logger.debug("Sync.Channel: Count requested for #{table}")

    case DataExporter.get_count(table) do
      {:ok, count} ->
        push(socket, "response:count", %{count: count, ref: ref})

      {:error, reason} ->
        push(socket, "response:error", %{
          error: "Failed to get count: #{inspect(reason)}",
          ref: ref
        })
    end

    {:noreply, socket}
  end

  def handle_in("request:records", payload, socket) do
    table = Map.fetch!(payload, "table")
    ref = Map.fetch!(payload, "ref")
    offset = Map.get(payload, "offset", 0)
    limit = Map.get(payload, "limit", 100)

    Logger.debug(
      "Sync.Channel: Records requested for #{table} (offset: #{offset}, limit: #{limit})"
    )

    case DataExporter.fetch_records(table, offset: offset, limit: limit) do
      {:ok, records} ->
        push(socket, "response:records", %{
          records: records,
          offset: offset,
          has_more: length(records) == limit,
          ref: ref
        })

      {:error, reason} ->
        push(socket, "response:error", %{
          error: "Failed to fetch records: #{inspect(reason)}",
          ref: ref
        })
    end

    {:noreply, socket}
  end

  def handle_in(event, payload, socket) do
    Logger.warning("Sync: Unknown event #{event} with payload #{inspect(payload)}")
    {:reply, {:error, %{message: "Unknown event: #{event}"}}, socket}
  end

  # ===========================================
  # HANDLE INFO (from Sender's LiveView)
  # ===========================================

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ===========================================
  # TERMINATE
  # ===========================================

  @impl true
  def terminate(reason, socket) do
    Logger.info(
      "Sync: Channel terminated for code #{socket.assigns.session_code}, reason: #{inspect(reason)}"
    )

    # Notify the sender's LiveView that receiver has disconnected (with PID for multi-receiver support)
    send_to_sender(socket.assigns.session, {:receiver_disconnected, self()})

    :ok
  end

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  defp send_to_sender(%{owner_pid: pid}, message) when is_pid(pid) do
    if Process.alive?(pid) do
      send(pid, {:sync, message})
    end
  end

  defp send_to_sender(_session, _message), do: :ok
end
