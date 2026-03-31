defmodule PhoenixKit.Supervisor do
  @moduledoc """
  Supervisor for all PhoenixKit workers.
  """
  use Supervisor

  alias PhoenixKit.Modules.Languages

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    update_mode = Application.get_env(:phoenix_kit, :update_mode, false)
    children = build_children(update_mode)
    Supervisor.init(children, strategy: :one_for_one)
  end

  # Minimal set of children needed when running mix phoenix_kit.update.
  # Skips Dashboard.Registry, OAuthConfigLoader, module workers, and presence
  # so the update task only needs 1-2 DB connections for migrations.
  # Settings cache starts with NO warmer — all Settings functions return nil/%{}
  # in update_mode anyway, so warming would just spam warnings every 10 s.
  defp build_children(true = _update_mode) do
    [
      PhoenixKit.PubSub.Manager,
      {PhoenixKit.Cache.Registry, []},
      PhoenixKit.ModuleRegistry,
      Supervisor.child_spec(
        {PhoenixKit.Cache, name: :settings},
        id: :settings_cache
      ),
      PhoenixKit.Users.RateLimiter.Backend
    ]
  end

  # Full set of children for normal application operation.
  defp build_children(false = _update_mode) do
    [
      PhoenixKit.PubSub.Manager,
      PhoenixKit.Admin.SimplePresence,
      {PhoenixKit.Cache.Registry, []},
      # Module registry — must start before Dashboard.Registry so module tabs are available
      PhoenixKit.ModuleRegistry,
      # Settings cache starts BEFORE Dashboard.Registry so enabled?/0 calls hit the cache
      # instead of making individual DB queries per module at startup.
      Supervisor.child_spec(
        {PhoenixKit.Cache,
         name: :settings, sync_init: true, warmer: &PhoenixKit.Settings.warm_cache_data/0},
        id: :settings_cache
      ),
      # Dashboard tab registry for user dashboard navigation.
      # Starts after settings_cache so module enabled? checks hit cache rather than DB.
      PhoenixKit.Dashboard.Registry,
      # Normalize legacy admin_languages setting into unified languages_config
      # Runs once after settings cache is warmed; idempotent no-op if already migrated
      Supervisor.child_spec(
        {Task, fn -> Languages.normalize_language_settings() end},
        id: :normalize_languages
      ),
      # Rate limiter backend MUST be started before any authentication requests
      PhoenixKit.Users.RateLimiter.Backend,
      # Task supervisor for fire-and-forget background work (e.g. stale fixer)
      {Task.Supervisor, name: PhoenixKit.TaskSupervisor},
      # OAuth config loader - now guaranteed to have critical settings in cache
      PhoenixKit.Workers.OAuthConfigLoader
    ] ++
      PhoenixKit.ModuleRegistry.static_children()
  end
end
