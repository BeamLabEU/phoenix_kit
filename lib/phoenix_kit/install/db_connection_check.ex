defmodule PhoenixKit.Install.DbConnectionCheck do
  @moduledoc """
  Simple database connection check for PhoenixKit installation.
  """
  alias PhoenixKit.Config

  @dialyzer {:nowarn_function, check!: 0}

  @doc """
  Check if database is reachable. Returns true if connected, false otherwise.
  """
  def check? do
    case Config.get(:repo) do
      {:ok, repo} when is_atom(repo) ->
        check_repo?(repo)

      _ ->
        false
    end
  end

  @doc """
  Check DB connection and exit with error if not connected.
  """
  @spec check!() :: no_return()
  def check! do
    unless check?() do
      Mix.shell().error("""
      ❌ Cannot connect to database.

      Please ensure:
      1. PostgreSQL is running
      2. Database exists (run: mix ecto.create)
      3. Configuration in config/dev.exs is correct
      """)

      exit({:shutdown, 1})
    end
  end

  defp check_repo?(repo) do
    with true <- Code.ensure_loaded?(repo),
         true <- function_exported?(repo, :__adapter__, 0),
         {:ok, %{rows: [[1]]}} <- repo.query("SELECT 1", [], log: false) do
      true
    else
      _ -> false
    end
  end
end
