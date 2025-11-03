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

  @doc """
  Gets the current status of OAuth configuration.

  Returns:
  - `{:ok, :loaded}` - Configuration successfully loaded
  - `{:ok, :not_loaded, reason}` - Configuration not loaded with reason
  - `{:error, :not_running}` - OAuthConfigLoader is not running
  """
  def get_status do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_running}

      pid ->
        try do
          state = GenServer.call(pid, :get_status, 5000)

          case state do
            %{status: :loaded} ->
              {:ok, :loaded}

            %{status: :not_loaded, reason: reason} ->
              {:ok, :not_loaded, reason}

            %{status: :error, error: error} ->
              {:ok, :error, error}

            _ ->
              {:ok, :unknown}
          end
        catch
          :exit, _ ->
            {:error, :timeout}
        end
    end
  end

  @doc """
  Attempts to reload OAuth configuration.

  This can be called to retry loading configuration if it failed during startup.
  """
  def reload_config do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_running}

      pid ->
        GenServer.call(pid, :reload_config, 10_000)
    end
  end

  ## Server Callbacks

  @impl true
  def init(_) do
    # Load OAuth configuration synchronously during initialization
    # This ensures configuration is ready before supervisor completes startup
    case load_oauth_config_with_retry() do
      :ok ->
        Logger.info("OAuth config loaded successfully during startup")
        {:ok, %{status: :loaded}}

      {:error, :cache_not_ready} ->
        Logger.warning(
          "OAuth config loading failed after #{@max_retries} attempts: cache not ready"
        )

        # Don't fail supervisor startup if cache is not ready
        # The fallback plug will handle this case
        {:ok, %{status: :not_loaded, reason: :cache_not_ready}}

      {:error, :modules_not_loaded} ->
        Logger.info("OAuth modules not loaded, OAuth features will be unavailable")
        {:ok, %{status: :not_loaded, reason: :modules_not_loaded}}
    end
  rescue
    # Catch unexpected errors during initialization
    error ->
      Logger.error("""
      Critical error during OAuth config loader initialization:
      #{Exception.format(:error, error, __STACKTRACE__)}
      OAuth features will be unavailable.
      """)

      # Still don't crash supervisor, but log the error prominently
      {:ok, %{status: :error, error: error}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:reload_config, _from, state) do
    case load_oauth_config() do
      :ok ->
        new_state = %{state | status: :loaded}
        Logger.info("OAuth configuration reloaded successfully")
        {:reply, :ok, new_state}

      {:error, reason} = error ->
        new_state = %{state | status: :not_loaded, reason: reason}
        Logger.warning("OAuth configuration reload failed: #{inspect(reason)}")
        {:reply, error, new_state}
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
    # Specific error types that indicate cache not ready (retriable)
    error in [RuntimeError, UndefinedFunctionError] ->
      # These are expected during startup - Settings cache may not be ready
      Logger.debug("Settings cache not ready: #{Exception.message(error)}")
      {:error, :cache_not_ready}

    # Database connection errors (retriable)
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Database connection error: #{Exception.message(error)}")
      {:error, :cache_not_ready}

    # Any other unexpected error (non-retriable)
    error ->
      # Log full error with stacktrace for debugging
      Logger.error("""
      Unexpected error loading OAuth configuration:
      #{Exception.format(:error, error, __STACKTRACE__)}
      """)

      # Re-raise to fail fast on unexpected errors
      reraise error, __STACKTRACE__
  end
end
