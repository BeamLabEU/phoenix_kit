defmodule PhoenixKitWeb.DBSyncWebsock do
  @moduledoc """
  WebSock handler for DB Sync module.

  Uses WebSock directly (not Phoenix.Socket/Channel) to avoid
  cross-OTP-app channel supervision issues.

  ## How it works

  This is a simple WebSocket handler that processes JSON messages directly.
  The Receiver connects with a code, and can then request data from the Sender.

  ## Message Protocol

  All messages are JSON arrays in Phoenix channel format:
  `[join_ref, ref, topic, event, payload]`

  Supported events:
  - `phx_join` - Join the transfer session
  - `request:capabilities` - Get server capabilities
  - `request:tables` - List available tables
  - `request:schema` - Get table schema
  - `request:count` - Get record count
  - `request:records` - Fetch records with pagination
  """

  @behaviour WebSock
  require Logger

  alias PhoenixKit.DBSync
  alias PhoenixKit.DBSync.DataExporter
  alias PhoenixKit.DBSync.SchemaInspector

  defstruct [:code, :session, :joined, :receiver_info, :connection_info]

  # ===========================================
  # WEBSOCK CALLBACKS
  # ===========================================

  @impl WebSock
  def init(opts) do
    code = Keyword.get(opts, :code)
    session = Keyword.get(opts, :session)
    connection_info = Keyword.get(opts, :connection_info, %{})

    state = %__MODULE__{
      code: code,
      session: session,
      joined: false,
      connection_info: connection_info
    }

    Logger.info("DBSync.Websock: Connection initialized for code #{code}")
    {:ok, state}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, [join_ref, ref, topic, event, payload]} ->
        handle_message(join_ref, ref, topic, event, payload, state)

      {:error, reason} ->
        Logger.warning("DBSync.Websock: Failed to decode message: #{inspect(reason)}")
        {:ok, state}
    end
  end

  def handle_in({_data, [opcode: :binary]}, state) do
    # Ignore binary messages
    {:ok, state}
  end

  @impl WebSock
  def handle_info({:db_sync, message}, state) do
    # Handle messages from LiveView or other processes
    Logger.debug("DBSync.Websock: Received internal message: #{inspect(message)}")
    {:ok, state}
  end

  def handle_info(msg, state) do
    Logger.debug("DBSync.Websock: Unknown info message: #{inspect(msg)}")
    {:ok, state}
  end

  @impl WebSock
  def terminate(reason, state) do
    Logger.info("DBSync.Websock: Terminated for code #{state.code}, reason: #{inspect(reason)}")

    # Notify sender's LiveView that receiver disconnected
    if state.session && state.session[:owner_pid] do
      send(state.session.owner_pid, {:db_sync, :receiver_disconnected})
    end

    :ok
  end

  # ===========================================
  # MESSAGE HANDLERS
  # ===========================================

  # Handle join message
  defp handle_message(_join_ref, ref, "transfer:" <> code, "phx_join", payload, state) do
    if code == state.code do
      Logger.info("DBSync.Websock: Receiver joined for code #{code}")

      # Extract receiver info from join payload
      receiver_info = get_in(payload, ["receiver_info"]) || %{}

      # Merge connection_info (from HTTP upgrade) with receiver_info (from join payload)
      full_connection_info = %{
        receiver_info: receiver_info,
        connection_info: state.connection_info
      }

      # Update session with connection info
      DBSync.update_session(code, %{
        channel_pid: self(),
        receiver_info: receiver_info,
        connection_info: state.connection_info
      })

      # Notify sender's LiveView with full connection details
      if state.session[:owner_pid] do
        send(
          state.session.owner_pid,
          {:db_sync, {:receiver_joined, self(), full_connection_info}}
        )
      end

      state = %{state | joined: true, receiver_info: receiver_info}

      reply =
        encode_reply(ref, "transfer:#{code}", "phx_reply", %{"status" => "ok", "response" => %{}})

      {:push, {:text, reply}, state}
    else
      Logger.warning("DBSync.Websock: Code mismatch - expected #{state.code}, got #{code}")

      reply =
        encode_reply(ref, "transfer:#{code}", "phx_reply", %{
          "status" => "error",
          "response" => %{"reason" => "code_mismatch"}
        })

      {:push, {:text, reply}, state}
    end
  end

  # Handle heartbeat
  defp handle_message(_join_ref, ref, "phoenix", "heartbeat", _payload, state) do
    reply = encode_reply(ref, "phoenix", "phx_reply", %{"status" => "ok", "response" => %{}})
    {:push, {:text, reply}, state}
  end

  # Handle capabilities request
  defp handle_message(
         _join_ref,
         _ref,
         _topic,
         "request:capabilities",
         %{"ref" => client_ref},
         state
       ) do
    if state.joined do
      Logger.debug("DBSync.Websock: Capabilities requested")

      capabilities = %{
        "version" => "1.0.0",
        "phoenix_kit_version" => Application.spec(:phoenix_kit, :vsn) |> to_string(),
        "features" => ["list_tables", "get_schema", "fetch_records"]
      }

      response =
        encode_push("transfer:#{state.code}", "response:capabilities", %{
          "capabilities" => capabilities,
          "ref" => client_ref
        })

      {:push, {:text, response}, state}
    else
      {:ok, state}
    end
  end

  # Handle tables request
  defp handle_message(_join_ref, _ref, _topic, "request:tables", %{"ref" => client_ref}, state) do
    if state.joined do
      Logger.debug("DBSync.Websock: Tables requested")

      response =
        case SchemaInspector.list_tables() do
          {:ok, tables} ->
            encode_push("transfer:#{state.code}", "response:tables", %{
              "tables" => tables,
              "ref" => client_ref
            })

          {:error, reason} ->
            encode_push("transfer:#{state.code}", "response:error", %{
              "error" => "Failed to list tables: #{inspect(reason)}",
              "ref" => client_ref
            })
        end

      {:push, {:text, response}, state}
    else
      {:ok, state}
    end
  end

  # Handle schema request
  defp handle_message(
         _join_ref,
         _ref,
         _topic,
         "request:schema",
         %{"table" => table, "ref" => client_ref},
         state
       ) do
    if state.joined do
      Logger.debug("DBSync.Websock: Schema requested for #{table}")

      response =
        case SchemaInspector.get_schema(table) do
          {:ok, schema} ->
            encode_push("transfer:#{state.code}", "response:schema", %{
              "schema" => schema,
              "ref" => client_ref
            })

          {:error, :not_found} ->
            encode_push("transfer:#{state.code}", "response:error", %{
              "error" => "Table not found: #{table}",
              "ref" => client_ref
            })

          {:error, reason} ->
            encode_push("transfer:#{state.code}", "response:error", %{
              "error" => "Failed to get schema: #{inspect(reason)}",
              "ref" => client_ref
            })
        end

      {:push, {:text, response}, state}
    else
      {:ok, state}
    end
  end

  # Handle count request
  defp handle_message(
         _join_ref,
         _ref,
         _topic,
         "request:count",
         %{"table" => table, "ref" => client_ref},
         state
       ) do
    if state.joined do
      Logger.debug("DBSync.Websock: Count requested for #{table}")

      response =
        case DataExporter.get_count(table) do
          {:ok, count} ->
            encode_push("transfer:#{state.code}", "response:count", %{
              "count" => count,
              "ref" => client_ref
            })

          {:error, reason} ->
            encode_push("transfer:#{state.code}", "response:error", %{
              "error" => "Failed to get count: #{inspect(reason)}",
              "ref" => client_ref
            })
        end

      {:push, {:text, response}, state}
    else
      {:ok, state}
    end
  end

  # Handle records request
  defp handle_message(_join_ref, _ref, _topic, "request:records", payload, state) do
    if state.joined do
      table = Map.fetch!(payload, "table")
      client_ref = Map.fetch!(payload, "ref")
      offset = Map.get(payload, "offset", 0)
      limit = Map.get(payload, "limit", 100)

      Logger.debug(
        "DBSync.Websock: Records requested for #{table} (offset: #{offset}, limit: #{limit})"
      )

      response =
        case DataExporter.fetch_records(table, offset: offset, limit: limit) do
          {:ok, records} ->
            encode_push("transfer:#{state.code}", "response:records", %{
              "records" => records,
              "offset" => offset,
              "has_more" => length(records) == limit,
              "ref" => client_ref
            })

          {:error, reason} ->
            encode_push("transfer:#{state.code}", "response:error", %{
              "error" => "Failed to fetch records: #{inspect(reason)}",
              "ref" => client_ref
            })
        end

      {:push, {:text, response}, state}
    else
      {:ok, state}
    end
  end

  # Catch-all for unknown messages
  defp handle_message(_join_ref, _ref, topic, event, payload, state) do
    Logger.warning(
      "DBSync.Websock: Unknown message - topic: #{topic}, event: #{event}, payload: #{inspect(payload)}"
    )

    {:ok, state}
  end

  # ===========================================
  # ENCODING HELPERS
  # ===========================================

  defp encode_reply(ref, topic, event, payload) do
    Jason.encode!([nil, ref, topic, event, payload])
  end

  defp encode_push(topic, event, payload) do
    Jason.encode!([nil, nil, topic, event, payload])
  end
end
