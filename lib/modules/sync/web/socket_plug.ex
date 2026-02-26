defmodule PhoenixKit.Modules.Sync.Web.SocketPlug do
  @moduledoc """
  Plug for handling DB Sync WebSocket connections.

  This plug handles the HTTP upgrade to WebSocket and validates
  the connection code or auth token before handing off to SyncWebsock.

  ## Authentication Methods

  Supports two authentication methods:

  1. **Session Code** (ephemeral) - For manual one-time transfers
     - Query param: `?code=ABC12345`
     - Session is tied to LiveView process

  2. **Connection Token** (permanent) - For persistent connections
     - Query param: `?token=xyz123...`
     - Validated against database, subject to access controls

  ## Usage

  In your endpoint:

      plug PhoenixKit.Modules.Sync.Web.SocketPlug

  Or mount at a specific path in router (done automatically by phoenix_kit_socket macro).
  """

  @behaviour Plug
  require Logger

  alias PhoenixKit.Modules.Sync
  alias PhoenixKit.Modules.Sync.Connections

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # When used with forward in router, the path is stripped to "/"
    # When used directly in endpoint (deprecated), check if path ends with /sync/websocket
    cond do
      conn.request_path == "/" ->
        # Forwarded from router - handle the request
        handle_websocket_request(conn)

      String.ends_with?(conn.request_path, "/sync/websocket") ->
        # Direct endpoint use (deprecated) - still handle for backwards compatibility
        handle_websocket_request(conn)

      true ->
        # Not a sync websocket request - pass through
        conn
    end
  end

  defp handle_websocket_request(conn) do
    # Check if this is a WebSocket upgrade request
    if websocket_request?(conn) do
      if Sync.enabled?() do
        conn = Plug.Conn.fetch_query_params(conn)
        code = conn.query_params["code"]
        token = conn.query_params["token"]

        cond do
          # Permanent connection token authentication
          token != nil ->
            validate_token_and_upgrade(conn, token)

          # Ephemeral session code authentication
          code != nil ->
            validate_code_and_upgrade(conn, code)

          # No authentication provided
          true ->
            Logger.warning("Sync: Connection attempt without code or token")
            send_forbidden(conn, "Missing authentication")
        end
      else
        Logger.warning("Sync: Connection attempt but module is disabled")
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

  # ===========================================
  # SESSION CODE AUTHENTICATION (EPHEMERAL)
  # ===========================================

  defp validate_code_and_upgrade(conn, code) do
    case Sync.validate_code(code) do
      {:ok, session} ->
        Logger.info("Sync: Receiver connecting with code #{code}")

        # Capture connection metadata
        connection_info = extract_connection_info(conn)

        conn =
          WebSockAdapter.upgrade(
            conn,
            PhoenixKitWeb.SyncWebsock,
            [
              auth_type: :session,
              code: code,
              session: session,
              connection_info: connection_info
            ],
            timeout: 60_000
          )

        Plug.Conn.halt(conn)

      {:error, :invalid_code} ->
        Logger.warning("Sync: Invalid code attempt: #{code}")
        send_forbidden(conn, "Invalid code")

      {:error, :already_used} ->
        Logger.warning("Sync: Code already used: #{code}")
        send_forbidden(conn, "Code already used")
    end
  end

  # ===========================================
  # CONNECTION TOKEN AUTHENTICATION (PERMANENT)
  # ===========================================

  defp validate_token_and_upgrade(conn, token) do
    # Extract client IP for validation
    client_ip = get_remote_ip(conn)

    case Connections.validate_connection(token, client_ip) do
      {:ok, db_connection} ->
        # Check for download password if required
        password = conn.query_params["password"]

        case Connections.validate_download_password(db_connection, password) do
          :ok ->
            Logger.info("Sync: Token connection validated for #{db_connection.name}")

            # Update last connected timestamp
            Connections.touch_connected(db_connection)

            # Capture connection metadata
            connection_info = extract_connection_info(conn)

            conn =
              WebSockAdapter.upgrade(
                conn,
                PhoenixKitWeb.SyncWebsock,
                [
                  auth_type: :connection,
                  connection: db_connection,
                  connection_info: connection_info
                ],
                timeout: 60_000
              )

            Plug.Conn.halt(conn)

          {:error, :invalid_password} ->
            Logger.warning("Sync: Invalid download password for connection #{db_connection.uuid}")
            send_forbidden(conn, "Invalid password")
        end

      {:error, :invalid_token} ->
        Logger.warning("Sync: Invalid token attempt")
        send_forbidden(conn, "Invalid token")

      {:error, :connection_not_active} ->
        Logger.warning("Sync: Token for inactive connection")
        send_forbidden(conn, "Connection not active")

      {:error, :connection_expired} ->
        Logger.warning("Sync: Token for expired connection")
        send_forbidden(conn, "Connection expired")

      {:error, :download_limit_reached} ->
        Logger.warning("Sync: Download limit reached")
        send_forbidden(conn, "Download limit reached")

      {:error, :record_limit_reached} ->
        Logger.warning("Sync: Record limit reached")
        send_forbidden(conn, "Record limit reached")

      {:error, :ip_not_allowed} ->
        Logger.warning("Sync: IP not in whitelist: #{client_ip}")
        send_forbidden(conn, "IP not allowed")

      {:error, :outside_allowed_hours} ->
        Logger.warning("Sync: Connection outside allowed hours")
        send_forbidden(conn, "Outside allowed hours")
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

    if forwarded_for do
      # Take the first IP in the chain (original client)
      forwarded_for
      |> String.split(",")
      |> List.first()
      |> String.trim()
    else
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
