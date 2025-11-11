defmodule PhoenixKitWeb.Plugs.Integration do
  @moduledoc """
  Central integration plug for PhoenixKit.

  This plug serves as a single entry point for all PhoenixKit plugs that need to run
  in the parent application's browser pipeline. It coordinates multiple sub-plugs and
  ensures they run in the correct order.

  ## Current Features

  - **Maintenance Mode**: Intercepts requests when maintenance mode is enabled

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

  alias PhoenixKitWeb.Plugs.MaintenanceMode

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

    # Future plugs can be added here:
    # |> run_rate_limiter()
    # |> run_security_headers()
  end

  # Run maintenance mode check
  defp run_maintenance_mode_check(conn) do
    MaintenanceMode.call(conn, [])
  end
end
