defmodule PhoenixKit.Install.ApplicationSupervisor do
  @moduledoc """
  Installation helper for adding PhoenixKit supervisor to parent application.
  Used by `mix phoenix_kit.install` task.

  ## Important

  PhoenixKit.Supervisor MUST start AFTER the Ecto Repo because it depends on
  the database for loading Settings cache and OAuth configuration.

  Incorrect order (will crash):
  ```elixir
  children = [
    PhoenixKit.Supervisor,  # ❌ Tries to read Settings from DB
    MyApp.Repo              # ⚠️ DB not ready yet!
  ]
  ```

  Correct order:
  ```elixir
  children = [
    MyApp.Repo,             # ✅ Start DB first
    PhoenixKit.Supervisor   # ✅ Then PhoenixKit
  ]
  ```
  """
  use PhoenixKit.Install.IgniterCompat

  alias Igniter.Libs.Ecto
  alias Igniter.Libs.Phoenix
  alias Igniter.Project.Application

  def add_supervisor(igniter) do
    {igniter, endpoint} = Phoenix.select_endpoint(igniter)
    {igniter, repos} = Ecto.list_repos(igniter)

    repo = List.first(repos)

    # Build positioning options based on whether we found a Repo
    opts =
      case repo do
        nil ->
          # No Repo found - just add before endpoint
          # User will need to manually reorder if they have a Repo
          [before: [endpoint]]

        repo_module ->
          # Repo found - explicitly position AFTER Repo AND BEFORE Endpoint
          # This ensures correct startup order: Repo → PhoenixKit → Endpoint
          [after: [repo_module], before: [endpoint]]
      end

    igniter
    |> Application.add_new_child(PhoenixKit.Supervisor, opts)
  end
end
