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
    # Module children (Presence, Supervisors, Listeners, etc.)
    # Uses static_children/0 which works before the GenServer starts
    children =
      [
        PhoenixKit.PubSub.Manager,
        PhoenixKit.Admin.SimplePresence,
        {PhoenixKit.Cache.Registry, []},
        # Module registry — must start before Dashboard.Registry so module tabs are available
        PhoenixKit.ModuleRegistry,
        # Settings cache starts BEFORE Dashboard.Registry so enabled?/0 calls hit the cache
        # instead of making individual DB queries per module at startup.
        # Loads all settings asynchronously via :warm_cache message (non-blocking for supervisor).
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
        # No longer needs retry logic as cache is pre-warmed with OAuth settings
        PhoenixKit.Workers.OAuthConfigLoader
      ] ++
        PhoenixKit.ModuleRegistry.static_children()

    Supervisor.init(children, strategy: :one_for_one)
  end
end
