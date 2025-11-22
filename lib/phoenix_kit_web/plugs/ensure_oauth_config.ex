defmodule PhoenixKitWeb.Plugs.EnsureOAuthConfig do
  @moduledoc """
  Plug that ensures OAuth configuration is loaded before processing OAuth requests.

  This plug serves as a fallback safety mechanism for cases where:
  - PhoenixKit.Supervisor starts AFTER parent application's Endpoint
  - OAuthConfigLoader worker failed to load configuration
  - Configuration was cleared or lost for any reason

  ## How It Works

  1. Checks if Ueberauth has :providers configured
  2. If configuration is missing or invalid, loads it synchronously
  3. If loading fails, returns 503 Service Unavailable error
  4. Otherwise, allows request to proceed normally

  ## Usage

  Add this plug BEFORE Ueberauth plug in OAuth controller:

      plug PhoenixKitWeb.Plugs.EnsureOAuthConfig
      plug Ueberauth

  ## Why This Is Needed

  Ueberauth plug expects :providers key to exist in application config.
  If it's missing, Ueberauth.get_providers/2 fails with MatchError.

  This plug prevents that error by ensuring configuration exists before
  Ueberauth plug runs.
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
