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
    children = [
      PhoenixKit.PubSub.Manager,
      PhoenixKit.Admin.SimplePresence,
      {PhoenixKit.Cache.Registry, []},
      # Settings cache with synchronous initialization
      # Loads all settings in handle_continue (after init returns)
      # This ensures OAuth configuration is available before OAuthConfigLoader starts
      # while not blocking supervisor initialization
      Supervisor.child_spec(
        {PhoenixKit.Cache,
         name: :settings, sync_init: true, warmer: &PhoenixKit.Settings.warm_cache_data/0},
        id: :settings_cache
      ),
      # Cache rendered blog posts (HTML) to avoid re-rendering markdown on every request
      Supervisor.child_spec(
        {PhoenixKit.Cache, name: :blog_posts, ttl: :timer.hours(6)},
        id: :blog_posts_cache
      ),
      # Rate limiter backend MUST be started before any authentication requests
      PhoenixKit.Users.RateLimiter.Backend,
      # OAuth config loader - now guaranteed to have critical settings in cache
      # No longer needs retry logic as cache is pre-warmed with OAuth settings
      PhoenixKit.Workers.OAuthConfigLoader,
      # Presence modules for collaborative editing
      PhoenixKit.Modules.Entities.Presence,
      PhoenixKit.Modules.Publishing.Presence,
      # Email tracking supervisor - handles SQS Worker for automatic bounce event processing
      PhoenixKit.Modules.Emails.Supervisor,
      # DB Sync session store for ephemeral connection codes
      PhoenixKit.Modules.Sync.SessionStore,
      # DB Explorer listener for PostgreSQL LISTEN/NOTIFY (live table updates)
      PhoenixKit.Modules.DB.Listener
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
