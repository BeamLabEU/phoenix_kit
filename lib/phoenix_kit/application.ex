defmodule PhoenixKit.Application do
  @moduledoc """
  OTP Application module for PhoenixKit.

  Note: PhoenixKit.Supervisor is started by the parent application,
  not by this module. This is an empty application callback.
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    check_installation()

    children = [
      # Start the Ecto repository
      PhoenixKit.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: PhoenixKit.PubSub},
      # Start the Endpoint (http/https)
      PhoenixKitWeb.Endpoint
    ]

    # PhoenixKit.Supervisor is started by parent app in its supervision tree
    # This is just a placeholder to satisfy OTP application callback
    opts = [strategy: :one_for_one, name: PhoenixKit.AppSupervisor]
    Supervisor.start_link(children, opts)
  end

  defp check_installation do
    unless PhoenixKit.configured?() do
      Logger.warning("""
      PhoenixKit is added as a dependency but not installed.
      Run: mix phoenix_kit.install
      See: https://hexdocs.pm/phoenix_kit
      """)
    end
  end
end
