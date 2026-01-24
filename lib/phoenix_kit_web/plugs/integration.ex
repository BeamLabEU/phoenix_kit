defmodule PhoenixKitWeb.Plugs.Integration do
  @moduledoc """
  Central integration plug for PhoenixKit.

  This plug serves as a single entry point for all PhoenixKit plugs that need to run
  in the parent application's browser pipeline. It coordinates multiple sub-plugs and
  ensures they run in the correct order.

  ## Current Features

  - **Maintenance Mode**: Intercepts requests when maintenance mode is enabled
  - **WebSocket Transport Fix**: Clears cached LongPoll fallback preferences to ensure
    WebSocket is always tried first, providing much better LiveView performance

  ## Future Extensions

  This plug can be extended to include additional PhoenixKit features such as:
  - Rate limiting
  - Security headers
  - Analytics tracking
  - Custom middleware

  ## Usage

  This plug is automatically added to your `:browser` pipeline during installation:

      pipeline :browser do
        plug :accepts, ["html"]
        plug :fetch_session
        plug :fetch_live_flash
        plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
        plug :protect_from_forgery
        plug :put_secure_browser_headers
        plug PhoenixKitWeb.Plugs.Integration  # ← Added automatically
      end

  ## Performance

  Each sub-plug is optimized to be a no-op when its feature is disabled, ensuring
  zero performance impact when features are not in use.
  """

  import Plug.Conn
  alias PhoenixKitWeb.Plugs.MaintenanceMode

  # Inline script to clear Phoenix LiveView transport cache.
  # This ensures WebSocket is always tried first instead of using cached LongPoll fallback.
  # Must run BEFORE app.js/LiveSocket initializes.
  # IMPORTANT: Excludes 'phx:' prefixed keys (PhoenixKit features like phx:theme)
  @websocket_fix_script """
  <script>try{Object.keys(localStorage).filter(k=>k.includes('phx')&&!k.startsWith('phx:')).forEach(k=>localStorage.removeItem(k));Object.keys(sessionStorage).filter(k=>k.includes('phx')&&!k.startsWith('phx:')).forEach(k=>sessionStorage.removeItem(k))}catch(e){}</script>
  """

  @doc """
  Initializes the plug with options.
  """
  def init(opts), do: opts

  @doc """
  Runs all PhoenixKit integration plugs in sequence.
  """
  def call(conn, _opts) do
    conn
    |> run_maintenance_mode_check()
    |> inject_websocket_fix()

    # Future plugs can be added here:
    # |> run_rate_limiter()
    # |> run_security_headers()
  end

  # Run maintenance mode check
  defp run_maintenance_mode_check(conn) do
    MaintenanceMode.call(conn, [])
  end

  # Inject WebSocket transport fix script into HTML responses.
  # This clears any cached LongPoll fallback preferences before LiveSocket initializes.
  defp inject_websocket_fix(conn) do
    register_before_send(conn, fn conn ->
      # Only inject for HTML responses
      content_type = get_resp_header(conn, "content-type") |> List.first() || ""

      if String.contains?(content_type, "text/html") and conn.resp_body do
        inject_script_into_head(conn)
      else
        conn
      end
    end)
  end

  # Inject the script right after <head> tag so it runs before any other scripts
  # Uses simple string replacement instead of regex for better performance
  defp inject_script_into_head(conn) do
    body = to_string(conn.resp_body)

    # Try simple replacements first (faster than regex)
    cond do
      String.contains?(body, "<head>") ->
        new_body = String.replace(body, "<head>", "<head>" <> @websocket_fix_script, global: false)
        %{conn | resp_body: new_body}

      String.contains?(body, "<HEAD>") ->
        new_body = String.replace(body, "<HEAD>", "<HEAD>" <> @websocket_fix_script, global: false)
        %{conn | resp_body: new_body}

      true ->
        # No simple <head> tag found, try regex for <head ...> with attributes
        case Regex.run(~r/<head[^>]*>/i, body, return: :index) do
          [{start, length}] ->
            insert_pos = start + length
            {before, after_head} = String.split_at(body, insert_pos)
            new_body = before <> @websocket_fix_script <> after_head
            %{conn | resp_body: new_body}

          _ ->
            conn
        end
    end
  end
end
