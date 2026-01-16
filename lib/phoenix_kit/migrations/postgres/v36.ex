defmodule PhoenixKit.Migrations.Postgres.V36 do
  @moduledoc """
  PhoenixKit V36 Migration: Connections Module - Social Relationships System

  Adds complete social relationships system with follows, connections, and blocking.

  ## Architecture

  Each relationship type has two tables:
  - **Main table**: Current state only (one row per user pair)
  - **History table**: Activity log of all changes over time

  ## Changes

  ### User Follows Table (phoenix_kit_user_follows)
  - One-way follow relationships (no consent required)
  - Stores only CURRENT follows (row deleted when unfollowed)
  - Unique constraint ensures one row per user pair

  ### User Follows History Table (phoenix_kit_user_follows_history)
  - Logs all follow/unfollow events
  - Actions: "follow", "unfollow"
  - Preserves full audit trail

  ### User Connections Table (phoenix_kit_user_connections)
  - Two-way mutual relationships (requires acceptance)
  - Stores only CURRENT status per user pair
  - Status: "pending", "accepted" (rejected rows are deleted)

  ### User Connections History Table (phoenix_kit_user_connections_history)
  - Logs all connection events
  - Actions: "requested", "accepted", "rejected", "removed"
  - Preserves full audit trail

  ### User Blocks Table (phoenix_kit_user_blocks)
  - Blocking prevents all interaction
  - Stores only CURRENT blocks (row deleted when unblocked)
  - Unique constraint ensures one row per user pair

  ### User Blocks History Table (phoenix_kit_user_blocks_history)
  - Logs all block/unblock events
  - Actions: "block", "unblock"
  - Preserves full audit trail

  ## Settings

  - connections_enabled: Enable/disable entire module

  ## Features

  - UUIDv7 primary keys for time-sortable IDs
  - Comprehensive indexes for efficient queries
  - Foreign key constraints for data integrity
  - Complete activity history for auditing
  """
  use Ecto.Migration

  @doc """
  Run the V36 migration to add connections system.
  """
  def up(%{prefix: prefix} = _opts) do
    # Main tables (current state)
    create_user_follows_table(prefix)
    create_user_connections_table(prefix)
    create_user_blocks_table(prefix)

    # History tables (activity log)
    create_user_follows_history_table(prefix)
    create_user_connections_history_table(prefix)
    create_user_blocks_history_table(prefix)

    seed_settings(prefix)

    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '36'")
  end

  @doc """
  Rollback the V36 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop history tables first (no foreign keys to main tables)
    drop_if_exists(table(:phoenix_kit_user_blocks_history, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_user_connections_history, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_user_follows_history, prefix: prefix))

    # Drop main tables
    drop_if_exists(table(:phoenix_kit_user_blocks, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_user_connections, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_user_follows, prefix: prefix))

    delete_setting(prefix, "connections_enabled")

    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '35'")
  end

  defp create_user_follows_table(prefix) do
    create_if_not_exists table(:phoenix_kit_user_follows, primary_key: false, prefix: prefix) do
      add(:id, :uuid, primary_key: true)

      add(
        :follower_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      add(
        :followed_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      add(:inserted_at, :naive_datetime, null: false)
    end

    create_if_not_exists(index(:phoenix_kit_user_follows, [:follower_id], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_user_follows, [:followed_id], prefix: prefix))

    create_if_not_exists(
      unique_index(:phoenix_kit_user_follows, [:follower_id, :followed_id],
        name: :phoenix_kit_user_follows_unique_idx,
        prefix: prefix
      )
    )

    execute("""
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_user_follows", prefix)} IS
    'One-way follow relationships (follower follows followed, no consent required)'
    """)
  end

  defp create_user_connections_table(prefix) do
    create_if_not_exists table(:phoenix_kit_user_connections, primary_key: false, prefix: prefix) do
      add(:id, :uuid, primary_key: true)

      add(
        :requester_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      add(
        :recipient_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      add(:status, :string, null: false, default: "pending")
      add(:requested_at, :naive_datetime, null: false)
      add(:responded_at, :naive_datetime)

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_user_connections, [:requester_id], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_user_connections, [:recipient_id], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_user_connections, [:status], prefix: prefix))

    create_if_not_exists(
      index(:phoenix_kit_user_connections, [:recipient_id, :status],
        name: :phoenix_kit_user_connections_recipient_status_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_user_connections, [:requester_id, :status],
        name: :phoenix_kit_user_connections_requester_status_idx,
        prefix: prefix
      )
    )

    execute("""
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_user_connections", prefix)} IS
    'Two-way mutual connections (requires acceptance from both parties)'
    """)
  end

  defp create_user_blocks_table(prefix) do
    create_if_not_exists table(:phoenix_kit_user_blocks, primary_key: false, prefix: prefix) do
      add(:id, :uuid, primary_key: true)

      add(
        :blocker_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      add(
        :blocked_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      add(:reason, :string)
      add(:inserted_at, :naive_datetime, null: false)
    end

    create_if_not_exists(index(:phoenix_kit_user_blocks, [:blocker_id], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_user_blocks, [:blocked_id], prefix: prefix))

    create_if_not_exists(
      unique_index(:phoenix_kit_user_blocks, [:blocker_id, :blocked_id],
        name: :phoenix_kit_user_blocks_unique_idx,
        prefix: prefix
      )
    )

    execute("""
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_user_blocks", prefix)} IS
    'User blocking (prevents all interaction between users)'
    """)
  end

  defp seed_settings(prefix) do
    insert_setting(prefix, "connections_enabled", "false")
  end

  defp insert_setting(prefix, key, value) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    execute("""
    INSERT INTO #{prefix_table_name("phoenix_kit_settings", prefix)}
    (key, value, date_added, date_updated)
    VALUES ('#{key}', '#{value}', '#{now}', '#{now}')
    ON CONFLICT (key) DO NOTHING
    """)
  end

  defp delete_setting(prefix, key) do
    execute("""
    DELETE FROM #{prefix_table_name("phoenix_kit_settings", prefix)}
    WHERE key = '#{key}'
    """)
  end

  # ===== HISTORY TABLES =====

  defp create_user_follows_history_table(prefix) do
    create_if_not_exists table(:phoenix_kit_user_follows_history,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:id, :uuid, primary_key: true)

      add(
        :follower_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      add(
        :followed_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      # Action: "follow" or "unfollow"
      add(:action, :string, null: false)
      add(:inserted_at, :naive_datetime, null: false)
    end

    create_if_not_exists(index(:phoenix_kit_user_follows_history, [:follower_id], prefix: prefix))

    create_if_not_exists(index(:phoenix_kit_user_follows_history, [:followed_id], prefix: prefix))

    create_if_not_exists(index(:phoenix_kit_user_follows_history, [:inserted_at], prefix: prefix))

    execute("""
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_user_follows_history", prefix)} IS
    'Activity log of follow/unfollow events'
    """)
  end

  defp create_user_connections_history_table(prefix) do
    create_if_not_exists table(:phoenix_kit_user_connections_history,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:id, :uuid, primary_key: true)

      add(
        :user_a_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      add(
        :user_b_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      # Who initiated this action
      add(
        :actor_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      # Action: "requested", "accepted", "rejected", "removed"
      add(:action, :string, null: false)
      add(:inserted_at, :naive_datetime, null: false)
    end

    create_if_not_exists(
      index(:phoenix_kit_user_connections_history, [:user_a_id], prefix: prefix)
    )

    create_if_not_exists(
      index(:phoenix_kit_user_connections_history, [:user_b_id], prefix: prefix)
    )

    create_if_not_exists(
      index(:phoenix_kit_user_connections_history, [:actor_id], prefix: prefix)
    )

    create_if_not_exists(
      index(:phoenix_kit_user_connections_history, [:inserted_at], prefix: prefix)
    )

    execute("""
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_user_connections_history", prefix)} IS
    'Activity log of connection request/accept/reject/remove events'
    """)
  end

  defp create_user_blocks_history_table(prefix) do
    create_if_not_exists table(:phoenix_kit_user_blocks_history,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:id, :uuid, primary_key: true)

      add(
        :blocker_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      add(
        :blocked_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      # Action: "block" or "unblock"
      add(:action, :string, null: false)
      add(:reason, :string)
      add(:inserted_at, :naive_datetime, null: false)
    end

    create_if_not_exists(index(:phoenix_kit_user_blocks_history, [:blocker_id], prefix: prefix))

    create_if_not_exists(index(:phoenix_kit_user_blocks_history, [:blocked_id], prefix: prefix))

    create_if_not_exists(index(:phoenix_kit_user_blocks_history, [:inserted_at], prefix: prefix))

    execute("""
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_user_blocks_history", prefix)} IS
    'Activity log of block/unblock events'
    """)
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
