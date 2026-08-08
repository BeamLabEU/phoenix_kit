defmodule PhoenixKit.Migrations.Repair.ObanRunner do
  @moduledoc """
  Runs `Oban.Migration.up/1` outside of an actual chain migration — the
  mechanics behind `PhoenixKit.Migrations.Repair`'s Oban delegation step
  (spec §6.1; see `Repair`'s moduledoc "What this pipeline does NOT (yet)
  do" and the `delegate_oban/2` call site).

  ## Why this exists

  `Oban.Migration.up/1` is written to run *inside* a real `Ecto.Migration`
  (`use Ecto.Migration` internally, calling `execute/1` to queue its DDL) —
  it needs an active `Ecto.Migration.Runner` process to talk to. Normally
  that Runner is supplied by `Ecto.Migrator.run/4` wrapping a real,
  file-backed migration module (this is exactly how `Postgres.V135` already
  delegates to Oban, inside the real chain — originally V27's idiom, folded
  into the V135 baseline by the squash). `PhoenixKit.Migrations.Repair`
  is not a migration, though — it is ordinary application code invoked from
  `mix phoenix_kit.repair`/`mix phoenix_kit.doctor` or a LiveView action —
  so there is no Runner in scope, and calling `Oban.Migration.up/1` directly
  raises `"could not find migration runner process for #<pid>"`.

  `Ecto.Migrator.up/4` would supply a Runner, but only as a side effect of
  also inserting a `schema_migrations` row — bookkeeping PhoenixKit's own
  chain does not use at all (its version marker is the `phoenix_kit` table's
  `COMMENT`, spec §6.1) and that a repair run must not create as an
  unrelated, surprising side effect (nor does it want to require a
  `schema_migrations` table to exist in an arbitrary prefix in the first
  place). `Ecto.Migration.Runner.run/8` is the lower-level primitive
  `Ecto.Migrator` itself calls *after* that bookkeeping — calling it
  directly here gives `Oban.Migration.up/1` a real Runner with none of it.

  `change/0` cannot take an argument (`Runner`'s `perform_operation/3`
  always calls `apply(module, operation, [])`), so it reads its prefix from
  the ambient `Ecto.Migration.prefix/0` — the value `Runner.run/8` seeds
  from its own `opts[:prefix]` before ever invoking `change/0`.
  """

  use Ecto.Migration

  alias Ecto.Migration.Runner

  @doc false
  def change, do: Oban.Migration.up(prefix: prefix(), create_schema: false)

  @doc """
  Runs `Oban.Migration.up/1` against `prefix` on `repo`, bootstrapping the
  `Ecto.Migration.Runner` context it needs (see moduledoc) and tearing it
  down again afterward — no `schema_migrations` row, no other side effect
  beyond whatever DDL `Oban.Migration.up/1` itself queues. Raises on
  failure exactly like a real migration would; the DDL Oban's migration
  queues via `execute/1` still runs immediately, autocommit, matching every
  other statement `PhoenixKit.Migrations.Repair.Executor` issues.
  `PhoenixKit.Migrations.Repair.delegate_oban/2` is the caller that turns a
  raised error into an `:oban_delegation_failed` finding instead of
  crashing the whole repair run.
  """
  @spec up(Ecto.Repo.t(), String.t()) :: :ok
  def up(repo, prefix) do
    Runner.run(repo, repo.config(), 0, __MODULE__, :forward, :change, :up,
      prefix: prefix,
      log: false
    )

    :ok
  end
end
