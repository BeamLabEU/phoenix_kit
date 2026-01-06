defmodule PhoenixKit.Migrations.Postgres.V44 do
  @moduledoc """
  PhoenixKit V44 Migration: Rename DB Sync tables to Sync

  This migration renames the DB Sync tables and indexes to match the
  module rename from DBSync to Sync.

  ## Changes

  ### Table Renames
  - `phoenix_kit_db_sync_connections` → `phoenix_kit_sync_connections`
  - `phoenix_kit_db_sync_transfers` → `phoenix_kit_sync_transfers`

  ### Index Renames
  All indexes are renamed to match the new table names.

  ### Setting Key Renames
  - `db_sync_enabled` → `sync_enabled`
  - `db_sync_incoming_mode` → `sync_incoming_mode`
  - `db_sync_incoming_password` → `sync_incoming_password`

  ## Backwards Compatibility

  This is a breaking change for existing installations. The migration
  handles the rename automatically, but any raw SQL queries referencing
  the old table names will need to be updated.
  """
  use Ecto.Migration

  @old_connections_table "phoenix_kit_db_sync_connections"
  @new_connections_table "phoenix_kit_sync_connections"
  @old_transfers_table "phoenix_kit_db_sync_transfers"
  @new_transfers_table "phoenix_kit_sync_transfers"

  @doc """
  Run the V44 migration to rename Sync tables.
  """
  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix, do: "#{prefix}.", else: ""

    # ===========================================
    # 1. RENAME CONNECTIONS TABLE
    # ===========================================

    # Check if old table exists and new doesn't (idempotent)
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = COALESCE('#{prefix}', 'public')
                 AND table_name = '#{@old_connections_table}')
         AND NOT EXISTS (SELECT 1 FROM information_schema.tables
                        WHERE table_schema = COALESCE('#{prefix}', 'public')
                        AND table_name = '#{@new_connections_table}') THEN
        ALTER TABLE #{prefix_str}#{@old_connections_table}
        RENAME TO #{@new_connections_table};
      END IF;
    END $$;
    """

    # Rename connections indexes
    rename_index_if_exists(
      "phoenix_kit_db_sync_connections_site_direction_uidx",
      "phoenix_kit_sync_connections_site_direction_uidx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_db_sync_connections_status_idx",
      "phoenix_kit_sync_connections_status_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_db_sync_connections_direction_idx",
      "phoenix_kit_sync_connections_direction_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_db_sync_connections_expires_at_idx",
      "phoenix_kit_sync_connections_expires_at_idx",
      prefix
    )

    # ===========================================
    # 2. RENAME TRANSFERS TABLE
    # ===========================================

    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = COALESCE('#{prefix}', 'public')
                 AND table_name = '#{@old_transfers_table}')
         AND NOT EXISTS (SELECT 1 FROM information_schema.tables
                        WHERE table_schema = COALESCE('#{prefix}', 'public')
                        AND table_name = '#{@new_transfers_table}') THEN
        ALTER TABLE #{prefix_str}#{@old_transfers_table}
        RENAME TO #{@new_transfers_table};
      END IF;
    END $$;
    """

    # Rename transfers indexes
    rename_index_if_exists(
      "phoenix_kit_db_sync_transfers_direction_idx",
      "phoenix_kit_sync_transfers_direction_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_db_sync_transfers_connection_id_idx",
      "phoenix_kit_sync_transfers_connection_id_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_db_sync_transfers_status_idx",
      "phoenix_kit_sync_transfers_status_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_db_sync_transfers_initiated_by_idx",
      "phoenix_kit_sync_transfers_initiated_by_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_db_sync_transfers_inserted_at_idx",
      "phoenix_kit_sync_transfers_inserted_at_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_db_sync_transfers_approval_idx",
      "phoenix_kit_sync_transfers_approval_idx",
      prefix
    )

    # ===========================================
    # 3. UPDATE TABLE COMMENTS (only if tables exist)
    # ===========================================

    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = COALESCE('#{prefix}', 'public')
                 AND table_name = '#{@new_connections_table}') THEN
        COMMENT ON TABLE #{prefix_str}#{@new_connections_table} IS
        'Permanent connections between PhoenixKit instances for data sync';
      END IF;
    END $$;
    """

    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = COALESCE('#{prefix}', 'public')
                 AND table_name = '#{@new_transfers_table}') THEN
        COMMENT ON TABLE #{prefix_str}#{@new_transfers_table} IS
        'Track all data transfers (uploads and downloads) with approval workflow';
      END IF;
    END $$;
    """

    # ===========================================
    # 4. RENAME SETTINGS KEYS
    # ===========================================

    rename_setting_key("db_sync_enabled", "sync_enabled", prefix)
    rename_setting_key("db_sync_incoming_mode", "sync_incoming_mode", prefix)
    rename_setting_key("db_sync_incoming_password", "sync_incoming_password", prefix)

    # Update version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '44'"
  end

  @doc """
  Rollback the V44 migration (rename back to old names).
  """
  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix, do: "#{prefix}.", else: ""

    # Rename transfers table back
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = COALESCE('#{prefix}', 'public')
                 AND table_name = '#{@new_transfers_table}')
         AND NOT EXISTS (SELECT 1 FROM information_schema.tables
                        WHERE table_schema = COALESCE('#{prefix}', 'public')
                        AND table_name = '#{@old_transfers_table}') THEN
        ALTER TABLE #{prefix_str}#{@new_transfers_table}
        RENAME TO #{@old_transfers_table};
      END IF;
    END $$;
    """

    # Rename transfers indexes back
    rename_index_if_exists(
      "phoenix_kit_sync_transfers_approval_idx",
      "phoenix_kit_db_sync_transfers_approval_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_sync_transfers_inserted_at_idx",
      "phoenix_kit_db_sync_transfers_inserted_at_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_sync_transfers_initiated_by_idx",
      "phoenix_kit_db_sync_transfers_initiated_by_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_sync_transfers_status_idx",
      "phoenix_kit_db_sync_transfers_status_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_sync_transfers_connection_id_idx",
      "phoenix_kit_db_sync_transfers_connection_id_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_sync_transfers_direction_idx",
      "phoenix_kit_db_sync_transfers_direction_idx",
      prefix
    )

    # Rename connections table back
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = COALESCE('#{prefix}', 'public')
                 AND table_name = '#{@new_connections_table}')
         AND NOT EXISTS (SELECT 1 FROM information_schema.tables
                        WHERE table_schema = COALESCE('#{prefix}', 'public')
                        AND table_name = '#{@old_connections_table}') THEN
        ALTER TABLE #{prefix_str}#{@new_connections_table}
        RENAME TO #{@old_connections_table};
      END IF;
    END $$;
    """

    # Rename connections indexes back
    rename_index_if_exists(
      "phoenix_kit_sync_connections_expires_at_idx",
      "phoenix_kit_db_sync_connections_expires_at_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_sync_connections_direction_idx",
      "phoenix_kit_db_sync_connections_direction_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_sync_connections_status_idx",
      "phoenix_kit_db_sync_connections_status_idx",
      prefix
    )

    rename_index_if_exists(
      "phoenix_kit_sync_connections_site_direction_uidx",
      "phoenix_kit_db_sync_connections_site_direction_uidx",
      prefix
    )

    # Rename settings keys back
    rename_setting_key("sync_enabled", "db_sync_enabled", prefix)
    rename_setting_key("sync_incoming_mode", "db_sync_incoming_mode", prefix)
    rename_setting_key("sync_incoming_password", "db_sync_incoming_password", prefix)

    # Update version back
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '43'"
  end

  # Helper to rename setting key if it exists
  defp rename_setting_key(old_key, new_key, prefix) do
    prefix_str = if prefix, do: "#{prefix}.", else: ""

    execute """
    UPDATE #{prefix_str}phoenix_kit_settings
    SET key = '#{new_key}'
    WHERE key = '#{old_key}'
    AND NOT EXISTS (
      SELECT 1 FROM #{prefix_str}phoenix_kit_settings WHERE key = '#{new_key}'
    );
    """
  end

  # Helper to rename index if it exists
  defp rename_index_if_exists(old_name, new_name, prefix) do
    schema = if prefix, do: prefix, else: "public"

    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname = '#{schema}'
                 AND indexname = '#{old_name}') THEN
        ALTER INDEX #{if prefix, do: "#{prefix}.", else: ""}#{old_name}
        RENAME TO #{new_name};
      END IF;
    END $$;
    """
  end
end
