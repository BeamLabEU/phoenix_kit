defmodule PhoenixKitWeb.Plugs.MaintenanceMode do
  @moduledoc """
  Plug that enforces maintenance mode for non-admin users on controller routes.

  LiveView routes are handled by the on_mount hook in `auth.ex` which overrides
  the layout instead of redirecting. This plug handles the remaining non-LiveView
  routes (POST actions, OAuth callbacks, etc.) by rendering a 503 maintenance page.

  Adds a `Retry-After` header when a scheduled end time is known.
  """

  import Plug.Conn

  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    # Clean up stale state if the scheduled end time has passed
    Maintenance.cleanup_expired_schedule()

    if Maintenance.active?() do
      handle_maintenance_mode(conn)
    else
      conn
    end
  end

  defp handle_maintenance_mode(conn) do
    if should_skip?(conn.request_path) do
      conn
    else
      user = get_user_from_session(conn)

      if admin_or_owner?(user) do
        conn
      else
        render_maintenance_page(conn)
      end
    end
  end

  defp should_skip?(path) do
    static_asset?(path) or auth_route?(path)
  end

  defp static_asset?(path) do
    String.starts_with?(path, "/assets/") or
      String.starts_with?(path, "/images/") or
      String.starts_with?(path, "/fonts/") or
      String.starts_with?(path, "/favicon")
  end

  defp auth_route?(path) do
    url_prefix = PhoenixKit.Config.get_url_prefix()

    prefix_path = fn route ->
      case url_prefix do
        "" -> route
        "/" -> route
        prefix -> prefix <> route
      end
    end

    auth_routes = [
      "/users/log-in",
      "/users/reset-password",
      "/users/confirm",
      "/users/magic-link",
      "/users/auth/"
    ]

    # Use starts_with? (not contains?) to prevent parent-app paths like
    # "/blog/users/log-in-to-us" from bypassing maintenance mode.
    Enum.any?(auth_routes, fn route ->
      String.starts_with?(path, prefix_path.(route)) or
        String.starts_with?(path, route)
    end)
  end

  defp admin_or_owner?(nil), do: false

  defp admin_or_owner?(user) do
    scope = Scope.for_user(user)
    Scope.admin?(scope) || Scope.owner?(scope)
  end

  defp get_user_from_session(conn) do
    if user_token = get_session(conn, :user_token) do
      Auth.get_user_by_session_token(user_token)
    else
      nil
    end
  end

  defp render_maintenance_page(conn) do
    config = Maintenance.get_config()
    header = Phoenix.HTML.html_escape(config.header) |> Phoenix.HTML.safe_to_string()
    subtext = Phoenix.HTML.html_escape(config.subtext) |> Phoenix.HTML.safe_to_string()

    # Inline styles so the page works without the parent app's asset pipeline.
    # Controller routes served by this plug may not have access to the digested
    # app.css, so we ship a self-contained page.
    html = """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{header}</title>
        <meta http-equiv="refresh" content="5" />
        <style>
          html, body { margin: 0; padding: 0; height: 100%; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; }
          body { background: #f2f2f2; color: #1a1a1a; }
          .wrap { display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 1rem; box-sizing: border-box; }
          .card { background: #fff; border: 2px dashed #d4d4d4; border-radius: 1rem; box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.25); max-width: 42rem; width: 100%; padding: 3rem 1.5rem; text-align: center; box-sizing: border-box; }
          .icon { font-size: 5rem; margin-bottom: 1.5rem; opacity: 0.7; }
          h1 { font-size: 3rem; font-weight: 700; margin: 0 0 1.5rem 0; line-height: 1.1; }
          p { font-size: 1.25rem; line-height: 1.6; opacity: 0.7; margin: 0; }
          @media (prefers-color-scheme: dark) {
            body { background: #1d232a; color: #a6adbb; }
            .card { background: #191e24; border-color: #2a323c; }
          }
        </style>
      </head>
      <body>
        <div class="wrap">
          <div class="card">
            <div class="icon">🚧</div>
            <h1>#{header}</h1>
            <p>#{subtext}</p>
          </div>
        </div>
      </body>
    </html>
    """

    conn
    |> maybe_add_retry_after()
    |> put_resp_content_type("text/html")
    |> send_resp(:service_unavailable, html)
    |> halt()
  end

  defp maybe_add_retry_after(conn) do
    case Maintenance.seconds_until_end() do
      seconds when is_integer(seconds) and seconds > 0 ->
        put_resp_header(conn, "retry-after", Integer.to_string(seconds))

      _ ->
        conn
    end
  end
end
