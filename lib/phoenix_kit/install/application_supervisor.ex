defmodule PhoenixKit.Install.ApplicationSupervisor do
  @moduledoc """
  Installation helper for adding PhoenixKit supervisor to parent application.
  Used by `mix phoenix_kit.install` task.
  """
  use PhoenixKit.Install.IgniterCompat

  alias Igniter.Libs.Phoenix
  alias Igniter.Project.Application

  def add_supervisor(igniter) do
    {igniter, endpoint} = Phoenix.select_endpoint(igniter)

    igniter
    |> Application.add_new_child(PhoenixKit.Supervisor,
      before: [endpoint]
    )
  end
end
