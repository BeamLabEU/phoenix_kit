defmodule PhoenixKit.Migrations.Postgres.V61 do
  @moduledoc """
  V61: UUID Column Safety Net for Tables Missed by V40

  ## Root Cause

  V40 adds a `uuid` column to 33 legacy tables, but uses `repo().query()`
  for its `table_exists?` checks. In Ecto migrations, `repo().query()` is
  executed immediately against the database, while migration commands
  (`execute`, `create`, `alter`) are **buffered** until `flush()` or
  callback return.

  During a fresh install (V01→V49 in one Ecto migration), V31 calls
  `flush()` — making V01–V31 tables visible — but V32–V39 tables remain
  buffered when V40 runs. V40 therefore skips all V32+ tables.

  V56 added a safety net for 6 of these tables:
  - consent_logs, payment_methods, ai_endpoints, ai_prompts,
    sync_connections, subscription_plans

  This migration covers the remaining 6 tables that V40 missed and V56
  did not catch:

  ## Tables Fixed

  | Table | Created in | Why missed |
  |-------|-----------|------------|
  | `phoenix_kit_admin_notes` | V39 | After V31 flush, before V40 |
  | `phoenix_kit_ai_requests` | V32 | After V31 flush, before V40 |
  | `phoenix_kit_subscriptions` | V33 | After V31 flush, before V40 |
  | `phoenix_kit_payment_provider_configs` | V33 | After V31 flush, before V40 |
  | `phoenix_kit_webhook_events` | V33 | After V31 flush, before V40 |
  | `phoenix_kit_sync_transfers` | V37/V44 | After V31 flush, before V40 |

  ## Additional Fix

  Adds `created_by_uuid` FK column to `phoenix_kit_scheduled_jobs` (V42).
  This table uses a UUID native PK so it doesn't need a `uuid` identity
  column, but its `created_by_id` integer FK was missing its UUID companion.

  ## Permanent Fix

  V40 has been updated with `flush()` at the start of `up()` so this
  issue cannot recur on new installations.

  All operations are idempotent — safe to run on any installation.
  """

  use Ecto.Migration

  @tables_missing_uuid [
    :phoenix_kit_admin_notes,
    :phoenix_kit_ai_requests,
    :phoenix_kit_subscriptions,
    :phoenix_kit_payment_provider_configs,
    :phoenix_kit_webhook_events,
    :phoenix_kit_sync_transfers
  ]

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # Flush any pending commands from earlier versions
    flush()

    # Ensure uuid_generate_v7() exists (created in V40, but be safe)
    execute("""
    CREATE OR REPLACE FUNCTION uuid_generate_v7()
    RETURNS uuid AS $$
    DECLARE
      unix_ts_ms bytea;
      uuid_bytes bytea;
    BEGIN
      unix_ts_ms := substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);
      uuid_bytes := unix_ts_ms || gen_random_bytes(10);
      uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);
      uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);
      RETURN encode(uuid_bytes, 'hex')::uuid;
    END
    $$ LANGUAGE plpgsql VOLATILE;
    """)

    # Need to flush uuid_generate_v7() creation before using it
    flush()

    # Add uuid column to each missing table
    for table <- @tables_missing_uuid do
      add_uuid_column(table, prefix, escaped_prefix)
    end

    # Add created_by_uuid FK to scheduled_jobs
    add_created_by_uuid_to_scheduled_jobs(prefix, escaped_prefix)

    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '61'")
  end

  def down(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # Remove created_by_uuid from scheduled_jobs
    remove_created_by_uuid_from_scheduled_jobs(prefix, escaped_prefix)

    # Remove uuid columns (in reverse order)
    for table <- Enum.reverse(@tables_missing_uuid) do
      remove_uuid_column(table, prefix, escaped_prefix)
    end

    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '60'")
  end

  defp add_uuid_column(table, prefix, escaped_prefix) do
    table_name = prefix_table_name(Atom.to_string(table), prefix)

    if table_exists?(table, escaped_prefix) do
      unless column_exists?(table, :uuid, escaped_prefix) do
        execute("""
        ALTER TABLE #{table_name}
        ADD COLUMN uuid UUID DEFAULT uuid_generate_v7()
        """)

        execute("""
        UPDATE #{table_name}
        SET uuid = uuid_generate_v7()
        WHERE uuid IS NULL
        """)

        execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS #{table}_uuid_idx
        ON #{table_name}(uuid)
        """)

        execute("""
        ALTER TABLE #{table_name}
        ALTER COLUMN uuid SET NOT NULL
        """)
      end
    end
  end

  defp remove_uuid_column(table, prefix, escaped_prefix) do
    table_name = prefix_table_name(Atom.to_string(table), prefix)

    if table_exists?(table, escaped_prefix) and column_exists?(table, :uuid, escaped_prefix) do
      index_name = prefix_index_name(table, prefix)
      execute("DROP INDEX IF EXISTS #{index_name}")

      execute("""
      ALTER TABLE #{table_name}
      DROP COLUMN IF EXISTS uuid
      """)
    end
  end

  defp add_created_by_uuid_to_scheduled_jobs(prefix, escaped_prefix) do
    table = :phoenix_kit_scheduled_jobs

    if table_exists?(table, escaped_prefix) do
      unless column_exists?(table, :created_by_uuid, escaped_prefix) do
        table_name = prefix_table_name("phoenix_kit_scheduled_jobs", prefix)

        execute("""
        ALTER TABLE #{table_name}
        ADD COLUMN created_by_uuid UUID
        """)

        # Backfill from users table
        users_table = prefix_table_name("phoenix_kit_users", prefix)

        execute("""
        UPDATE #{table_name} t
        SET created_by_uuid = u.uuid
        FROM #{users_table} u
        WHERE t.created_by_id = u.id
        AND t.created_by_uuid IS NULL
        AND t.created_by_id IS NOT NULL
        """)

        execute("""
        CREATE INDEX IF NOT EXISTS phoenix_kit_scheduled_jobs_created_by_uuid_idx
        ON #{table_name}(created_by_uuid)
        """)
      end
    end
  end

  defp remove_created_by_uuid_from_scheduled_jobs(prefix, escaped_prefix) do
    table = :phoenix_kit_scheduled_jobs

    if table_exists?(table, escaped_prefix) and
         column_exists?(table, :created_by_uuid, escaped_prefix) do
      table_name = prefix_table_name("phoenix_kit_scheduled_jobs", prefix)

      execute("""
      DROP INDEX IF EXISTS phoenix_kit_scheduled_jobs_created_by_uuid_idx
      """)

      execute("""
      ALTER TABLE #{table_name}
      DROP COLUMN IF EXISTS created_by_uuid
      """)
    end
  end

  # Helpers

  defp table_exists?(table, escaped_prefix) do
    table_name = Atom.to_string(table)

    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = '#{table_name}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp column_exists?(table, column, escaped_prefix) do
    table_name = Atom.to_string(table)
    column_name = Atom.to_string(column)

    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.columns
      WHERE table_name = '#{table_name}'
      AND column_name = '#{column_name}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"

  defp prefix_index_name(table, nil), do: "#{table}_uuid_idx"
  defp prefix_index_name(table, "public"), do: "#{table}_uuid_idx"
  defp prefix_index_name(table, prefix), do: "#{prefix}_#{table}_uuid_idx"
end
