defmodule PhoenixKit.Migrations.Postgres.V56 do
  @moduledoc """
  V56: UUID Column Consistency Fix

  Comprehensive fix for UUID column issues across all PhoenixKit tables.
  Ensures every table with a uuid column has:
  - DEFAULT uuid_generate_v7() (not gen_random_uuid())
  - NOT NULL constraint
  - Unique index

  Also adds the missing uuid column to `phoenix_kit_consent_logs` (V43 schema
  expects it but the migration never created it).

  All operations are idempotent — safe to run on fresh installs where V40
  already set things up correctly, and on upgrades where uuid_repair.ex or
  V45/V46/V53 left columns in an inconsistent state.

  Existing UUID values are NOT changed — they remain valid UUIDs regardless
  of version. Only defaults, constraints, and indexes are updated.

  ## Issues Fixed

  ### 1. Wrong DEFAULT (gen_random_uuid → uuid_generate_v7)
  V45, V46, V53, and V55 used `gen_random_uuid()` (UUIDv4) instead of the
  `uuid_generate_v7()` function created in V40.

  Additionally, `uuid_repair.ex` (pre-1.7.0 upgrade path) adds uuid columns
  with `gen_random_uuid()`, and V40 then skips those tables because the column
  already exists — leaving them with the wrong default.

  ### 2. Missing NOT NULL constraint
  V46 and V53 tables, plus uuid_repair.ex tables, may have nullable uuid columns.

  ### 3. Missing unique indexes
  V45 tables and uuid_repair.ex tables may lack a unique index on the uuid column.

  ### 4. Missing uuid column entirely
  V43 created `phoenix_kit_consent_logs` without a uuid column, but the Ecto
  schema (`consent_log.ex`) declares `field :uuid, Ecto.UUID, read_after_writes: true`.

  ### 5. Wrong DEFAULT on UUID primary keys (gen_random_uuid → uuid_generate_v7)
  V55 Comments module tables use UUID as primary key with `gen_random_uuid()`.
  These need the same DEFAULT fix but on the `id` column instead of `uuid`.

  ## Tables Fixed

  ### V43 — Legal Module (missing uuid column entirely)
  - phoenix_kit_consent_logs

  ### V45 — Shop Module (DEFAULT + unique index)
  - phoenix_kit_shop_categories
  - phoenix_kit_shop_products
  - phoenix_kit_shop_shipping_methods
  - phoenix_kit_shop_carts
  - phoenix_kit_shop_cart_items
  - phoenix_kit_payment_options

  ### V46 — Shop Extensions (DEFAULT + NOT NULL)
  - phoenix_kit_shop_config
  - phoenix_kit_shop_import_logs
  - phoenix_kit_shop_import_configs

  ### V53 — Permissions (DEFAULT + NOT NULL)
  - phoenix_kit_role_permissions

  ### V55 — Comments Module (DEFAULT on UUID primary key)
  - phoenix_kit_comments
  - phoenix_kit_comments_likes
  - phoenix_kit_comments_dislikes

  ### uuid_repair.ex path — Core tables (DEFAULT + NOT NULL + unique index)
  These are only affected on pre-1.7.0 upgrades where uuid_repair.ex ran before
  V40, causing V40 to skip them. On fresh installs V40 handles them correctly,
  and the operations here are no-ops.
  - phoenix_kit_users
  - phoenix_kit_users_tokens
  - phoenix_kit_user_roles
  - phoenix_kit_user_role_assignments
  - phoenix_kit_settings
  - phoenix_kit_email_templates
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.UUIDFKColumns

  # Tables missing the uuid column entirely (schema expects it, migration never created it)
  @tables_missing_column [
    :phoenix_kit_consent_logs
  ]

  # Tables using UUID as primary key with wrong DEFAULT (V55 Comments module)
  @tables_fix_uuid_pk [
    :phoenix_kit_comments,
    :phoenix_kit_comments_likes,
    :phoenix_kit_comments_dislikes
  ]

  # All tables that may have the wrong DEFAULT (includes tables that need the column added)
  @all_tables [
    # V43 — Legal (column added by this migration)
    :phoenix_kit_consent_logs,
    # V45 — Shop Module
    :phoenix_kit_shop_categories,
    :phoenix_kit_shop_products,
    :phoenix_kit_shop_shipping_methods,
    :phoenix_kit_shop_carts,
    :phoenix_kit_shop_cart_items,
    :phoenix_kit_payment_options,
    # V46 — Shop Extensions
    :phoenix_kit_shop_config,
    :phoenix_kit_shop_import_logs,
    :phoenix_kit_shop_import_configs,
    # V53 — Permissions
    :phoenix_kit_role_permissions,
    # uuid_repair.ex path — Core tables
    :phoenix_kit_users,
    :phoenix_kit_users_tokens,
    :phoenix_kit_user_roles,
    :phoenix_kit_user_role_assignments,
    :phoenix_kit_settings,
    :phoenix_kit_email_templates
  ]

  # Tables that may have nullable uuid columns
  @tables_ensure_not_null [
    # V43 table (column added by this migration)
    :phoenix_kit_consent_logs,
    # V46 tables (created nullable)
    :phoenix_kit_shop_config,
    :phoenix_kit_shop_import_logs,
    :phoenix_kit_shop_import_configs,
    # V53 table (created nullable)
    :phoenix_kit_role_permissions,
    # uuid_repair.ex tables (no NOT NULL added)
    :phoenix_kit_users,
    :phoenix_kit_users_tokens,
    :phoenix_kit_user_roles,
    :phoenix_kit_user_role_assignments,
    :phoenix_kit_settings,
    :phoenix_kit_email_templates
  ]

  # Tables that may be missing a unique index on uuid
  @tables_ensure_index [
    # V43 table (column added by this migration)
    :phoenix_kit_consent_logs,
    # V45 tables (no unique index created)
    :phoenix_kit_shop_categories,
    :phoenix_kit_shop_products,
    :phoenix_kit_shop_shipping_methods,
    :phoenix_kit_shop_carts,
    :phoenix_kit_shop_cart_items,
    :phoenix_kit_payment_options,
    # uuid_repair.ex tables (no index created)
    :phoenix_kit_users,
    :phoenix_kit_users_tokens,
    :phoenix_kit_user_roles,
    :phoenix_kit_user_role_assignments,
    :phoenix_kit_settings,
    :phoenix_kit_email_templates
  ]

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # Ensure uuid_generate_v7() function exists (created in V40, but be safe)
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

    # Fix 0: Add missing uuid columns (V43 consent_logs)
    for table <- @tables_missing_column do
      add_uuid_column(table, prefix, escaped_prefix)
    end

    # Fix 1: Ensure correct DEFAULT on all tables
    for table <- @all_tables do
      fix_uuid_default(table, prefix, escaped_prefix)
    end

    # Fix 2: Backfill NULL uuids and ensure NOT NULL constraint
    for table <- @tables_ensure_not_null do
      fix_not_null(table, prefix, escaped_prefix)
    end

    # Fix 3: Ensure unique index exists
    for table <- @tables_ensure_index do
      fix_unique_index(table, prefix, escaped_prefix)
    end

    # Fix 4: Fix UUID primary key defaults (V55 Comments tables)
    for table <- @tables_fix_uuid_pk do
      fix_uuid_pk_default(table, prefix, escaped_prefix)
    end

    # Fix 5: Add UUID FK columns alongside integer FKs
    UUIDFKColumns.up(opts)

    # Fix 6: Add NOT NULL + FK constraints on UUID FK columns
    UUIDFKColumns.add_constraints(opts)

    # Fix 7: Add unique indexes on UUID FK columns (needed for ON CONFLICT in Ecto)
    add_uuid_unique_indexes(prefix, escaped_prefix)

    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '56'")
  end

  def down(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # Revert Fix 7: Drop UUID unique indexes
    drop_uuid_unique_indexes(prefix, escaped_prefix)

    # Revert Fix 6: Drop FK constraints + NOT NULL before dropping columns
    UUIDFKColumns.drop_constraints(opts)

    # Revert Fix 5: Drop UUID FK columns
    UUIDFKColumns.down(opts)

    # Only revert V45/V46/V53 tables (not the uuid_repair core tables,
    # which should have been correct from V40 on most installs)

    # Revert unique indexes for V45 tables only
    for table <- v45_tables() do
      revert_unique_index(table, prefix, escaped_prefix)
    end

    # Revert NOT NULL for V46 + V53 tables only
    for table <- v46_v53_tables() do
      revert_not_null(table, prefix, escaped_prefix)
    end

    # Revert DEFAULT for V45/V46/V53 tables only
    for table <- v45_v46_v53_tables() do
      revert_uuid_default(table, prefix, escaped_prefix)
    end

    # Revert UUID PK defaults for V55 Comments tables
    for table <- @tables_fix_uuid_pk do
      revert_uuid_pk_default(table, prefix, escaped_prefix)
    end

    # Drop uuid column from tables where we added it
    for table <- @tables_missing_column do
      drop_uuid_column(table, prefix, escaped_prefix)
    end

    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '55'")
  end

  # Table groups for rollback (don't revert core table fixes)
  defp v45_tables do
    [
      :phoenix_kit_shop_categories,
      :phoenix_kit_shop_products,
      :phoenix_kit_shop_shipping_methods,
      :phoenix_kit_shop_carts,
      :phoenix_kit_shop_cart_items,
      :phoenix_kit_payment_options
    ]
  end

  defp v46_v53_tables do
    [
      :phoenix_kit_shop_config,
      :phoenix_kit_shop_import_logs,
      :phoenix_kit_shop_import_configs,
      :phoenix_kit_role_permissions
    ]
  end

  defp v45_v46_v53_tables, do: v45_tables() ++ v46_v53_tables()

  # Fix 0: Add uuid column to tables that are missing it entirely
  defp add_uuid_column(table, prefix, escaped_prefix) do
    table_name = prefix_table_name(Atom.to_string(table), prefix)

    if table_exists?(table, escaped_prefix) and not column_exists?(table, :uuid, escaped_prefix) do
      execute("""
      ALTER TABLE #{table_name}
      ADD COLUMN uuid UUID DEFAULT uuid_generate_v7()
      """)

      # Backfill existing rows
      execute("""
      UPDATE #{table_name}
      SET uuid = uuid_generate_v7()
      WHERE uuid IS NULL
      """)
    end
  end

  # Fix 1: Set DEFAULT to uuid_generate_v7()
  defp fix_uuid_default(table, prefix, escaped_prefix) do
    table_name = prefix_table_name(Atom.to_string(table), prefix)

    if table_exists?(table, escaped_prefix) and column_exists?(table, :uuid, escaped_prefix) do
      execute("""
      ALTER TABLE #{table_name}
      ALTER COLUMN uuid SET DEFAULT uuid_generate_v7()
      """)
    end
  end

  # Fix 2: Backfill NULLs and set NOT NULL
  defp fix_not_null(table, prefix, escaped_prefix) do
    table_name = prefix_table_name(Atom.to_string(table), prefix)

    if table_exists?(table, escaped_prefix) and column_exists?(table, :uuid, escaped_prefix) do
      # Backfill any NULL uuid values with UUIDv7
      execute("""
      UPDATE #{table_name}
      SET uuid = uuid_generate_v7()
      WHERE uuid IS NULL
      """)

      # Set NOT NULL (no-op if already NOT NULL)
      execute("""
      ALTER TABLE #{table_name}
      ALTER COLUMN uuid SET NOT NULL
      """)
    end
  end

  # Fix 3: Add unique index on uuid column
  defp fix_unique_index(table, prefix, escaped_prefix) do
    table_name = prefix_table_name(Atom.to_string(table), prefix)
    index_name = prefix_index_name(table, prefix)

    if table_exists?(table, escaped_prefix) and column_exists?(table, :uuid, escaped_prefix) do
      execute("""
      CREATE UNIQUE INDEX IF NOT EXISTS #{index_name}
      ON #{table_name}(uuid)
      """)
    end
  end

  # Fix 4: Fix UUID primary key default (tables using UUID as PK, not secondary column)
  defp fix_uuid_pk_default(table, prefix, escaped_prefix) do
    table_name = prefix_table_name(Atom.to_string(table), prefix)

    if table_exists?(table, escaped_prefix) and column_exists?(table, :id, escaped_prefix) do
      execute("""
      ALTER TABLE #{table_name}
      ALTER COLUMN id SET DEFAULT uuid_generate_v7()
      """)
    end
  end

  # Rollback helpers

  defp revert_uuid_default(table, prefix, escaped_prefix) do
    table_name = prefix_table_name(Atom.to_string(table), prefix)

    if table_exists?(table, escaped_prefix) and column_exists?(table, :uuid, escaped_prefix) do
      execute("""
      ALTER TABLE #{table_name}
      ALTER COLUMN uuid SET DEFAULT gen_random_uuid()
      """)
    end
  end

  defp revert_not_null(table, prefix, escaped_prefix) do
    table_name = prefix_table_name(Atom.to_string(table), prefix)

    if table_exists?(table, escaped_prefix) and column_exists?(table, :uuid, escaped_prefix) do
      execute("""
      ALTER TABLE #{table_name}
      ALTER COLUMN uuid DROP NOT NULL
      """)
    end
  end

  defp drop_uuid_column(table, prefix, escaped_prefix) do
    table_name = prefix_table_name(Atom.to_string(table), prefix)

    if table_exists?(table, escaped_prefix) and column_exists?(table, :uuid, escaped_prefix) do
      # Drop index first
      index_name = prefix_index_name(table, prefix)
      execute("DROP INDEX IF EXISTS #{index_name}")

      execute("""
      ALTER TABLE #{table_name}
      DROP COLUMN uuid
      """)
    end
  end

  defp revert_uuid_pk_default(table, prefix, escaped_prefix) do
    table_name = prefix_table_name(Atom.to_string(table), prefix)

    if table_exists?(table, escaped_prefix) and column_exists?(table, :id, escaped_prefix) do
      execute("""
      ALTER TABLE #{table_name}
      ALTER COLUMN id SET DEFAULT gen_random_uuid()
      """)
    end
  end

  defp revert_unique_index(table, prefix, escaped_prefix) do
    if table_exists?(table, escaped_prefix) do
      index_name = prefix_index_name(table, prefix)

      execute("""
      DROP INDEX IF EXISTS #{index_name}
      """)
    end
  end

  # Rollback helpers for Fix 7

  defp drop_uuid_unique_indexes(prefix, escaped_prefix) do
    indexes = [
      {:phoenix_kit_user_role_assignments,
       "phoenix_kit_role_assignments_user_uuid_role_uuid_idx"},
      {:phoenix_kit_role_permissions, "phoenix_kit_role_permissions_role_uuid_module_key_idx"},
      {:phoenix_kit_user_oauth_providers, "phoenix_kit_oauth_providers_user_uuid_provider_idx"}
    ]

    for {table, index_name} <- indexes do
      if table_exists?(table, escaped_prefix) do
        idx = if prefix && prefix != "public", do: "#{prefix}.#{index_name}", else: index_name
        execute("DROP INDEX IF EXISTS #{idx}")
      end
    end
  end

  # Fix 6: UUID unique indexes for ON CONFLICT support
  defp add_uuid_unique_indexes(prefix, escaped_prefix) do
    indexes = [
      {:phoenix_kit_user_role_assignments, [:user_uuid, :role_uuid],
       "phoenix_kit_role_assignments_user_uuid_role_uuid_idx"},
      {:phoenix_kit_role_permissions, [:role_uuid, :module_key],
       "phoenix_kit_role_permissions_role_uuid_module_key_idx"},
      {:phoenix_kit_user_oauth_providers, [:user_uuid, :provider],
       "phoenix_kit_oauth_providers_user_uuid_provider_idx"}
    ]

    for {table, columns, index_name} <- indexes do
      if table_exists?(table, escaped_prefix) do
        table_name = prefix_table_name(Atom.to_string(table), prefix)
        cols = Enum.join(columns, ", ")
        idx = if prefix && prefix != "public", do: "#{prefix}.#{index_name}", else: index_name

        execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS #{idx}
        ON #{table_name}(#{cols})
        """)
      end
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
