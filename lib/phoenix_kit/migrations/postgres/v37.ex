defmodule PhoenixKit.Migrations.Postgres.V37 do
  @moduledoc """
  PhoenixKit V37 Migration: DB Sync - Connections & Transfer Tracking

  This migration adds persistent connections and transfer tracking to the DB Sync module.

  ## Changes

  ### Connections Table (phoenix_kit_db_sync_connections)
  - Permanent connections between PhoenixKit instances
  - Sender-side access controls (approval mode, allowed/excluded tables)
  - Expiration and download limits
  - Additional security (password, IP whitelist, time restrictions)
  - Receiver-side settings (conflict strategy, auto-sync)
  - Full audit trail

  ### Transfers Table (phoenix_kit_db_sync_transfers)
  - Track all data transfers (uploads and downloads)
  - Record counts and bytes transferred
  - Approval workflow support
  - Request context for security

  ## Key Features

  - **Approval Modes**: auto_approve, require_approval, per_table
  - **Expiration**: Time-based and usage-based limits
  - **Security**: Password protection, IP whitelist, time-of-day restrictions
  - **Audit Trail**: Full tracking of who approved/suspended/revoked connections
  """
  use Ecto.Migration

  @doc """
  Run the V37 migration to add DB Sync connections and transfers.
  """
  def up(%{prefix: prefix} = _opts) do
    # ===========================================
    # 1. CONNECTIONS TABLE
    # ===========================================
    create_if_not_exists table(:phoenix_kit_db_sync_connections, prefix: prefix) do
      add :name, :string, null: false
      add :direction, :string, size: 10, null: false
      add :site_url, :string, null: false
      add :auth_token, :string
      add :auth_token_hash, :string
      add :status, :string, size: 20, null: false, default: "pending"

      # Sender-side settings
      add :approval_mode, :string, size: 20, default: "require_approval"
      add :allowed_tables, {:array, :string}, null: false, default: []
      add :excluded_tables, {:array, :string}, null: false, default: []
      add :auto_approve_tables, {:array, :string}, null: false, default: []

      # Expiration & limits
      add :expires_at, :utc_datetime_usec
      add :max_downloads, :integer
      add :downloads_used, :integer, null: false, default: 0
      add :max_records_total, :bigint
      add :records_downloaded, :bigint, null: false, default: 0

      # Per-request limits
      add :max_records_per_request, :integer, null: false, default: 10_000
      add :rate_limit_requests_per_minute, :integer, null: false, default: 60

      # Additional security
      add :download_password_hash, :string
      add :ip_whitelist, {:array, :string}, null: false, default: []
      add :allowed_hours_start, :integer
      add :allowed_hours_end, :integer

      # Receiver-side settings
      add :default_conflict_strategy, :string, size: 20, default: "skip"
      add :auto_sync_enabled, :boolean, null: false, default: false
      add :auto_sync_tables, {:array, :string}, null: false, default: []
      add :auto_sync_interval_minutes, :integer, null: false, default: 60

      # Approval & status tracking
      add :approved_at, :utc_datetime_usec
      add :approved_by, :integer
      add :suspended_at, :utc_datetime_usec
      add :suspended_by, :integer
      add :suspended_reason, :string
      add :revoked_at, :utc_datetime_usec
      add :revoked_by, :integer
      add :revoked_reason, :string

      # Audit & statistics
      add :created_by, :integer
      add :last_connected_at, :utc_datetime_usec
      add :last_transfer_at, :utc_datetime_usec
      add :total_transfers, :integer, null: false, default: 0
      add :total_records_transferred, :bigint, null: false, default: 0
      add :total_bytes_transferred, :bigint, null: false, default: 0

      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(
                           :phoenix_kit_db_sync_connections,
                           [:site_url, :direction],
                           name: :phoenix_kit_db_sync_connections_site_direction_uidx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_db_sync_connections, [:status],
                           name: :phoenix_kit_db_sync_connections_status_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_db_sync_connections, [:direction],
                           name: :phoenix_kit_db_sync_connections_direction_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_db_sync_connections, [:expires_at],
                           name: :phoenix_kit_db_sync_connections_expires_at_idx,
                           prefix: prefix
                         )

    # Add foreign keys for connections (optional - user references)
    add_user_foreign_key("phoenix_kit_db_sync_connections", "approved_by", prefix)
    add_user_foreign_key("phoenix_kit_db_sync_connections", "suspended_by", prefix)
    add_user_foreign_key("phoenix_kit_db_sync_connections", "revoked_by", prefix)
    add_user_foreign_key("phoenix_kit_db_sync_connections", "created_by", prefix)

    # ===========================================
    # 2. TRANSFERS TABLE
    # ===========================================
    create_if_not_exists table(:phoenix_kit_db_sync_transfers, prefix: prefix) do
      add :direction, :string, size: 10, null: false
      add :connection_id, :integer
      add :session_code, :string, size: 20
      add :remote_site_url, :string
      add :table_name, :string, null: false
      add :records_requested, :integer, null: false, default: 0
      add :records_transferred, :integer, null: false, default: 0
      add :records_created, :integer, null: false, default: 0
      add :records_updated, :integer, null: false, default: 0
      add :records_skipped, :integer, null: false, default: 0
      add :records_failed, :integer, null: false, default: 0
      add :bytes_transferred, :bigint, null: false, default: 0
      add :conflict_strategy, :string, size: 20

      # Status and approval
      add :status, :string, size: 20, null: false, default: "pending"
      add :requires_approval, :boolean, null: false, default: false
      add :approved_at, :utc_datetime_usec
      add :approved_by, :integer
      add :denied_at, :utc_datetime_usec
      add :denied_by, :integer
      add :denial_reason, :string
      add :approval_expires_at, :utc_datetime_usec

      # Request context
      add :requester_ip, :string
      add :requester_user_agent, :string

      add :error_message, :text
      add :initiated_by, :integer
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create_if_not_exists index(:phoenix_kit_db_sync_transfers, [:direction],
                           name: :phoenix_kit_db_sync_transfers_direction_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_db_sync_transfers, [:connection_id],
                           name: :phoenix_kit_db_sync_transfers_connection_id_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_db_sync_transfers, [:status],
                           name: :phoenix_kit_db_sync_transfers_status_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_db_sync_transfers, [:initiated_by],
                           name: :phoenix_kit_db_sync_transfers_initiated_by_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_db_sync_transfers, [:inserted_at],
                           name: :phoenix_kit_db_sync_transfers_inserted_at_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(
                           :phoenix_kit_db_sync_transfers,
                           [:requires_approval, :status],
                           name: :phoenix_kit_db_sync_transfers_approval_idx,
                           prefix: prefix
                         )

    # Add foreign keys for transfers
    add_connection_foreign_key("phoenix_kit_db_sync_transfers", "connection_id", prefix)
    add_user_foreign_key("phoenix_kit_db_sync_transfers", "approved_by", prefix)
    add_user_foreign_key("phoenix_kit_db_sync_transfers", "denied_by", prefix)
    add_user_foreign_key("phoenix_kit_db_sync_transfers", "initiated_by", prefix)

    # ===========================================
    # 3. TABLE COMMENTS
    # ===========================================
    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_db_sync_connections", prefix)} IS
    'Permanent connections between PhoenixKit instances for data sync'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_db_sync_connections", prefix)}.approval_mode IS
    'Access control mode: auto_approve, require_approval, or per_table'
    """

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_db_sync_transfers", prefix)} IS
    'Track all data transfers (uploads and downloads) with approval workflow'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_db_sync_transfers", prefix)}.status IS
    'Transfer status: pending_approval, approved, denied, in_progress, completed, failed, cancelled, expired'
    """

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '37'"
  end

  @doc """
  Rollback the V37 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop transfers foreign keys
    drop_foreign_key_if_exists("phoenix_kit_db_sync_transfers", "initiated_by", prefix)
    drop_foreign_key_if_exists("phoenix_kit_db_sync_transfers", "denied_by", prefix)
    drop_foreign_key_if_exists("phoenix_kit_db_sync_transfers", "approved_by", prefix)
    drop_foreign_key_if_exists("phoenix_kit_db_sync_transfers", "connection_id", prefix)

    # Drop transfers indexes
    drop_if_exists index(:phoenix_kit_db_sync_transfers, [:requires_approval, :status],
                     name: :phoenix_kit_db_sync_transfers_approval_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_db_sync_transfers, [:inserted_at],
                     name: :phoenix_kit_db_sync_transfers_inserted_at_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_db_sync_transfers, [:initiated_by],
                     name: :phoenix_kit_db_sync_transfers_initiated_by_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_db_sync_transfers, [:status],
                     name: :phoenix_kit_db_sync_transfers_status_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_db_sync_transfers, [:connection_id],
                     name: :phoenix_kit_db_sync_transfers_connection_id_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_db_sync_transfers, [:direction],
                     name: :phoenix_kit_db_sync_transfers_direction_idx,
                     prefix: prefix
                   )

    # Drop transfers table
    drop_if_exists table(:phoenix_kit_db_sync_transfers, prefix: prefix)

    # Drop connections foreign keys
    drop_foreign_key_if_exists("phoenix_kit_db_sync_connections", "created_by", prefix)
    drop_foreign_key_if_exists("phoenix_kit_db_sync_connections", "revoked_by", prefix)
    drop_foreign_key_if_exists("phoenix_kit_db_sync_connections", "suspended_by", prefix)
    drop_foreign_key_if_exists("phoenix_kit_db_sync_connections", "approved_by", prefix)

    # Drop connections indexes
    drop_if_exists index(:phoenix_kit_db_sync_connections, [:expires_at],
                     name: :phoenix_kit_db_sync_connections_expires_at_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_db_sync_connections, [:direction],
                     name: :phoenix_kit_db_sync_connections_direction_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_db_sync_connections, [:status],
                     name: :phoenix_kit_db_sync_connections_status_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_db_sync_connections, [:site_url, :direction],
                     name: :phoenix_kit_db_sync_connections_site_direction_uidx,
                     prefix: prefix
                   )

    # Drop connections table
    drop_if_exists table(:phoenix_kit_db_sync_connections, prefix: prefix)

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '36'"
  end

  # Helper functions

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"

  defp add_user_foreign_key(table, column, prefix) do
    constraint_name = "#{table}_#{column}_fkey"

    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = '#{constraint_name}'
        AND conrelid = '#{prefix_table_name(table, prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name(table, prefix)}
        ADD CONSTRAINT #{constraint_name}
        FOREIGN KEY (#{column})
        REFERENCES #{prefix_table_name("phoenix_kit_users", prefix)}(id)
        ON DELETE SET NULL;
      END IF;
    END $$;
    """
  end

  defp add_connection_foreign_key(table, column, prefix) do
    constraint_name = "#{table}_#{column}_fkey"

    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = '#{constraint_name}'
        AND conrelid = '#{prefix_table_name(table, prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name(table, prefix)}
        ADD CONSTRAINT #{constraint_name}
        FOREIGN KEY (#{column})
        REFERENCES #{prefix_table_name("phoenix_kit_db_sync_connections", prefix)}(id)
        ON DELETE SET NULL;
      END IF;
    END $$;
    """
  end

  defp drop_foreign_key_if_exists(table, column, prefix) do
    constraint_name = "#{table}_#{column}_fkey"

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = '#{constraint_name}'
        AND conrelid = '#{prefix_table_name(table, prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name(table, prefix)}
        DROP CONSTRAINT #{constraint_name};
      END IF;
    END $$;
    """
  end
end
