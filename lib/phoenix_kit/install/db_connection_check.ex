defmodule PhoenixKit.Install.DbConnectionCheck do
  @moduledoc """
  Simple database connection check for PhoenixKit installation.
  """
  alias PhoenixKit.Config

  @dialyzer {:nowarn_function, ensure_connected!: 0}

  @doc """
  Returns `true` if the configured repo can reach the database, `false` otherwise.
  """
  @spec connected?() :: boolean()
  def connected? do
    case Config.get(:repo) do
      {:ok, repo} when is_atom(repo) ->
        repo_connected?(repo)

      _ ->
        false
    end
  end

  @doc """
  Verifies database connectivity, exiting with a user-friendly error on failure.

  Returns `:ok` when the database is reachable.
  """
  @spec ensure_connected!() :: :ok | no_return()
  def ensure_connected! do
    if connected?() do
      :ok
    else
      Mix.shell().error("""
      Cannot connect to database.

      Please ensure:
      1. PostgreSQL is running
      2. Database exists (run: mix ecto.create)
      3. Database configuration in config/#{Mix.env()}.exs is correct
      """)

      exit({:shutdown, 1})
    end
  end

  defp repo_connected?(repo) do
    with true <- Code.ensure_loaded?(repo),
         true <- function_exported?(repo, :__adapter__, 0),
         {:ok, %{rows: [[1]]}} <- repo.query("SELECT 1", [], timeout: 5_000, log: false) do
      true
    else
      _ -> false
    end
  end
end
