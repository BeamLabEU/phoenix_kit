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
      # OAuth config loader MUST be first to ensure configuration
      # is available before any OAuth requests are processed
      PhoenixKit.Workers.OAuthConfigLoader,
      PhoenixKit.PubSub.Manager,
      PhoenixKit.Admin.SimplePresence,
      {PhoenixKit.Cache.Registry, []},
      {PhoenixKit.Cache, name: :settings, warmer: &PhoenixKit.Settings.warm_cache_data/0},
      PhoenixKit.Entities.Presence
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
