defmodule PhoenixKit.Application do
  @moduledoc """
  OTP Application module for PhoenixKit.

  Note: PhoenixKit.Supervisor is started by the parent application,
  not by this module. This is an empty application callback.
  """
  use Application

  @impl true
  def start(_type, _args) do
    # PhoenixKit.Supervisor is started by parent app in its supervision tree
    # This is just a placeholder to satisfy OTP application callback
    Supervisor.start_link([], strategy: :one_for_one, name: PhoenixKit.AppSupervisor)
  end
end
