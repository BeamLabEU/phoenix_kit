defmodule PhoenixKit.Workers.OAuthConfigLoader do
  @moduledoc """
  GenServer worker that ensures OAuth configuration is loaded from database
  before any OAuth requests are processed.

  This worker runs synchronously during application startup to configure
  OAuth providers from database settings.

  ## Startup Sequence

  1. PhoenixKit.Cache starts with sync_init, loading critical OAuth settings
  2. OAuthConfigLoader starts, OAuth settings already in cache
  3. Loads OAuth configuration from cache
  4. Configures Ueberauth with available providers
  5. Returns :ok when complete

  ## Why This Is Needed

  Parent applications typically start services in this order:
  - Repo (database ready)
  - PubSub
  - Parent Endpoint (router compiles, Ueberauth.init() runs)
  - PhoenixKit.Supervisor (OAuth config should load here)

  With sync_init enabled in the Cache, critical OAuth settings are loaded
  synchronously before this worker starts, eliminating race conditions.

  This worker ensures OAuth configuration is available as early as possible
  during PhoenixKit.Supervisor initialization.
  """

  use GenServer
  require Logger

  ## Client API

  @doc """
  Starts the OAuth configuration loader.

  Loads OAuth configuration from cache which is pre-warmed with critical settings.
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
    # With sync_init in the Cache, critical OAuth settings are already loaded
    case load_oauth_config() do
      :ok ->
        Logger.info("OAuth config loaded successfully during startup")
        {:ok, %{status: :loaded}}

      {:error, :modules_not_loaded} ->
        Logger.info("OAuth modules not loaded, OAuth features will be unavailable")
        {:ok, %{status: :not_loaded, reason: :modules_not_loaded}}

      {:error, :repo_not_available} ->
        # During Mix tasks, the repo may not be available
        # This is expected and not an error condition
        Logger.debug(
          "OAuth config loading skipped: Repository not available (likely during Mix task execution)"
        )

        {:ok, %{status: :not_loaded, reason: :repo_not_available}}
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
    # With sync_init enabled, critical OAuth settings are already in cache
    # No need to check cache size or wait for warming

    # Check if repository is available (for Mix tasks)
    if PhoenixKit.Settings.repo_available?() do
      # OAuth settings are already loaded via sync_init
      oauth_enabled = PhoenixKit.Settings.get_setting("oauth_enabled", "false")

      # Check that at least one provider's credentials are accessible
      has_any_oauth_data =
        PhoenixKit.Settings.has_oauth_credentials?(:google) or
          PhoenixKit.Settings.has_oauth_credentials?(:apple) or
          PhoenixKit.Settings.has_oauth_credentials?(:github) or
          PhoenixKit.Settings.has_oauth_credentials?(:facebook)

      Logger.debug(
        "OAuth configuration: enabled=#{oauth_enabled}, has_oauth_data=#{has_any_oauth_data}"
      )

      # Configure OAuth providers from settings
      alias PhoenixKit.Users.OAuthConfig
      OAuthConfig.configure_providers()

      :ok
    else
      {:error, :repo_not_available}
    end
  rescue
    # Database connection errors
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Database connection error: #{Exception.message(error)}")
      {:error, :repo_not_available}

    # Any other unexpected error
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
