defmodule PhoenixKit.Migrations.Postgres.V228 do
  @moduledoc """
  V228: a lease on a file for the reconciler, held in its row.

  Two additive columns on `phoenix_kit_files`:

    * **`reconcile_lock_token`** (`uuid`, `NULL`): who holds the file, a token
      the holder made;
    * **`reconcile_locked_until`** (`timestamp(0)`, `NULL`): until when. The
      holder renews it while it works; a holder that dies leaves it to run out.

  `Storage.Reconciler.with_file_lock/2` takes the lease with one conditional
  `UPDATE` and gives it back with another, so no database connection is held
  while a file's objects are copied. It replaces an advisory lock: a session
  advisory lock is unreliable behind PgBouncer in transaction pooling (the
  unlock can reach another server connection), and a transaction one pins a
  pooled server connection for as long as a copy takes.

  ## Locks

  Two `ADD COLUMN`s with no default: catalog-only, bounded by `lock_timeout`.
  No backfill (no file is held). Re-runnable.

  ## Down

  Drops both columns. A reconciler of this version then cannot lock files;
  roll the code back with the schema.
  """
  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V228 back: both lease columns go."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "SET lock_timeout = '5000ms'",
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS reconcile_lock_token uuid",
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS reconcile_locked_until timestamp(0) without time zone",
      "RESET lock_timeout",
      "COMMENT ON TABLE #{p}phoenix_kit IS '228'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS reconcile_locked_until",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS reconcile_lock_token",
      "COMMENT ON TABLE #{p}phoenix_kit IS '227'"
    ]
  end
end
