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
      String.contains?(path, "/favicon")
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

    Enum.any?(auth_routes, fn route ->
      String.contains?(path, prefix_path.(route)) or
        String.contains?(path, route)
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

    html = """
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{header}</title>
        <link rel="stylesheet" href="/assets/css/app.css" />
        <meta http-equiv="refresh" content="5" />
      </head>
      <body class="h-full bg-base-200">
        <div class="flex items-center justify-center min-h-screen p-4">
          <div class="card bg-base-100 shadow-2xl border-2 border-dashed border-base-300 max-w-2xl w-full">
            <div class="card-body text-center py-12 px-6">
              <div class="text-8xl mb-6 opacity-70">🚧</div>
              <h1 class="text-5xl font-bold text-base-content mb-6">#{header}</h1>
              <p class="text-xl text-base-content/70 mb-8 leading-relaxed">#{subtext}</p>
            </div>
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
