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
      # Settings cache with synchronous initialization for critical OAuth settings
      # This ensures OAuth configuration is available before OAuthConfigLoader starts
      {PhoenixKit.Cache,
       name: :settings,
       sync_init: true,
       critical_warmer: &PhoenixKit.Settings.warm_critical_cache/0,
       warmer: &PhoenixKit.Settings.warm_cache_data/0},
      # Rate limiter backend MUST be started before any authentication requests
      PhoenixKit.Users.RateLimiter.Backend,
      # OAuth config loader - now guaranteed to have critical settings in cache
      # No longer needs retry logic as cache is pre-warmed with OAuth settings
      PhoenixKit.Workers.OAuthConfigLoader,
      PhoenixKit.Entities.Presence,
      # Email tracking supervisor - handles SQS Worker for automatic bounce event processing
      PhoenixKit.Emails.Supervisor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
