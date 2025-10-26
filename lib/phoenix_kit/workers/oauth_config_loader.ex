defmodule PhoenixKit.Workers.OAuthConfigLoader do
  @moduledoc """
  GenServer worker that ensures OAuth configuration is loaded from database
  before any OAuth requests are processed.

  This worker runs synchronously during application startup to prevent timing
  issues where Ueberauth plug is initialized before OAuth providers are configured.

  ## Startup Sequence

  1. Worker starts as first child in PhoenixKit.Supervisor
  2. Waits for Settings cache to be ready (with timeout)
  3. Loads OAuth configuration from database
  4. Configures Ueberauth with available providers
  5. Returns :ok when complete

  ## Why This Is Needed

  Parent applications typically start services in this order:
  - Repo (database ready)
  - PubSub
  - Parent Endpoint (router compiles, Ueberauth.init() runs)
  - PhoenixKit.Supervisor (OAuth config should load here)

  If PhoenixKit.Supervisor starts AFTER Parent Endpoint, the OAuth configuration
  arrives too late and Ueberauth fails with MatchError.

  This worker ensures OAuth configuration is available as early as possible
  during PhoenixKit.Supervisor initialization.
  """

  use GenServer
  require Logger

  @max_retries 10
  @retry_delay 100

  ## Client API

  @doc """
  Starts the OAuth configuration loader.

  Blocks until OAuth configuration is successfully loaded or max retries exceeded.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  ## Server Callbacks

  @impl true
  def init(_) do
    # Load OAuth configuration synchronously during initialization
    # This ensures configuration is ready before supervisor completes startup
    case load_oauth_config_with_retry() do
      :ok ->
        Logger.debug("OAuth config loaded successfully during startup")
        {:ok, %{}}

      {:error, reason} ->
        Logger.warning("OAuth config loading failed: #{inspect(reason)}")
        # Don't fail supervisor startup if OAuth config fails
        # The fallback plug will handle this case
        {:ok, %{}}
    end
  end

  ## Private Helpers

  defp load_oauth_config_with_retry(attempt \\ 1) do
    case load_oauth_config() do
      :ok ->
        :ok

      {:error, :cache_not_ready} when attempt < @max_retries ->
        Logger.debug("Settings cache not ready, retrying... (attempt #{attempt}/#{@max_retries})")
        Process.sleep(@retry_delay)
        load_oauth_config_with_retry(attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_oauth_config do
    # Check if required modules are loaded
    if Code.ensure_loaded?(PhoenixKit.Users.OAuthConfig) and
         Code.ensure_loaded?(PhoenixKit.Settings) do
      do_load_oauth_config()
    else
      Logger.debug("OAuth modules not loaded, skipping configuration")
      {:error, :modules_not_loaded}
    end
  end

  defp do_load_oauth_config do
    # Verify Settings cache is ready by attempting to read a setting
    # Try to read any setting to verify cache is operational
    _ = PhoenixKit.Settings.get_setting("oauth_enabled", "false")

    # Configure OAuth providers from database
    alias PhoenixKit.Users.OAuthConfig
    OAuthConfig.configure_providers()

    :ok
  rescue
    error ->
      # Cache might not be ready yet
      Logger.debug("Settings cache not ready: #{inspect(error)}")
      {:error, :cache_not_ready}
  end
end
