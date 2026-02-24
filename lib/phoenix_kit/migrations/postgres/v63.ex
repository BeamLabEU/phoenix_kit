defmodule PhoenixKit.Migrations.Postgres.V63 do
  @moduledoc """
  V63: UUID Companion Column Safety Net — Round 2

  Adds missing `uuid` and `_uuid` FK companion columns identified after V62.
  All operations are idempotent — safe to run on any installation.

  ## Issues Fixed

  ### 1. `phoenix_kit_ai_accounts` missing `uuid` column

  V61 used the wrong table name in `@tables_missing_uuid` (listed
  `phoenix_kit_ai_requests` instead of `phoenix_kit_ai_accounts`). This
  left `ai_accounts` as the only legacy table without a `uuid` identity
  column.

  ### 2. `phoenix_kit_ai_requests` missing `account_uuid` companion

  The `account_id` integer FK had no UUID companion. Backfilled via JOIN
  to `phoenix_kit_ai_accounts` once that table has its `uuid` column.

  ### 3. `phoenix_kit_email_orphaned_events` missing `matched_email_log_uuid`

  The `matched_email_log_id` integer FK had no UUID companion. Backfilled
  via JOIN to `phoenix_kit_email_logs`.

  ### 4. `phoenix_kit_invoices` missing `subscription_uuid` companion

  The `subscription_id` integer FK had no UUID companion. Backfilled via
  JOIN to `phoenix_kit_subscriptions`.

  ### 5. `phoenix_kit_shop_cart_items` missing `variant_uuid` companion

  The `variant_id` integer FK had no UUID companion. No backfill possible
  (no variants table in schema); column added as nullable for future use.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # Flush any pending migration commands from earlier versions
    flush()

    # Ensure uuid_generate_v7() exists (created in V40, be defensive)
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

    # Flush so uuid_generate_v7() is available for subsequent queries
    flush()

    # 1. Add uuid column to ai_accounts (must come before account_uuid backfill)
    add_uuid_to_ai_accounts(prefix, escaped_prefix)

    # Flush so ai_accounts.uuid is visible for the JOIN backfill below
    flush()

    # 2. Add account_uuid companion to ai_requests
    add_account_uuid_to_ai_requests(prefix, escaped_prefix)

    # 3. Add matched_email_log_uuid companion to email_orphaned_events
    add_matched_email_log_uuid(prefix, escaped_prefix)

    # 4. Add subscription_uuid companion to invoices
    add_subscription_uuid_to_invoices(prefix, escaped_prefix)

    # 5. Add variant_uuid companion to shop_cart_items
    add_variant_uuid_to_cart_items(prefix, escaped_prefix)

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '63'")
  end

  def down(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    remove_column_if_exists(:phoenix_kit_shop_cart_items, :variant_uuid, prefix, escaped_prefix)
    remove_column_if_exists(:phoenix_kit_invoices, :subscription_uuid, prefix, escaped_prefix)

    remove_column_if_exists(
      :phoenix_kit_email_orphaned_events,
      :matched_email_log_uuid,
      prefix,
      escaped_prefix
    )

    remove_column_if_exists(:phoenix_kit_ai_requests, :account_uuid, prefix, escaped_prefix)
    remove_uuid_from_ai_accounts(prefix, escaped_prefix)

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '62'")
  end

  # ---------------------------------------------------------------------------
  # Individual fixups
  # ---------------------------------------------------------------------------

  defp add_uuid_to_ai_accounts(prefix, escaped_prefix) do
    table = :phoenix_kit_ai_accounts

    if table_exists?(table, escaped_prefix) and
         not column_exists?(table, :uuid, escaped_prefix) do
      table_name = prefix_table("phoenix_kit_ai_accounts", prefix)

      execute("ALTER TABLE #{table_name} ADD COLUMN uuid UUID DEFAULT uuid_generate_v7()")
      execute("UPDATE #{table_name} SET uuid = uuid_generate_v7() WHERE uuid IS NULL")

      execute("""
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_ai_accounts_uuid_idx
      ON #{table_name}(uuid)
      """)

      execute("ALTER TABLE #{table_name} ALTER COLUMN uuid SET NOT NULL")
    end
  end

  defp add_account_uuid_to_ai_requests(prefix, escaped_prefix) do
    table = :phoenix_kit_ai_requests

    if table_exists?(table, escaped_prefix) and
         not column_exists?(table, :account_uuid, escaped_prefix) do
      table_name = prefix_table("phoenix_kit_ai_requests", prefix)
      accounts_table = prefix_table("phoenix_kit_ai_accounts", prefix)

      execute("ALTER TABLE #{table_name} ADD COLUMN account_uuid UUID")

      # Backfill only if ai_accounts has uuid column (it should, we just added it)
      if column_exists?(:phoenix_kit_ai_accounts, :uuid, escaped_prefix) do
        execute("""
        UPDATE #{table_name} r
        SET account_uuid = a.uuid
        FROM #{accounts_table} a
        WHERE r.account_id = a.id
          AND r.account_uuid IS NULL
          AND r.account_id IS NOT NULL
        """)
      end

      execute("""
      CREATE INDEX IF NOT EXISTS phoenix_kit_ai_requests_account_uuid_idx
      ON #{table_name}(account_uuid)
      """)
    end
  end

  defp add_matched_email_log_uuid(prefix, escaped_prefix) do
    table = :phoenix_kit_email_orphaned_events

    if table_exists?(table, escaped_prefix) and
         not column_exists?(table, :matched_email_log_uuid, escaped_prefix) do
      table_name = prefix_table("phoenix_kit_email_orphaned_events", prefix)
      email_logs_table = prefix_table("phoenix_kit_email_logs", prefix)

      execute("ALTER TABLE #{table_name} ADD COLUMN matched_email_log_uuid UUID")

      if table_exists?(:phoenix_kit_email_logs, escaped_prefix) do
        execute("""
        UPDATE #{table_name} e
        SET matched_email_log_uuid = l.uuid
        FROM #{email_logs_table} l
        WHERE e.matched_email_log_id = l.id
          AND e.matched_email_log_uuid IS NULL
          AND e.matched_email_log_id IS NOT NULL
        """)
      end

      execute("""
      CREATE INDEX IF NOT EXISTS phoenix_kit_email_orphaned_events_matched_log_uuid_idx
      ON #{table_name}(matched_email_log_uuid)
      """)
    end
  end

  defp add_subscription_uuid_to_invoices(prefix, escaped_prefix) do
    table = :phoenix_kit_invoices

    if table_exists?(table, escaped_prefix) and
         not column_exists?(table, :subscription_uuid, escaped_prefix) do
      table_name = prefix_table("phoenix_kit_invoices", prefix)
      subscriptions_table = prefix_table("phoenix_kit_subscriptions", prefix)

      execute("ALTER TABLE #{table_name} ADD COLUMN subscription_uuid UUID")

      if table_exists?(:phoenix_kit_subscriptions, escaped_prefix) do
        execute("""
        UPDATE #{table_name} i
        SET subscription_uuid = s.uuid
        FROM #{subscriptions_table} s
        WHERE i.subscription_id = s.id
          AND i.subscription_uuid IS NULL
          AND i.subscription_id IS NOT NULL
        """)
      end

      execute("""
      CREATE INDEX IF NOT EXISTS phoenix_kit_invoices_subscription_uuid_idx
      ON #{table_name}(subscription_uuid)
      """)
    end
  end

  defp add_variant_uuid_to_cart_items(prefix, escaped_prefix) do
    table = :phoenix_kit_shop_cart_items

    if table_exists?(table, escaped_prefix) and
         not column_exists?(table, :variant_uuid, escaped_prefix) do
      table_name = prefix_table("phoenix_kit_shop_cart_items", prefix)

      # No variants table exists — add nullable column for future use
      execute("ALTER TABLE #{table_name} ADD COLUMN variant_uuid UUID")

      execute("""
      CREATE INDEX IF NOT EXISTS phoenix_kit_shop_cart_items_variant_uuid_idx
      ON #{table_name}(variant_uuid)
      """)
    end
  end

  defp remove_uuid_from_ai_accounts(prefix, escaped_prefix) do
    table = :phoenix_kit_ai_accounts

    if table_exists?(table, escaped_prefix) and
         column_exists?(table, :uuid, escaped_prefix) do
      table_name = prefix_table("phoenix_kit_ai_accounts", prefix)
      execute("DROP INDEX IF EXISTS phoenix_kit_ai_accounts_uuid_idx")
      execute("ALTER TABLE #{table_name} DROP COLUMN IF EXISTS uuid")
    end
  end

  defp remove_column_if_exists(table, column, prefix, escaped_prefix) do
    col_str = Atom.to_string(column)

    if table_exists?(table, escaped_prefix) and
         column_exists?(table, column, escaped_prefix) do
      table_name = prefix_table(Atom.to_string(table), prefix)
      execute("ALTER TABLE #{table_name} DROP COLUMN IF EXISTS #{col_str}")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers (same pattern as V61)
  # ---------------------------------------------------------------------------

  defp table_exists?(table, escaped_prefix) do
    table_name = Atom.to_string(table)

    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.tables
             WHERE table_name = '#{table_name}'
             AND table_schema = '#{escaped_prefix}'
           )
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp column_exists?(table, column, escaped_prefix) do
    table_name = Atom.to_string(table)
    column_name = Atom.to_string(column)

    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.columns
             WHERE table_name = '#{table_name}'
             AND column_name = '#{column_name}'
             AND table_schema = '#{escaped_prefix}'
           )
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_table(table_name, nil), do: table_name
  defp prefix_table(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table(table_name, prefix), do: "#{prefix}.#{table_name}"
end
