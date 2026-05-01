# Test helper for PhoenixKit test suite

# Check if the test database exists before trying to connect.
# Uses `psql -lqt` for a fast check that avoids Postgrex connection hangs.
# Falls back to attempting connection directly if psql is unavailable (e.g., CI).
db_name =
  Application.get_env(:phoenix_kit, PhoenixKit.Test.Repo)[:database] || "phoenix_kit_test"

db_check =
  case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
    {output, 0} ->
      exists =
        output
        |> String.split("\n")
        |> Enum.any?(fn line ->
          line |> String.split("|") |> List.first("") |> String.trim() == db_name
        end)

      if exists, do: :exists, else: :not_found

    _ ->
      # psql not available (CI without postgresql-client) — try connecting directly
      :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n⚠  Test database "#{db_name}" not found — integration tests will be excluded.
       Run `mix test.setup` to create the test database.
    """)

    false
  else
    try do
      {:ok, _} = PhoenixKit.Test.Repo.start_link()

      migrations_path = Path.join([__DIR__, "support", "postgres", "migrations"])
      Ecto.Migrator.run(PhoenixKit.Test.Repo, migrations_path, :up, all: true, log: false)

      Ecto.Adapters.SQL.Sandbox.mode(PhoenixKit.Test.Repo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit, :test_repo_available, repo_available)

# Start minimal services needed for tests
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])
{:ok, _pid} = PhoenixKit.Users.RateLimiter.Backend.start_link([])

# Start the LV endpoint once for the whole test run. `PhoenixKitWeb.ConnCase`
# previously did this per-test via `start_supervised`, but that ties the
# endpoint's lifetime to a single test pid — when an async test finishes,
# ExUnit tears down its supervisor and any concurrent test loses the
# `PhoenixKitWeb.Endpoint` ETS config table mid-request, surfacing as
# `:ets.lookup(PhoenixKitWeb.Endpoint, :secret_key_base)` ArgumentErrors.
# A single Application-level start avoids that race entirely.
case Process.whereis(PhoenixKitWeb.Endpoint) do
  nil -> {:ok, _} = PhoenixKitWeb.Endpoint.start_link()
  _pid -> :ok
end

# Exclude integration tests when DB is not available
exclude = if repo_available, do: [], else: [:integration]

ExUnit.start(exclude: exclude)
