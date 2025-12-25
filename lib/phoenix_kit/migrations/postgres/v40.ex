defmodule PhoenixKit.Migrations.Postgres.V40 do
  @moduledoc """
  PhoenixKit V40 Migration: UUID Column Addition for Legacy Tables

  This migration adds UUID columns to all legacy tables that currently use
  bigserial primary keys. This is Phase 1 of the graceful UUID migration
  strategy, designed to be completely non-breaking for existing installations.

  ## Strategy

  This migration is designed to work with PhoenixKit as a library dependency:
  - **Non-breaking**: Only adds new columns, doesn't change existing PKs
  - **Backward compatible**: Existing code using integer IDs continues to work
  - **Forward compatible**: New code can start using UUIDs immediately
  - **Optional module aware**: Skips tables that don't exist (disabled modules)

  ## Changes

  For each of the 33 legacy tables:
  1. Adds a `uuid` column (UUID type, using UUIDv7 for time-ordering)
  2. Backfills existing records with generated UUIDv7 values
  3. Creates a unique index on the uuid column
  4. Sets the column to NOT NULL after backfill
  5. Keeps DEFAULT for database-level inserts (Ecto changesets override with UUIDv7)

  ## UUIDv7

  This migration uses UUIDv7 (time-ordered UUIDs) which provide:
  - Time-based ordering (first 48 bits are Unix timestamp in milliseconds)
  - Better index locality than random UUIDs
  - Sortable by creation time
  - Compatible with standard UUID format

  A PostgreSQL function `uuid_generate_v7()` is created to generate UUIDv7
  values at the database level.

  ## Tables Affected

  ### Core Auth (V01)
  - phoenix_kit_users
  - phoenix_kit_users_tokens
  - phoenix_kit_user_roles
  - phoenix_kit_user_role_assignments

  ### Settings & Referrals (V03-V04)
  - phoenix_kit_settings
  - phoenix_kit_referral_codes
  - phoenix_kit_referral_code_usage

  ### Email System (V07, V09, V15, V22)
  - phoenix_kit_email_logs
  - phoenix_kit_email_events
  - phoenix_kit_email_blocklist
  - phoenix_kit_email_templates
  - phoenix_kit_email_orphaned_events
  - phoenix_kit_email_metrics

  ### OAuth (V16)
  - phoenix_kit_user_oauth_providers

  ### Entities (V17)
  - phoenix_kit_entities
  - phoenix_kit_entity_data

  ### Audit (V22)
  - phoenix_kit_audit_logs

  ### Billing (V31, V33)
  - phoenix_kit_currencies
  - phoenix_kit_billing_profiles
  - phoenix_kit_orders
  - phoenix_kit_invoices
  - phoenix_kit_transactions
  - phoenix_kit_payment_methods
  - phoenix_kit_subscription_plans
  - phoenix_kit_subscriptions
  - phoenix_kit_payment_provider_configs
  - phoenix_kit_webhook_events

  ### AI System (V32, V34, V38)
  - phoenix_kit_ai_endpoints
  - phoenix_kit_ai_requests
  - phoenix_kit_ai_prompts

  ### DB Sync (V37)
  - phoenix_kit_db_sync_connections
  - phoenix_kit_db_sync_transfers

  ### Admin Notes (V39)
  - phoenix_kit_admin_notes

  ## Performance Considerations

  - Uses batched updates for large tables to avoid long locks
  - Checks table existence before migration (for optional modules)
  - UUIDv7 provides better index performance than random UUIDs

  ## Usage

      # Migrate up
      PhoenixKit.Migrations.Postgres.up(prefix: "public", version: 40)

      # Rollback
      PhoenixKit.Migrations.Postgres.down(prefix: "public", version: 39)
  """
  use Ecto.Migration

  @tables_to_migrate [
    # Core Auth (V01)
    :phoenix_kit_users,
    :phoenix_kit_users_tokens,
    :phoenix_kit_user_roles,
    :phoenix_kit_user_role_assignments,
    # Settings & Referrals (V03-V04)
    :phoenix_kit_settings,
    :phoenix_kit_referral_codes,
    :phoenix_kit_referral_code_usage,
    # Email System (V07, V09, V15, V22)
    :phoenix_kit_email_logs,
    :phoenix_kit_email_events,
    :phoenix_kit_email_blocklist,
    :phoenix_kit_email_templates,
    :phoenix_kit_email_orphaned_events,
    :phoenix_kit_email_metrics,
    # OAuth (V16)
    :phoenix_kit_user_oauth_providers,
    # Entities (V17)
    :phoenix_kit_entities,
    :phoenix_kit_entity_data,
    # Audit (V22)
    :phoenix_kit_audit_logs,
    # Billing (V31, V33)
    :phoenix_kit_currencies,
    :phoenix_kit_billing_profiles,
    :phoenix_kit_orders,
    :phoenix_kit_invoices,
    :phoenix_kit_transactions,
    :phoenix_kit_payment_methods,
    :phoenix_kit_subscription_plans,
    :phoenix_kit_subscriptions,
    :phoenix_kit_payment_provider_configs,
    :phoenix_kit_webhook_events,
    # AI System (V32, V34, V38)
    :phoenix_kit_ai_endpoints,
    :phoenix_kit_ai_requests,
    :phoenix_kit_ai_prompts,
    # DB Sync (V37)
    :phoenix_kit_db_sync_connections,
    :phoenix_kit_db_sync_transfers,
    # Admin Notes (V39)
    :phoenix_kit_admin_notes
  ]

  # Tables that may have large amounts of data and need batched updates
  @large_tables [
    :phoenix_kit_users,
    :phoenix_kit_users_tokens,
    :phoenix_kit_email_logs,
    :phoenix_kit_email_events,
    :phoenix_kit_audit_logs,
    :phoenix_kit_entity_data,
    :phoenix_kit_ai_requests
  ]

  # Batch size for large table updates
  @batch_size 10_000

  @doc """
  Run the V40 migration to add UUID columns to all legacy tables.
  """
  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # Step 1: Ensure pgcrypto extension exists
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")

    # Step 2: Create UUIDv7 generation function if it doesn't exist
    # UUIDv7 format: timestamp (48 bits) + version (4 bits) + random (12 bits) + variant (2 bits) + random (62 bits)
    execute("""
    CREATE OR REPLACE FUNCTION uuid_generate_v7()
    RETURNS uuid AS $$
    DECLARE
      unix_ts_ms bytea;
      uuid_bytes bytea;
    BEGIN
      -- Get current timestamp in milliseconds
      unix_ts_ms := substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);

      -- Build UUIDv7: 6 bytes timestamp + 2 bytes random (with version) + 8 bytes random (with variant)
      uuid_bytes := unix_ts_ms || gen_random_bytes(10);

      -- Set version 7 (0111xxxx in byte 7)
      uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);

      -- Set variant (10xxxxxx in byte 9)
      uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);

      RETURN encode(uuid_bytes, 'hex')::uuid;
    END
    $$ LANGUAGE plpgsql VOLATILE;
    """)

    # Step 3: Process each table
    for table <- @tables_to_migrate do
      add_uuid_column_to_table(table, prefix, escaped_prefix)
    end

    # Step 4: Update version comment
    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '40'")
  end

  @doc """
  Rollback the V40 migration by removing UUID columns.
  """
  def down(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # Remove UUID columns from all tables (in reverse order)
    for table <- Enum.reverse(@tables_to_migrate) do
      remove_uuid_column_from_table(table, prefix, escaped_prefix)
    end

    # Update version comment
    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '39'")
  end

  # Add UUID column to a single table with all safety checks
  defp add_uuid_column_to_table(table, prefix, escaped_prefix) do
    table_name = prefix_table_name(Atom.to_string(table), prefix)

    # Check if table exists (for optional modules that might not be enabled)
    if table_exists?(table, escaped_prefix) do
      # Check if uuid column already exists (idempotency)
      unless column_exists?(table, :uuid, escaped_prefix) do
        # Step 1: Add UUID column with UUIDv7 default
        # The default ensures database-level inserts work correctly.
        # Ecto changesets will generate UUIDv7 in Elixir, which takes precedence.
        execute("""
        ALTER TABLE #{table_name}
        ADD COLUMN uuid UUID DEFAULT uuid_generate_v7()
        """)

        # Step 2: Backfill existing records with UUIDv7
        # Use batched updates for large tables to avoid long locks
        if table in @large_tables do
          backfill_uuids_batched(table_name)
        else
          # Small tables can be updated in one go
          execute("""
          UPDATE #{table_name}
          SET uuid = uuid_generate_v7()
          WHERE uuid IS NULL
          """)
        end

        # Step 3: Create unique index
        execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS #{table}_uuid_idx
        ON #{table_name}(uuid)
        """)

        # Step 4: Set NOT NULL constraint after backfill
        execute("""
        ALTER TABLE #{table_name}
        ALTER COLUMN uuid SET NOT NULL
        """)

        # Note: We KEEP the DEFAULT so database-level inserts continue to work.
        # This is important for backward compatibility with code that doesn't
        # explicitly set the uuid field. Ecto changesets will generate UUIDv7
        # in Elixir, which takes precedence over the default.
      end
    end
  end

  # Backfill UUIDs in batches to avoid long locks on large tables
  defp backfill_uuids_batched(table_name) do
    # Use a loop to update in batches
    # This is done via a DO block to handle it in a single migration step
    execute("""
    DO $$
    DECLARE
      batch_count INTEGER := 0;
      updated_rows INTEGER;
    BEGIN
      LOOP
        UPDATE #{table_name}
        SET uuid = uuid_generate_v7()
        WHERE id IN (
          SELECT id FROM #{table_name}
          WHERE uuid IS NULL
          LIMIT #{@batch_size}
        );

        GET DIAGNOSTICS updated_rows = ROW_COUNT;
        batch_count := batch_count + 1;

        -- Exit when no more rows to update
        EXIT WHEN updated_rows = 0;

        -- Small delay between batches to reduce lock contention
        PERFORM pg_sleep(0.01);
      END LOOP;
    END $$;
    """)
  end

  # Remove UUID column from a single table
  defp remove_uuid_column_from_table(table, prefix, escaped_prefix) do
    table_name = prefix_table_name(Atom.to_string(table), prefix)

    if table_exists?(table, escaped_prefix) and column_exists?(table, :uuid, escaped_prefix) do
      # Drop index first (handle nil prefix properly)
      index_name = prefix_index_name(table, prefix)

      execute("""
      DROP INDEX IF EXISTS #{index_name}
      """)

      # Drop column
      execute("""
      ALTER TABLE #{table_name}
      DROP COLUMN IF EXISTS uuid
      """)
    end
  end

  # Helper to build prefixed index name, handling nil prefix
  defp prefix_index_name(table, nil), do: "#{table}_uuid_idx"
  defp prefix_index_name(table, "public"), do: "public.#{table}_uuid_idx"
  defp prefix_index_name(table, prefix), do: "#{prefix}.#{table}_uuid_idx"

  # Check if a table exists in the database
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

  # Check if a column exists in a table
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

  # Helper to build prefixed table name
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
