defmodule PhoenixKit.Migrations.Repair.Environment do
  @moduledoc """
  Spec §6.3's environment rules: pooled-connection detection and the
  advisory lock. `classify_config/1` is pure (the config-based half of
  `mix phoenix_kit.doctor`'s existing PgBouncer heuristic,
  `doctor.ex:174-195`, reused rather than re-derived); `pooled?/1` and the
  lock functions execute real queries and have no unit test.

  ## Detection is two-layered, on purpose

  Config alone (a non-5432 port, a hostname containing "pgbouncer") is a
  fast, always-available *hint* — it is what `mix phoenix_kit.doctor`
  already prints a warning from. It is not proof: a direct Postgres
  connection can legitimately run on a non-standard port, and a
  transaction-pooling proxy can sit behind a hostname that says nothing
  about it. The authoritative signal is behavioral: `pg_backend_pid()`
  sampled twice over the SAME checked-out connection, as two separate
  (non-transactional) statements. A direct connection — or a
  session-pooling proxy, which behaves like one for this purpose — answers
  with the same pid both times, because both statements ride the one
  physical server backend for as long as the connection is checked out.
  Transaction-pooling PgBouncer can hand each statement a different backend
  connection, because nothing binds them together outside an explicit
  transaction. `pooled?/1` therefore checks out **one** connection
  (`Ecto.Adapters.SQL.checkout/2`) before sampling — sampling via two plain
  `repo.query!/3` calls without checking out first would let *Ecto's own*
  pool (nothing to do with PgBouncer) hand the two queries to different
  workers and manufacture a false positive on a perfectly direct database.

  Config classification and pid-sampling are combined with OR: either one
  saying "pooled" is enough to require `--unsafe-pooled` — false positives
  (an operator has to pass one extra flag) are the safe failure direction;
  false negatives (skipping `VALIDATE`/the advisory lock against a pooled
  connection that fooled both checks) are not.
  """

  @typedoc "The config-only heuristic's verdict — a hint, never authoritative on its own."
  @type config_verdict :: :maybe_pooled | :direct

  @doc """
  The config-based half of the detection (`doctor.ex`'s existing heuristic,
  reused verbatim): a non-`5432` port, or a hostname containing
  `"pgbouncer"`, is `:maybe_pooled`.

      iex> Environment.classify_config(port: 5432, hostname: "db.internal")
      :direct
      iex> Environment.classify_config(port: 6432, hostname: "db.internal")
      :maybe_pooled
      iex> Environment.classify_config(port: 5432, hostname: "pgbouncer.internal")
      :maybe_pooled
      iex> Environment.classify_config(url: "ecto://user:pass@pgbouncer:6432/db")
      :maybe_pooled
  """
  @spec classify_config(keyword()) :: config_verdict()
  def classify_config(config) do
    port =
      cond do
        config[:port] -> config[:port]
        config[:url] -> extract_port_from_url(config[:url])
        true -> 5432
      end

    hostname = config[:hostname] || extract_host_from_url(config[:url]) || "localhost"

    if port != 5432 or String.contains?(to_string(hostname), "pgbouncer") do
      :maybe_pooled
    else
      :direct
    end
  end

  defp extract_port_from_url(nil), do: nil

  defp extract_port_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{port: port} when is_integer(port) -> port
      _ -> nil
    end
  end

  defp extract_host_from_url(nil), do: nil

  defp extract_host_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  @doc """
  The authoritative, behavioral check — see moduledoc. Checks out one
  connection and compares `pg_backend_pid()` across two separate statements
  on it. Fails toward `true` (pooled, the safer assumption) on any error —
  an environment we cannot prove is direct is treated as pooled, never the
  other way around.
  """
  @spec pooled?(Ecto.Repo.t()) :: boolean()
  def pooled?(repo) do
    repo.checkout(fn ->
      first = backend_pid!(repo)
      second = backend_pid!(repo)
      first != second
    end)
  rescue
    _ -> true
  catch
    _, _ -> true
  end

  defp backend_pid!(repo) do
    %{rows: [[pid]]} = repo.query!("SELECT pg_backend_pid()", [], log: false)
    pid
  end

  @doc """
  Combines `classify_config/1` and `pooled?/1` with OR (see moduledoc).
  `config` is the repo's `Application.get_env(app, repo, [])` keyword list.
  """
  @spec pooled?(Ecto.Repo.t(), keyword()) :: boolean()
  def pooled?(repo, config) do
    classify_config(config) == :maybe_pooled or pooled?(repo)
  end

  # A 64-bit key derived from a fixed string, so it reads as intentional in
  # `pg_stat_activity`/`pg_locks` rather than an arbitrary magic number.
  # Shared with `PhoenixKit.Migrations.Postgres.up/1` and `.down/1` (spec
  # §6.1), which take it as `pg_advisory_xact_lock/1` rather than the
  # session-level form used here. The two contend on the same key, but only in
  # ONE direction: a chain run waits behind a repair that already holds this
  # lock, while a repair started mid-chain-run is not blocked, because the
  # generated wrappers disable their DDL transaction so the migration side's
  # lock is released after its own statement. See
  # `Postgres.acquire_chain_lock!/0` for why a session lock there is not the
  # answer. Exclusion also requires a direct connection on BOTH sides, so
  # `PhoenixKit.Migrations.CommentPolicy.concurrent_migration?/2`'s
  # before/after comment re-read (S18) remains the backstop for the pooled
  # case and for the unprotected direction.
  @lock_key :erlang.crc32("phoenix_kit.migrations.repair")

  @doc "The advisory lock key repair uses — exposed for tests/diagnostics, never meant to be passed elsewhere."
  @spec lock_key() :: non_neg_integer()
  def lock_key, do: @lock_key

  @doc """
  Acquires `lock_key/0` (session-level `pg_advisory_lock/1`, blocking) on
  `repo`'s checked-out connection, runs `fun`, then releases it — even if
  `fun` raises. Must run on a **direct** connection (§6.3): PgBouncer in
  transaction-pooling mode can hand the lock and unlock calls to different
  backend connections, silently defeating it. `--unsafe-pooled` skips
  calling this at all (`PhoenixKit.Migrations.Repair` never calls
  `with_lock/2` when the environment was classified pooled and the flag was
  given).
  """
  @spec with_lock(Ecto.Repo.t(), (-> result)) :: result when result: term()
  def with_lock(repo, fun) do
    repo.checkout(fn ->
      repo.query!("SELECT pg_advisory_lock($1)", [@lock_key], log: false)

      try do
        fun.()
      after
        repo.query!("SELECT pg_advisory_unlock($1)", [@lock_key], log: false)
      end
    end)
  end
end
