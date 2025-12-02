defmodule PhoenixKitWeb.Plugs.EnsureOAuthConfig do
  @moduledoc """
  Plug that ensures OAuth credentials are loaded into Application env before OAuth requests.

  This plug loads OAuth provider credentials from the database and configures
  them in Application env so that `Ueberauth.run_request/4` and `Ueberauth.run_callback/4`
  can access them at runtime.

  ## How It Works

  1. Checks if Ueberauth configuration exists in Application env
  2. If configuration is missing, loads credentials from database via `OAuthConfig.configure_providers()`
  3. If loading fails, returns 503 Service Unavailable error
  4. Otherwise, allows request to proceed

  ## Usage

  Used in OAuth controller before dynamic Ueberauth calls:

      plug PhoenixKitWeb.Plugs.EnsureOAuthConfig
      # Then in controller actions:
      # Ueberauth.run_request(conn, provider, provider_config)
      # Ueberauth.run_callback(conn, provider, provider_config)

  ## Why This Is Needed

  PhoenixKit stores OAuth credentials in the database. This plug ensures
  credentials are loaded into Application env before Ueberauth strategy
  modules attempt to read them.
  """

  import Plug.Conn
  require Logger

  alias PhoenixKit.Config

  def init(opts), do: opts

  def call(conn, _opts) do
    case ensure_oauth_config() do
      :ok ->
        conn

      {:error, reason} ->
        Logger.error("OAuth configuration unavailable: #{inspect(reason)}")

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(503, """
        <html>
          <head><title>Service Temporarily Unavailable</title></head>
          <body>
            <h1>OAuth Service Unavailable</h1>
            <p>OAuth authentication is temporarily unavailable. Please try again later.</p>
            <p>If this problem persists, please contact support.</p>
          </body>
        </html>
        """)
        |> halt()
    end
  end

  defp ensure_oauth_config do
    providers = Config.UeberAuth.get_providers()

    case providers do
      providers when is_map(providers) or is_list(providers) ->
        # Configuration exists, all good
        :ok

      _ ->
        # Configuration missing, try to load it
        Logger.warning("Ueberauth :providers missing, attempting to load OAuth configuration")
        load_oauth_config()
    end
  end

  defp load_oauth_config do
    if Code.ensure_loaded?(PhoenixKit.Users.OAuthConfig) do
      try do
        alias PhoenixKit.Users.OAuthConfig
        OAuthConfig.configure_providers()
        Logger.info("OAuth configuration loaded successfully via fallback plug")
        :ok
      rescue
        error ->
          Logger.error("Failed to load OAuth configuration: #{inspect(error)}")
          {:error, :configuration_load_failed}
      end
    else
      Logger.error("PhoenixKit.Users.OAuthConfig module not available")
      {:error, :oauth_module_not_loaded}
    end
  end
end
