defmodule PhoenixKit.Migrations.Postgres.V35 do
  @moduledoc """
  PhoenixKit V35 Migration: Support Tickets System

  Adds complete customer support ticket system with status workflow,
  comments with internal notes, file attachments, and audit trail.

  ## Changes

  ### Tickets Table (phoenix_kit_tickets)
  - Main ticket storage with status workflow (open/in_progress/resolved/closed)
  - Customer user association (who created the ticket)
  - Handler assignment (support staff)
  - Denormalized comment counter
  - Resolved/closed timestamps for tracking

  ### Ticket Comments (phoenix_kit_ticket_comments)
  - Threaded comments with internal notes support
  - is_internal flag for staff-only visibility
  - Self-referencing for nested replies

  ### Ticket Attachments (phoenix_kit_ticket_attachments)
  - Junction table for files on tickets or comments
  - Position-based ordering with captions

  ### Ticket Status History (phoenix_kit_ticket_status_history)
  - Complete audit trail for all status changes
  - Who changed, from/to status, optional reason

  ## Settings

  - Module config: enabled, per-page
  - Feature toggles: comments, internal notes, attachments
  - Workflow: allow reopen

  ## Features

  - UUIDv7 primary keys for time-sortable IDs
  - Comprehensive indexes for efficient queries
  - Foreign key constraints for data integrity
  - Check constraint for attachment parent reference
  """
  use Ecto.Migration

  @doc """
  Run the V34 migration to add support tickets system.
  """
  def up(%{prefix: prefix} = _opts) do
    # Create tables in dependency order
    create_tickets_table(prefix)
    create_ticket_comments_table(prefix)
    create_ticket_attachments_table(prefix)
    create_ticket_status_history_table(prefix)

    # Seed SupportAgent role if not exists
    seed_support_agent_role(prefix)

    # Seed default settings
    seed_settings(prefix)

    # Update version tracking
    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '35'")
  end

  @doc """
  Rollback the V35 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop tables in reverse order (respecting foreign keys)
    drop_if_exists(table(:phoenix_kit_ticket_status_history, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_ticket_attachments, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_ticket_comments, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_tickets, prefix: prefix))

    # Remove settings
    delete_setting(prefix, "tickets_enabled")
    delete_setting(prefix, "tickets_per_page")
    delete_setting(prefix, "tickets_comments_enabled")
    delete_setting(prefix, "tickets_internal_notes_enabled")
    delete_setting(prefix, "tickets_attachments_enabled")
    delete_setting(prefix, "tickets_allow_reopen")

    # Note: We don't remove SupportAgent role as it may have assignments

    # Update version tracking (rollback to V34)
    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '34'")
  end

  # Private helper functions

  defp create_tickets_table(prefix) do
    create_if_not_exists table(:phoenix_kit_tickets, primary_key: false, prefix: prefix) do
      add(:id, :uuid, primary_key: true)

      add(
        :user_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      add(
        :assigned_to_id,
        references(:phoenix_kit_users, on_delete: :nilify_all, prefix: prefix, type: :bigint)
      )

      add(:title, :string, null: false)
      add(:description, :text, null: false)
      add(:status, :string, null: false, default: "open")
      add(:slug, :string, null: false)
      add(:comment_count, :integer, default: 0, null: false)
      add(:metadata, :map, default: %{})
      add(:resolved_at, :utc_datetime_usec)
      add(:closed_at, :utc_datetime_usec)

      timestamps(type: :naive_datetime)
    end

    # Indexes for efficient queries
    create_if_not_exists(index(:phoenix_kit_tickets, [:user_id], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_tickets, [:assigned_to_id], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_tickets, [:status], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_tickets, [:slug], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_tickets, [:inserted_at], prefix: prefix))

    # Composite indexes for common queries
    create_if_not_exists(index(:phoenix_kit_tickets, [:status, :assigned_to_id], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_tickets, [:user_id, :status], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_tickets, [:status, :inserted_at], prefix: prefix))

    # Unique slug constraint
    create_if_not_exists(unique_index(:phoenix_kit_tickets, [:slug], prefix: prefix))

    execute("""
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_tickets", prefix)} IS
    'Support tickets with status workflow (open/in_progress/resolved/closed)'
    """)
  end

  defp create_ticket_comments_table(prefix) do
    create_if_not_exists table(:phoenix_kit_ticket_comments, primary_key: false, prefix: prefix) do
      add(:id, :uuid, primary_key: true)

      add(
        :ticket_id,
        references(:phoenix_kit_tickets, on_delete: :delete_all, prefix: prefix, type: :uuid),
        null: false
      )

      add(
        :user_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      add(
        :parent_id,
        references(:phoenix_kit_ticket_comments,
          on_delete: :delete_all,
          prefix: prefix,
          type: :uuid
        )
      )

      add(:content, :text, null: false)
      add(:is_internal, :boolean, default: false, null: false)
      add(:depth, :integer, default: 0, null: false)

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_ticket_comments, [:ticket_id], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_ticket_comments, [:user_id], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_ticket_comments, [:parent_id], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_ticket_comments, [:is_internal], prefix: prefix))

    # Composite indexes for queries
    create_if_not_exists(
      index(:phoenix_kit_ticket_comments, [:ticket_id, :is_internal], prefix: prefix)
    )

    create_if_not_exists(
      index(:phoenix_kit_ticket_comments, [:ticket_id, :parent_id, :depth], prefix: prefix)
    )

    create_if_not_exists(
      index(:phoenix_kit_ticket_comments, [:ticket_id, :inserted_at], prefix: prefix)
    )

    execute("""
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_ticket_comments", prefix)} IS
    'Ticket comments with internal notes support (is_internal flag for staff-only)'
    """)
  end

  defp create_ticket_attachments_table(prefix) do
    create_if_not_exists table(:phoenix_kit_ticket_attachments,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:id, :uuid, primary_key: true)

      add(
        :ticket_id,
        references(:phoenix_kit_tickets, on_delete: :delete_all, prefix: prefix, type: :uuid)
      )

      add(
        :comment_id,
        references(:phoenix_kit_ticket_comments,
          on_delete: :delete_all,
          prefix: prefix,
          type: :uuid
        )
      )

      add(
        :file_id,
        references(:phoenix_kit_files, on_delete: :delete_all, prefix: prefix, type: :uuid),
        null: false
      )

      add(:position, :integer, null: false)
      add(:caption, :text)

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_ticket_attachments, [:ticket_id], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_ticket_attachments, [:comment_id], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_ticket_attachments, [:file_id], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_ticket_attachments, [:position], prefix: prefix))

    # Check constraint: either ticket_id or comment_id must be set (but not both)
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_ticket_attachments_parent_check'
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_ticket_attachments", prefix)}
        ADD CONSTRAINT phoenix_kit_ticket_attachments_parent_check
        CHECK (
          (ticket_id IS NOT NULL AND comment_id IS NULL) OR
          (ticket_id IS NULL AND comment_id IS NOT NULL)
        );
      END IF;
    END $$;
    """)

    execute("""
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_ticket_attachments", prefix)} IS
    'File attachments for tickets or comments (with position ordering)'
    """)
  end

  defp create_ticket_status_history_table(prefix) do
    create_if_not_exists table(:phoenix_kit_ticket_status_history,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:id, :uuid, primary_key: true)

      add(
        :ticket_id,
        references(:phoenix_kit_tickets, on_delete: :delete_all, prefix: prefix, type: :uuid),
        null: false
      )

      add(
        :changed_by_id,
        references(:phoenix_kit_users, on_delete: :nilify_all, prefix: prefix, type: :bigint),
        null: false
      )

      add(:from_status, :string)
      add(:to_status, :string, null: false)
      add(:reason, :text)

      add(:inserted_at, :naive_datetime, null: false)
    end

    create_if_not_exists(index(:phoenix_kit_ticket_status_history, [:ticket_id], prefix: prefix))

    create_if_not_exists(
      index(:phoenix_kit_ticket_status_history, [:changed_by_id], prefix: prefix)
    )

    create_if_not_exists(
      index(:phoenix_kit_ticket_status_history, [:inserted_at], prefix: prefix)
    )

    # Composite index for ticket history queries
    create_if_not_exists(
      index(:phoenix_kit_ticket_status_history, [:ticket_id, :inserted_at], prefix: prefix)
    )

    execute("""
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_ticket_status_history", prefix)} IS
    'Audit trail for ticket status transitions (who, when, from/to, reason)'
    """)
  end

  defp seed_support_agent_role(prefix) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # Create SupportAgent as a system role (protected from deletion)
    execute("""
    INSERT INTO #{prefix_table_name("phoenix_kit_user_roles", prefix)}
    (name, description, is_system_role, inserted_at, updated_at)
    VALUES ('SupportAgent', 'Support team member with ticket management access', true, '#{now}', '#{now}')
    ON CONFLICT (name) DO UPDATE SET is_system_role = true
    """)
  end

  defp seed_settings(prefix) do
    settings = [
      # Module Configuration
      %{key: "tickets_enabled", value: "false"},
      %{key: "tickets_per_page", value: "20"},

      # Feature Toggles
      %{key: "tickets_comments_enabled", value: "true"},
      %{key: "tickets_internal_notes_enabled", value: "true"},
      %{key: "tickets_attachments_enabled", value: "true"},

      # Workflow
      %{key: "tickets_allow_reopen", value: "true"}
    ]

    Enum.each(settings, fn setting ->
      insert_setting(prefix, setting.key, setting.value)
    end)
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

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
