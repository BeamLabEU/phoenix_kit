defmodule PhoenixKitWeb.SyncWebsock do
  @moduledoc """
  WebSock handler for DB Sync module.

  Uses WebSock directly (not Phoenix.Socket/Channel) to avoid
  cross-OTP-app channel supervision issues.

  ## Authentication Types

  Supports two authentication methods:

  1. **Session-based** (`:session`) - Ephemeral sessions for manual transfers
     - Uses 8-character session codes
     - Tied to sender's LiveView process

  2. **Connection-based** (`:connection`) - Permanent connections
     - Uses auth tokens stored in database
     - Subject to access controls (allowed tables, limits, etc.)

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

  alias PhoenixKit.Modules.Sync
  alias PhoenixKit.Modules.Sync.Connection
  alias PhoenixKit.Modules.Sync.Connections
  alias PhoenixKit.Modules.Sync.DataExporter
  alias PhoenixKit.Modules.Sync.SchemaInspector
  alias PhoenixKit.Modules.Sync.Transfers

  defstruct [
    :auth_type,
    :code,
    :session,
    :db_connection,
    :joined,
    :receiver_info,
    :connection_info
  ]

  # ===========================================
  # WEBSOCK CALLBACKS
  # ===========================================

  @impl WebSock
  def init(opts) do
    auth_type = Keyword.get(opts, :auth_type, :session)
    connection_info = Keyword.get(opts, :connection_info, %{})

    state =
      case auth_type do
        :session ->
          code = Keyword.get(opts, :code)
          session = Keyword.get(opts, :session)

          Logger.info("Sync.Websock: Session connection initialized for code #{code}")

          %__MODULE__{
            auth_type: :session,
            code: code,
            session: session,
            db_connection: nil,
            joined: false,
            connection_info: connection_info
          }

        :connection ->
          db_connection = Keyword.get(opts, :connection)

          Logger.info("Sync.Websock: Token connection initialized for #{db_connection.name}")

          %__MODULE__{
            auth_type: :connection,
            code: "conn:#{db_connection.id}",
            session: nil,
            db_connection: db_connection,
            joined: false,
            connection_info: connection_info
          }
      end

    {:ok, state}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, [join_ref, ref, topic, event, payload]} ->
        handle_message(join_ref, ref, topic, event, payload, state)

      {:error, reason} ->
        Logger.warning("Sync.Websock: Failed to decode message: #{inspect(reason)}")
        {:ok, state}
    end
  end

  def handle_in({_data, [opcode: :binary]}, state) do
    # Ignore binary messages
    {:ok, state}
  end

  @impl WebSock
  def handle_info({:sync, message}, state) do
    # Handle messages from LiveView or other processes
    Logger.debug("Sync.Websock: Received internal message: #{inspect(message)}")
    {:ok, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Sync.Websock: Unknown info message: #{inspect(msg)}")
    {:ok, state}
  end

  @impl WebSock
  def terminate(reason, state) do
    Logger.info("Sync.Websock: Terminated for code #{state.code}, reason: #{inspect(reason)}")

    # Notify sender's LiveView that receiver disconnected
    if state.session && state.session[:owner_pid] do
      send(state.session.owner_pid, {:sync, :receiver_disconnected})
    end

    :ok
  end

  # ===========================================
  # MESSAGE HANDLERS
  # ===========================================

  # Handle join message
  defp handle_message(_join_ref, ref, "transfer:" <> code, "phx_join", payload, state) do
    if code == state.code do
      Logger.info("Sync.Websock: Receiver joined for code #{code}")

      # Extract receiver info from join payload
      receiver_info = get_in(payload, ["receiver_info"]) || %{}

      # Merge connection_info (from HTTP upgrade) with receiver_info (from join payload)
      full_connection_info = %{
        receiver_info: receiver_info,
        connection_info: state.connection_info
      }

      # Update session with connection info
      Sync.update_session(code, %{
        channel_pid: self(),
        receiver_info: receiver_info,
        connection_info: state.connection_info
      })

      # Notify sender's LiveView with full connection details
      if state.session[:owner_pid] do
        send(
          state.session.owner_pid,
          {:sync, {:receiver_joined, self(), full_connection_info}}
        )
      end

      state = %{state | joined: true, receiver_info: receiver_info}

      reply =
        encode_reply(ref, "transfer:#{code}", "phx_reply", %{"status" => "ok", "response" => %{}})

      {:push, {:text, reply}, state}
    else
      Logger.warning("Sync.Websock: Code mismatch - expected #{state.code}, got #{code}")

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
      Logger.debug("Sync.Websock: Capabilities requested")

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
      Logger.debug("Sync.Websock: Tables requested")

      response =
        case SchemaInspector.list_tables() do
          {:ok, tables} ->
            # Filter tables based on connection settings for permanent connections
            filtered_tables = filter_allowed_tables(tables, state)

            encode_push("transfer:#{state.code}", "response:tables", %{
              "tables" => filtered_tables,
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
      Logger.debug("Sync.Websock: Schema requested for #{table}")

      # Check table access for permanent connections
      response =
        if table_allowed?(table, state) do
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
        else
          encode_push("transfer:#{state.code}", "response:error", %{
            "error" => "Access denied to table: #{table}",
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
      Logger.debug("Sync.Websock: Count requested for #{table}")

      response =
        if table_allowed?(table, state) do
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
        else
          encode_push("transfer:#{state.code}", "response:error", %{
            "error" => "Access denied to table: #{table}",
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

      # Apply connection's max_records_per_request limit
      effective_limit = get_effective_limit(limit, state)

      Logger.debug(
        "Sync.Websock: Records requested for #{table} (offset: #{offset}, limit: #{effective_limit})"
      )

      response = fetch_and_respond_records(table, offset, effective_limit, client_ref, state)

      {:push, {:text, response}, state}
    else
      {:ok, state}
    end
  end

  # Catch-all for unknown messages
  defp handle_message(_join_ref, _ref, topic, event, payload, state) do
    Logger.warning(
      "Sync.Websock: Unknown message - topic: #{topic}, event: #{event}, payload: #{inspect(payload)}"
    )

    {:ok, state}
  end

  # ===========================================
  # RECORDS FETCHING HELPER
  # ===========================================

  defp fetch_and_respond_records(table, offset, limit, client_ref, state) do
    if table_allowed?(table, state) do
      fetch_records_for_table(table, offset, limit, client_ref, state)
    else
      encode_push("transfer:#{state.code}", "response:error", %{
        "error" => "Access denied to table: #{table}",
        "ref" => client_ref
      })
    end
  end

  defp fetch_records_for_table(table, offset, limit, client_ref, state) do
    case DataExporter.fetch_records(table, offset: offset, limit: limit) do
      {:ok, records} ->
        records_count = Enum.count(records)

        # Track transfer for permanent connections
        if state.auth_type == :connection && records_count > 0 do
          track_transfer(state.db_connection, table, records_count, state.connection_info)
        end

        encode_push("transfer:#{state.code}", "response:records", %{
          "records" => records,
          "offset" => offset,
          "has_more" => records_count == limit,
          "ref" => client_ref
        })

      {:error, reason} ->
        encode_push("transfer:#{state.code}", "response:error", %{
          "error" => "Failed to fetch records: #{inspect(reason)}",
          "ref" => client_ref
        })
    end
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

  # ===========================================
  # ACCESS CONTROL HELPERS
  # ===========================================

  # Filter tables based on connection settings for permanent connections
  defp filter_allowed_tables(tables, %{auth_type: :session}), do: tables

  defp filter_allowed_tables(tables, %{auth_type: :connection, db_connection: conn}) do
    Enum.filter(tables, fn table ->
      table_name = if is_map(table), do: table["name"] || table[:name], else: table
      Connection.table_allowed?(conn, table_name)
    end)
  end

  # Check if a specific table is allowed for this connection
  defp table_allowed?(_table, %{auth_type: :session}), do: true

  defp table_allowed?(table, %{auth_type: :connection, db_connection: conn}) do
    Connection.table_allowed?(conn, table)
  end

  # Get the effective limit considering connection's max_records_per_request
  defp get_effective_limit(requested_limit, %{auth_type: :session}), do: requested_limit

  defp get_effective_limit(requested_limit, %{auth_type: :connection, db_connection: conn}) do
    max_per_request = conn.max_records_per_request || 10_000
    min(requested_limit, max_per_request)
  end

  # Track transfer for permanent connections
  defp track_transfer(db_connection, table_name, records_count, connection_info) do
    # Create a transfer record
    attrs = %{
      direction: "send",
      connection_id: db_connection.id,
      connection_uuid: db_connection.uuid,
      table_name: table_name,
      records_requested: records_count,
      records_transferred: records_count,
      records_created: records_count,
      status: "completed",
      requester_ip: Map.get(connection_info, :remote_ip),
      requester_user_agent: Map.get(connection_info, :user_agent)
    }

    case Transfers.create_transfer(attrs) do
      {:ok, transfer} ->
        # Update the transfer to completed immediately (single batch transfer)
        Transfers.complete_transfer(transfer, %{
          records_transferred: records_count,
          records_created: records_count
        })

        # Update connection statistics
        Connections.record_transfer(db_connection, %{
          records_count: records_count,
          bytes_count: 0
        })

      {:error, _changeset} ->
        Logger.warning("Sync.Websock: Failed to track transfer for #{table_name}")
    end
  end
end
