defmodule PhoenixKit.Squash.RepoHelper do
  @moduledoc """
  Starts a minimal Ecto/Postgrex repo wired from environment variables at
  script runtime (outside the normal Mix/test config pipeline).

  Usage from a .exs script:

      Code.require_file("dev_docs/squash/repo_helper.ex")
      {:ok, repo} = PhoenixKit.Squash.RepoHelper.start()
      PhoenixKit.Squash.RepoHelper.query!(repo, "SELECT 1")

  The repo module is `PhoenixKit.Test.Repo` (already compiled in MIX_ENV=test)
  but its connection config is overridden from env so the squash scripts can
  point at a different host/database than the normal test DB.

  Required env vars: `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`.
  `PGPASSWORD` is genuinely mandatory: Postgrex never reads `.pgpass`, so a
  missing password would only fail later with an opaque auth error — we
  validate eagerly instead.

  Optional: `PGPORT` (default 5432), `PGSSL` ("true" enables SSL), `PGPOOL`
  (default 5 — matches the pre-PGPOOL hardcoded pool_size; a shared,
  connection-constrained instance should set this explicitly, same as
  `mix test`'s `config/test.exs` reader). A set-but-empty `PGPOOL=` is
  treated as absent rather than raising (mirrors `config/test.exs`, fixed
  after PR 681 found the opposite behavior confusing); a non-numeric or
  non-positive value raises a message naming the variable and the value.

  Functions tagged `[DB]` need a live direct Postgres connection (never
  PgBouncer — it silently drops transactional DDL). Everything else is pure;
  `run_self_checks/0` exercises the env parsing offline for verify.exs
  `--check`.
  """

  @repo PhoenixKit.Test.Repo

  # -------------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------------

  @doc """
  The repo module `start/0` starts and every query function targets —
  exposed so a caller that needs to start a SECOND, differently-configured
  instance of the same module (Ecto's dynamic-repo support: same module,
  distinct `:name`) doesn't have to hardcode the literal atom (verify.exs's
  S12 pooled-connection scenario).
  """
  def repo_module, do: @repo

  @doc """
  Start the repo and return {:ok, repo_module} or {:error, reason}.
  Idempotent: safe to call multiple times.

  Uses `pool: DBConnection.ConnectionPool` (not the test sandbox) so scripts
  get real autocommit connections and can run DDL outside a transaction.

  [DB] — requires a live Postgres connection.
  """
  def start do
    ensure_applications_started()

    config = build_config()

    Application.put_env(:phoenix_kit, @repo, config)

    case @repo.start_link(config) do
      {:ok, _pid} ->
        {:ok, @repo}

      {:error, {:already_started, _pid}} ->
        {:ok, @repo}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Same as start/0 but raises on failure.
  """
  def start! do
    case start() do
      {:ok, repo} -> repo
      {:error, reason} -> raise "Failed to start repo: #{inspect(reason)}"
    end
  end

  @doc """
  Execute raw SQL via the running repo. Returns {:ok, result} or {:error, reason}.
  [DB]
  """
  def query(repo, sql, params \\ []) do
    repo.query(sql, params)
  end

  @doc """
  Execute raw SQL and raise on failure.
  [DB]
  """
  def query!(repo, sql, params \\ []) do
    case repo.query(sql, params) do
      {:ok, result} -> result
      {:error, reason} -> raise "Query failed: #{inspect(reason)}\nSQL: #{sql}"
    end
  end

  @doc """
  Build a connection map from env vars (used for the repo config and for
  pg_dump/psql subprocess env). Pure given an explicit `env` map; reads
  `System.get_env/0` when called without arguments.

  Raises with an operator-facing message when a required variable is missing
  or blank.
  """
  def connection_env(env \\ nil) do
    env = env || System.get_env()

    %{
      host: fetch!(env, "PGHOST"),
      port: String.to_integer(Map.get(env, "PGPORT", "5432")),
      username: fetch!(env, "PGUSER"),
      password: fetch!(env, "PGPASSWORD"),
      database: fetch!(env, "PGDATABASE"),
      ssl: Map.get(env, "PGSSL") == "true",
      pool_size: parse_pool_size(Map.get(env, "PGPOOL"))
    }
  end

  @doc """
  Offline self-test of the env parsing (no DB, no real env). Returns `:ok` or
  raises with the failing check's name. Called by verify.exs `--check`.
  """
  def run_self_checks do
    full = %{
      "PGHOST" => "db.example",
      "PGPORT" => "6543",
      "PGUSER" => "u",
      "PGPASSWORD" => "secret",
      "PGDATABASE" => "d",
      "PGSSL" => "true"
    }

    ce = connection_env(full)
    check!(ce.host == "db.example" and ce.port == 6543, "connection_env: parses host/port")
    check!(ce.ssl == true, "connection_env: PGSSL flag")

    check!(
      connection_env(Map.delete(full, "PGPORT")).port == 5432,
      "connection_env: default port"
    )

    check!(connection_env(Map.delete(full, "PGSSL")).ssl == false, "connection_env: default ssl")

    check!(
      raised_message(fn -> connection_env(Map.delete(full, "PGPASSWORD")) end) =~ "PGPASSWORD",
      "connection_env: missing PGPASSWORD raises eagerly"
    )

    check!(
      raised_message(fn -> connection_env(Map.put(full, "PGDATABASE", "")) end) =~ "PGDATABASE",
      "connection_env: blank PGDATABASE raises eagerly"
    )

    check!(
      connection_env(Map.delete(full, "PGPOOL")).pool_size == 5,
      "connection_env: default pool_size"
    )

    check!(
      connection_env(Map.put(full, "PGPOOL", "4")).pool_size == 4,
      "connection_env: PGPOOL parsed"
    )

    check!(
      connection_env(Map.put(full, "PGPOOL", "")).pool_size == 5,
      "connection_env: blank PGPOOL treated as absent, not raised"
    )

    check!(
      raised_message(fn -> connection_env(Map.put(full, "PGPOOL", "0")) end) =~ "PGPOOL",
      "connection_env: non-positive PGPOOL raises eagerly"
    )

    check!(
      raised_message(fn -> connection_env(Map.put(full, "PGPOOL", "abc")) end) =~ "PGPOOL",
      "connection_env: non-numeric PGPOOL raises eagerly"
    )

    :ok
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp build_config do
    ce = connection_env()

    [
      hostname: ce.host,
      port: ce.port,
      username: ce.username,
      password: ce.password,
      database: ce.database,
      ssl: ce.ssl,
      pool_size: ce.pool_size,
      # Disable sandbox so scripts can run DDL outside a transaction
      pool: DBConnection.ConnectionPool,
      log: false
    ]
  end

  defp fetch!(env, name) do
    case Map.get(env, name) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        raise "Required env var #{name} is not set#{fetch_hint(name)}"
    end
  end

  defp fetch_hint("PGPASSWORD"),
    do: " (Postgrex never reads .pgpass; export PGPASSWORD explicitly)"

  defp fetch_hint(_name), do: ""

  # Mirrors config/test.exs's PGPOOL reader (fixed post-PR-681): a set-but-
  # empty value is UNSET, not a parse failure — System.get_env/2's fallback
  # only fires when the var is entirely absent, so this can't be folded into
  # a Map.get default.
  defp parse_pool_size(nil), do: 5
  defp parse_pool_size(""), do: 5

  defp parse_pool_size(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {size, ""} when size > 0 -> size
      _ -> raise "PGPOOL must be a positive integer, got: #{inspect(value)}"
    end
  end

  # Returns the raised RuntimeError message, or "" when nothing raised (so a
  # missing raise fails the =~ assertion instead of crashing it).
  defp raised_message(fun) do
    fun.()
    ""
  rescue
    e in RuntimeError -> e.message
  end

  defp ensure_applications_started do
    for app <- [:telemetry, :db_connection, :ecto, :ecto_sql, :postgrex] do
      Application.ensure_all_started(app)
    end
  end

  defp check!(true, _name), do: :ok
  defp check!(false, name), do: raise("RepoHelper self-check failed: #{name}")
end
