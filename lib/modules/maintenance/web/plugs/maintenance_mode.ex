defmodule PhoenixKitWeb.Plugs.MaintenanceMode do
  @moduledoc """
  Plug that enforces maintenance mode for non-admin users.

  When the Maintenance module is enabled, this plug will:
  - Allow admins and owners to access the site normally
  - Show maintenance page to all other users
  - Work for both LiveView and regular controller routes

  ## Usage

  This plug is automatically called by PhoenixKitWeb.Plugs.Integration which is
  added to your browser pipeline during installation. No manual setup required.

  ## Internal Usage

  The Integration plug calls this plug internally to check maintenance mode status.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @doc """
  Initializes the plug with options.
  """
  def init(opts), do: opts

  @doc """
  Checks if maintenance mode is enabled and renders maintenance page for non-admin users.
  """
  def call(conn, _opts) do
    # Only proceed if maintenance mode is enabled
    if Maintenance.enabled?() do
      handle_maintenance_mode(conn)
    else
      conn
    end
  end

  # Handle maintenance mode logic
  defp handle_maintenance_mode(conn) do
    # Skip maintenance mode for auth routes and static assets
    if should_skip_maintenance?(conn.request_path) do
      conn
    else
      # Get user from session and check if admin/owner
      user = get_user_from_session(conn)

      if user_is_admin_or_owner?(user) do
        # Admin/Owner bypasses maintenance mode
        conn
      else
        # Non-admin user - render maintenance page
        render_maintenance_page(conn)
      end
    end
  end

  # Check if user is admin or owner
  defp user_is_admin_or_owner?(nil), do: false

  defp user_is_admin_or_owner?(user) do
    scope = Scope.for_user(user)
    Scope.admin?(scope) || Scope.owner?(scope)
  end

  # Skip maintenance mode for these paths
  defp should_skip_maintenance?(path) do
    # Authentication routes (for existing users only - no registration)
    # Static assets
    String.contains?(path, "/users/log-in") ||
      String.contains?(path, "/users/reset-password") ||
      String.contains?(path, "/users/confirm") ||
      String.contains?(path, "/users/magic-link") ||
      String.contains?(path, "/users/auth/") ||
      String.starts_with?(path, "/assets/") ||
      String.starts_with?(path, "/images/") ||
      String.starts_with?(path, "/fonts/") ||
      String.contains?(path, "/favicon")
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

    html = """
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content="#{get_csrf_token()}" />
        <title>#{config.header}</title>
        <link rel="stylesheet" href="/assets/css/app.css" />
      </head>
      <body class="h-full bg-base-200">
        <div class="flex items-center justify-center min-h-screen p-4">
          <div class="card bg-base-100 shadow-2xl border-2 border-dashed border-base-300 max-w-2xl w-full">
            <div class="card-body text-center py-12 px-6">
              <div class="text-8xl mb-6 opacity-70">
                🚧
              </div>
              <h1 class="text-5xl font-bold text-base-content mb-6">
                #{config.header}
              </h1>
              <p class="text-xl text-base-content/70 mb-8 leading-relaxed">
                #{config.subtext}
              </p>
            </div>
          </div>
        </div>
      </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(:service_unavailable, html)
    |> halt()
  end
end
