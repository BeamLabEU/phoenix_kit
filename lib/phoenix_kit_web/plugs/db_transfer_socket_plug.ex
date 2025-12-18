defmodule PhoenixKitWeb.Plugs.DBTransferSocketPlug do
  @moduledoc """
  Plug for handling DB Transfer WebSocket connections.

  This plug handles the HTTP upgrade to WebSocket and validates
  the connection code before handing off to DBTransferWebsock.

  ## Usage

  In your endpoint:

      plug PhoenixKitWeb.Plugs.DBTransferSocketPlug

  Or mount at a specific path in router (done automatically by phoenix_kit_socket macro).
  """

  @behaviour Plug
  require Logger

  alias PhoenixKit.DBTransfer

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{request_path: "/db-transfer/websocket"} = conn, _opts) do
    handle_websocket_request(conn)
  end

  def call(conn, _opts) do
    conn
  end

  defp handle_websocket_request(conn) do
    # Check if this is a WebSocket upgrade request
    if websocket_request?(conn) do
      code = get_code_from_params(conn)

      if DBTransfer.enabled?() do
        case validate_and_upgrade(conn, code) do
          {:ok, conn} -> conn
          {:error, conn} -> conn
        end
      else
        Logger.warning("DBTransfer: Connection attempt but module is disabled")
        send_forbidden(conn, "Module disabled")
      end
    else
      send_bad_request(conn, "Expected WebSocket upgrade")
    end
  end

  defp websocket_request?(conn) do
    upgrade_header =
      Plug.Conn.get_req_header(conn, "upgrade")
      |> List.first()
      |> Kernel.||("")
      |> String.downcase()

    upgrade_header == "websocket"
  end

  defp get_code_from_params(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    conn.query_params["code"]
  end

  defp validate_and_upgrade(conn, nil) do
    Logger.warning("DBTransfer: Connection attempt without code")
    {:error, send_forbidden(conn, "Missing code")}
  end

  defp validate_and_upgrade(conn, code) do
    case DBTransfer.validate_code(code) do
      {:ok, session} ->
        Logger.info("DBTransfer: Sender connecting with code #{code}")

        # Capture connection metadata
        connection_info = extract_connection_info(conn)

        conn =
          WebSockAdapter.upgrade(
            conn,
            PhoenixKitWeb.DBTransferWebsock,
            [code: code, session: session, connection_info: connection_info],
            timeout: 60_000
          )

        {:ok, Plug.Conn.halt(conn)}

      {:error, :invalid_code} ->
        Logger.warning("DBTransfer: Invalid code attempt: #{code}")
        {:error, send_forbidden(conn, "Invalid code")}

      {:error, :already_used} ->
        Logger.warning("DBTransfer: Code already used: #{code}")
        {:error, send_forbidden(conn, "Code already used")}
    end
  end

  defp extract_connection_info(conn) do
    # Get remote IP - check for forwarded headers first (for proxies)
    remote_ip = get_remote_ip(conn)

    # Get user agent
    user_agent =
      Plug.Conn.get_req_header(conn, "user-agent")
      |> List.first()

    # Get origin/referer
    origin =
      Plug.Conn.get_req_header(conn, "origin")
      |> List.first()

    referer =
      Plug.Conn.get_req_header(conn, "referer")
      |> List.first()

    # Get host info
    host = conn.host
    port = conn.port
    scheme = if conn.scheme == :https, do: "https", else: "http"

    # Get WebSocket protocol version
    ws_version =
      Plug.Conn.get_req_header(conn, "sec-websocket-version")
      |> List.first()

    # Get accept-language for locale info
    accept_language =
      Plug.Conn.get_req_header(conn, "accept-language")
      |> List.first()

    %{
      remote_ip: remote_ip,
      user_agent: user_agent,
      origin: origin,
      referer: referer,
      host: host,
      port: port,
      scheme: scheme,
      request_path: conn.request_path,
      query_string: conn.query_string,
      websocket_version: ws_version,
      accept_language: accept_language,
      connected_at: DateTime.utc_now()
    }
  end

  defp get_remote_ip(conn) do
    # Check X-Forwarded-For first (for load balancers/proxies)
    forwarded_for =
      Plug.Conn.get_req_header(conn, "x-forwarded-for")
      |> List.first()

    cond do
      forwarded_for ->
        # Take the first IP in the chain (original client)
        forwarded_for
        |> String.split(",")
        |> List.first()
        |> String.trim()

      true ->
        # Fall back to direct connection IP
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  defp send_forbidden(conn, message) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(403, message)
    |> Plug.Conn.halt()
  end

  defp send_bad_request(conn, message) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(400, message)
    |> Plug.Conn.halt()
  end
end
