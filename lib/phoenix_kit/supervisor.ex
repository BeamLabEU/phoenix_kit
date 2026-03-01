defmodule PhoenixKit.Supervisor do
  @moduledoc """
  Supervisor for all PhoenixKit workers.
  """
  use Supervisor

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
  defp build_children(true = _update_mode) do
    [
      PhoenixKit.PubSub.Manager,
      {PhoenixKit.Cache.Registry, []},
      PhoenixKit.ModuleRegistry,
      Supervisor.child_spec(
        {PhoenixKit.Cache,
         name: :settings, sync_init: false, warmer: &PhoenixKit.Settings.warm_cache_data/0},
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
      # Cache rendered blog posts (HTML) to avoid re-rendering markdown on every request
      Supervisor.child_spec(
        {PhoenixKit.Cache, name: :publishing_posts, ttl: :timer.hours(6)},
        id: :publishing_posts_cache
      ),
      # Dashboard tab registry for user dashboard navigation.
      # Starts after settings_cache so module enabled? checks hit cache rather than DB.
      PhoenixKit.Dashboard.Registry,
      # Rate limiter backend MUST be started before any authentication requests
      PhoenixKit.Users.RateLimiter.Backend,
      # OAuth config loader - now guaranteed to have critical settings in cache
      PhoenixKit.Workers.OAuthConfigLoader
    ] ++
      PhoenixKit.ModuleRegistry.static_children()
  end
end
