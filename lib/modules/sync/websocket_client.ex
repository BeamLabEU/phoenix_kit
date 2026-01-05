defmodule PhoenixKit.Modules.Sync.WebSocketClient do
  @moduledoc """
  WebSocket client for Sync receiver connections.

  Uses WebSockex to connect from the receiver site to the sender's
  WebSocket endpoint. Sends requests and receives responses.

  ## Architecture

  The receiver uses this client to:
  1. Connect to the sender's hosted channel
  2. Send requests for data (tables, schema, records)
  3. Receive responses and notify the caller (LiveView)

  ## Usage

      {:ok, pid} = WebSocketClient.start_link(
        url: "https://sender-site.com",
        code: "ABC12345",
        caller: self()
      )

      # Request available tables
      WebSocketClient.request_tables(pid)
      # Receive: {:sync_client, {:tables, tables}}

      # Request records
      WebSocketClient.request_records(pid, "users", offset: 0, limit: 100)
      # Receive: {:sync_client, {:records, "users", result}}
  """

  use WebSockex
  require Logger

  @heartbeat_interval 30_000
  @join_timeout 10_000

  defstruct [
    :url,
    :code,
    :caller,
    :receiver_info,
    :ref_counter,
    :pending_refs,
    :joined,
    :heartbeat_ref
  ]

  # ===========================================
  # PUBLIC API
  # ===========================================

  @doc """
  Starts the WebSocket client and connects to the sender.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, any()}
  def start_link(opts) do
    url = Keyword.fetch!(opts, :url)
    code = Keyword.fetch!(opts, :code)
    caller = Keyword.fetch!(opts, :caller)
    receiver_info = Keyword.get(opts, :receiver_info, %{})

    ws_url = build_websocket_url(url, code)

    state = %__MODULE__{
      url: url,
      code: code,
      caller: caller,
      receiver_info: receiver_info,
      ref_counter: 0,
      pending_refs: %{},
      joined: false,
      heartbeat_ref: nil
    }

    WebSockex.start_link(ws_url, __MODULE__, state, [])
  end

  @doc """
  Disconnects the WebSocket client.
  """
  @spec disconnect(pid()) :: :ok
  def disconnect(pid) do
    WebSockex.cast(pid, :disconnect)
  end

  @doc """
  Request server capabilities.
  """
  @spec request_capabilities(pid()) :: :ok
  def request_capabilities(pid) do
    WebSockex.cast(pid, :request_capabilities)
  end

  @doc """
  Request list of available tables from sender.
  """
  @spec request_tables(pid()) :: :ok
  def request_tables(pid) do
    WebSockex.cast(pid, :request_tables)
  end

  @doc """
  Request schema for a specific table.
  """
  @spec request_schema(pid(), String.t()) :: :ok
  def request_schema(pid, table) do
    WebSockex.cast(pid, {:request_schema, table})
  end

  @doc """
  Request record count for a table.
  """
  @spec request_count(pid(), String.t()) :: :ok
  def request_count(pid, table) do
    WebSockex.cast(pid, {:request_count, table})
  end

  @doc """
  Request records from a table with pagination.
  """
  @spec request_records(pid(), String.t(), keyword()) :: :ok
  def request_records(pid, table, opts \\ []) do
    WebSockex.cast(pid, {:request_records, table, opts})
  end

  # ===========================================
  # WEBSOCKEX CALLBACKS
  # ===========================================

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("Sync.WebSocketClient: Connected to #{state.url}")

    # Join the transfer channel with receiver info
    join_payload = %{receiver_info: state.receiver_info}
    join_msg = encode_message("transfer:#{state.code}", "phx_join", join_payload, make_ref(state))
    WebSockex.cast(self(), {:send_raw, join_msg})

    # Start join timeout
    Process.send_after(self(), :join_timeout, @join_timeout)

    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, [_join_ref, ref, topic, event, payload]} ->
        handle_phoenix_message(topic, event, payload, ref, state)

      {:error, reason} ->
        Logger.warning("Sync.WebSocketClient: Failed to decode message: #{inspect(reason)}")
        {:ok, state}
    end
  end

  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:send_raw, msg}, state) do
    {:reply, {:text, msg}, state}
  end

  def handle_cast(:disconnect, state) do
    notify_caller(state, :disconnected)
    {:close, state}
  end

  def handle_cast(:request_capabilities, state) do
    if state.joined do
      {ref, state} = next_ref(state)
      msg = encode_message("transfer:#{state.code}", "request:capabilities", %{ref: ref}, ref)
      state = track_request(state, ref, :capabilities)
      {:reply, {:text, msg}, state}
    else
      Logger.warning("Sync.WebSocketClient: Cannot send request - not joined")
      {:ok, state}
    end
  end

  def handle_cast(:request_tables, state) do
    if state.joined do
      {ref, state} = next_ref(state)
      msg = encode_message("transfer:#{state.code}", "request:tables", %{ref: ref}, ref)
      state = track_request(state, ref, :tables)
      {:reply, {:text, msg}, state}
    else
      Logger.warning("Sync.WebSocketClient: Cannot send request - not joined")
      {:ok, state}
    end
  end

  def handle_cast({:request_schema, table}, state) do
    if state.joined do
      {ref, state} = next_ref(state)

      msg =
        encode_message("transfer:#{state.code}", "request:schema", %{table: table, ref: ref}, ref)

      state = track_request(state, ref, {:schema, table})
      {:reply, {:text, msg}, state}
    else
      Logger.warning("Sync.WebSocketClient: Cannot send request - not joined")
      {:ok, state}
    end
  end

  def handle_cast({:request_count, table}, state) do
    if state.joined do
      {ref, state} = next_ref(state)

      msg =
        encode_message("transfer:#{state.code}", "request:count", %{table: table, ref: ref}, ref)

      state = track_request(state, ref, {:count, table})
      {:reply, {:text, msg}, state}
    else
      Logger.warning("Sync.WebSocketClient: Cannot send request - not joined")
      {:ok, state}
    end
  end

  def handle_cast({:request_records, table, opts}, state) do
    if state.joined do
      {ref, state} = next_ref(state)
      offset = Keyword.get(opts, :offset, 0)
      limit = Keyword.get(opts, :limit, 100)

      msg =
        encode_message(
          "transfer:#{state.code}",
          "request:records",
          %{
            table: table,
            offset: offset,
            limit: limit,
            ref: ref
          },
          ref
        )

      state = track_request(state, ref, {:records, table})
      {:reply, {:text, msg}, state}
    else
      Logger.warning("Sync.WebSocketClient: Cannot send request - not joined")
      {:ok, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    if state.joined do
      {ref, state} = next_ref(state)
      msg = encode_message("phoenix", "heartbeat", %{}, ref)
      state = %{state | heartbeat_ref: ref}
      schedule_heartbeat()
      {:reply, {:text, msg}, state}
    else
      {:ok, state}
    end
  end

  def handle_info(:join_timeout, state) do
    if state.joined do
      {:ok, state}
    else
      Logger.warning("Sync.WebSocketClient: Join timeout")
      notify_caller(state, {:error, :join_timeout})
      {:close, state}
    end
  end

  def handle_info(_msg, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.info("Sync.WebSocketClient: Disconnected - #{inspect(reason)}")
    notify_caller(state, {:disconnected, reason})
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Sync.WebSocketClient: Terminating - #{inspect(reason)}")
    notify_caller(state, {:terminated, reason})
    :ok
  end

  # ===========================================
  # PHOENIX MESSAGE HANDLERS
  # ===========================================

  defp handle_phoenix_message(_topic, "phx_reply", %{"status" => "ok"} = payload, ref, state) do
    cond do
      # Join reply
      not state.joined and Map.get(payload, "response") == %{} ->
        Logger.info("Sync.WebSocketClient: Joined channel")
        state = %{state | joined: true}
        notify_caller(state, :connected)
        schedule_heartbeat()
        {:ok, state}

      # Heartbeat reply
      state.heartbeat_ref == ref ->
        {:ok, %{state | heartbeat_ref: nil}}

      true ->
        {:ok, state}
    end
  end

  defp handle_phoenix_message(_topic, "phx_reply", %{"status" => "error"} = payload, _ref, state) do
    Logger.warning("Sync.WebSocketClient: Error response - #{inspect(payload)}")
    notify_caller(state, {:error, payload})
    {:ok, state}
  end

  defp handle_phoenix_message(_topic, "phx_error", payload, _ref, state) do
    Logger.error("Sync.WebSocketClient: Channel error - #{inspect(payload)}")
    notify_caller(state, {:error, payload})
    {:ok, state}
  end

  defp handle_phoenix_message(_topic, "phx_close", _payload, _ref, state) do
    Logger.info("Sync.WebSocketClient: Channel closed by server")
    notify_caller(state, :channel_closed)
    {:close, state}
  end

  # Handle response messages from sender
  defp handle_phoenix_message(
         _topic,
         "response:capabilities",
         %{"capabilities" => caps, "ref" => ref},
         _msg_ref,
         state
       ) do
    Logger.debug("Sync.WebSocketClient: Received capabilities")
    {request_type, state} = pop_request(state, ref)

    if request_type == :capabilities do
      notify_caller(state, {:capabilities, caps})
    end

    {:ok, state}
  end

  defp handle_phoenix_message(
         _topic,
         "response:tables",
         %{"tables" => tables, "ref" => ref},
         _msg_ref,
         state
       ) do
    Logger.debug("Sync.WebSocketClient: Received #{length(tables)} tables")
    {request_type, state} = pop_request(state, ref)

    if request_type == :tables do
      notify_caller(state, {:tables, tables})
    end

    {:ok, state}
  end

  defp handle_phoenix_message(
         _topic,
         "response:schema",
         %{"schema" => schema, "ref" => ref},
         _msg_ref,
         state
       ) do
    Logger.info("Sync.WebSocketClient: Received schema response, ref: #{ref}")
    {request_type, state} = pop_request(state, ref)

    Logger.info("Sync.WebSocketClient: Request type for ref #{ref}: #{inspect(request_type)}")

    case request_type do
      {:schema, table} ->
        Logger.info("Sync.WebSocketClient: Notifying caller with schema for #{table}")
        notify_caller(state, {:schema, table, schema})

      other ->
        Logger.warning("Sync.WebSocketClient: Unexpected request type: #{inspect(other)}")
    end

    {:ok, state}
  end

  defp handle_phoenix_message(
         _topic,
         "response:count",
         %{"count" => count, "ref" => ref},
         _msg_ref,
         state
       ) do
    Logger.debug("Sync.WebSocketClient: Received count: #{count}")
    {request_type, state} = pop_request(state, ref)

    case request_type do
      {:count, table} -> notify_caller(state, {:count, table, count})
      _ -> :ok
    end

    {:ok, state}
  end

  defp handle_phoenix_message(_topic, "response:records", payload, _msg_ref, state) do
    records = Map.get(payload, "records", [])
    ref = Map.get(payload, "ref")
    offset = Map.get(payload, "offset", 0)
    has_more = Map.get(payload, "has_more", false)

    Logger.debug("Sync.WebSocketClient: Received #{length(records)} records")
    {request_type, state} = pop_request(state, ref)

    case request_type do
      {:records, table} ->
        result = %{records: records, offset: offset, has_more: has_more}
        notify_caller(state, {:records, table, result})

      _ ->
        :ok
    end

    {:ok, state}
  end

  defp handle_phoenix_message(
         _topic,
         "response:error",
         %{"error" => error, "ref" => ref},
         _msg_ref,
         state
       ) do
    Logger.warning("Sync.WebSocketClient: Error response - #{error}")
    {request_type, state} = pop_request(state, ref)
    notify_caller(state, {:request_error, request_type, error})
    {:ok, state}
  end

  defp handle_phoenix_message(topic, event, payload, _ref, state) do
    Logger.debug("Sync.WebSocketClient: Received #{event} on #{topic}: #{inspect(payload)}")
    notify_caller(state, {:message, event, payload})
    {:ok, state}
  end

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  defp build_websocket_url(base_url, code) do
    uri = URI.parse(base_url)

    scheme =
      case uri.scheme do
        "https" -> "wss"
        "http" -> "ws"
        "wss" -> "wss"
        "ws" -> "ws"
        _ -> "wss"
      end

    path =
      case uri.path do
        nil ->
          "/sync/websocket"

        "" ->
          "/sync/websocket"

        # If path already ends with /sync/websocket, use as-is
        # Otherwise append /sync/websocket to the prefix path
        p ->
          if String.ends_with?(p, "/sync/websocket") do
            p
          else
            "#{String.trim_trailing(p, "/")}/sync/websocket"
          end
      end

    query =
      case uri.query do
        nil -> "code=#{code}&vsn=2.0.0"
        q -> "#{q}&code=#{code}&vsn=2.0.0"
      end

    URI.to_string(%{uri | scheme: scheme, path: path, query: query})
  end

  defp encode_message(topic, event, payload, ref) do
    Jason.encode!([nil, ref, topic, event, payload])
  end

  defp next_ref(state) do
    ref = to_string(state.ref_counter + 1)
    {ref, %{state | ref_counter: state.ref_counter + 1}}
  end

  defp make_ref(%{ref_counter: counter}) do
    to_string(counter + 1)
  end

  defp track_request(state, ref, request_type) do
    pending = Map.put(state.pending_refs, ref, request_type)
    %{state | pending_refs: pending}
  end

  defp pop_request(state, ref) do
    {request_type, pending} = Map.pop(state.pending_refs, ref)
    {request_type, %{state | pending_refs: pending}}
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end

  defp notify_caller(%{caller: caller}, message) when is_pid(caller) do
    if Process.alive?(caller) do
      send(caller, {:sync_client, message})
    end
  end

  defp notify_caller(_, _), do: :ok
end
