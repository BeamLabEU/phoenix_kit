defmodule PhoenixKit.Migrations.Postgres.V22 do
  @moduledoc """
  PhoenixKit V22 Migration: Email System Improvements & Audit Logging

  This migration addresses critical issues in the email system and adds comprehensive audit logging:

  ## Changes

  ### Email System Fixes
  - Adds aws_message_id field to phoenix_kit_email_logs for AWS SES message ID tracking
  - Adds partial unique index on aws_message_id (preventing duplicates while allowing nulls)
  - Adds composite index (email_log_id, event_type) for faster duplicate event checking
  - Creates phoenix_kit_email_orphaned_events table for tracking unmatched SQS events
  - Adds phoenix_kit_email_metrics table for system metrics tracking

  ### Audit Logging System
  - Adds phoenix_kit_audit_logs table for comprehensive action tracking
  - Records admin actions with complete context (who, what, when, where)
  - Supports metadata storage for additional context
  - Indexed for efficient querying by user, action, and date

  ### New Tables
  - **phoenix_kit_email_orphaned_events**: Tracks SQS events without matching email logs
  - **phoenix_kit_email_metrics**: Tracks email system metrics (extraction rates, placeholder logs, etc.)
  - **phoenix_kit_audit_logs**: Immutable audit trail for administrative actions

  ### Database Improvements
  - Improved email log searching with dual message_id strategy
  - Better duplicate prevention for events
  - Enhanced debugging capabilities for AWS SES integration
  - Complete audit trail for admin password resets and other sensitive operations

  ## Migration Strategy
  The aws_message_id field addition is idempotent - it's added only if it doesn't exist.
  All indexes use create_if_not_exists for safe re-runs.
  """
  use Ecto.Migration

  @doc """
  Run the V22 migration to add email system improvements.
  """
  def up(%{prefix: prefix} = _opts) do
    # Add aws_message_id column to email_logs if it doesn't exist
    alter table(:phoenix_kit_email_logs, prefix: prefix) do
      # AWS SES message ID from provider response
      add_if_not_exists :aws_message_id, :string, null: true
      # Timestamps for when email was bounced, complained, opened, clicked
      add_if_not_exists :bounced_at, :utc_datetime_usec, null: true
      add_if_not_exists :complained_at, :utc_datetime_usec, null: true
      add_if_not_exists :opened_at, :utc_datetime_usec, null: true
      add_if_not_exists :clicked_at, :utc_datetime_usec, null: true
    end

    # Add partial unique index on aws_message_id (only where not null)
    # This prevents duplicate AWS message IDs while allowing multiple nulls
    create_if_not_exists unique_index(
                           :phoenix_kit_email_logs,
                           [:aws_message_id],
                           prefix: prefix,
                           name: :phoenix_kit_email_logs_aws_message_id_uidx,
                           where: "aws_message_id IS NOT NULL"
                         )

    # Add composite index for (message_id, aws_message_id) for faster correlation
    create_if_not_exists index(
                           :phoenix_kit_email_logs,
                           [:message_id, :aws_message_id],
                           prefix: prefix,
                           name: :phoenix_kit_email_logs_message_ids_idx
                         )

    # Add composite index for (email_log_id, event_type) on email_events
    # This dramatically speeds up event_exists? queries
    create_if_not_exists index(
                           :phoenix_kit_email_events,
                           [:email_log_id, :event_type],
                           prefix: prefix,
                           name: :phoenix_kit_email_events_log_type_idx
                         )

    # Create table for tracking orphaned SQS events (events without matching email logs)
    create_if_not_exists table(:phoenix_kit_email_orphaned_events, prefix: prefix) do
      # AWS SES message ID from the event
      add :aws_message_id, :string, null: false
      # Event type (delivery, bounce, open, etc.)
      add :event_type, :string, null: false
      # Full event data from SQS
      add :event_data, :map, null: false, default: %{}
      # When we received the orphaned event
      add :received_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      # Whether this event was later matched to a log
      add :matched, :boolean, null: false, default: false
      # ID of the email log it was matched to (if any)
      add :matched_email_log_id, :integer, null: true
      # When it was matched
      add :matched_at, :utc_datetime_usec, null: true
      # Error details if processing failed
      add :error_message, :text, null: true

      timestamps(type: :utc_datetime_usec)
    end

    # Indexes for orphaned events
    create_if_not_exists index(
                           :phoenix_kit_email_orphaned_events,
                           [:aws_message_id],
                           prefix: prefix,
                           name: :phoenix_kit_orphaned_events_aws_id_idx
                         )

    create_if_not_exists index(
                           :phoenix_kit_email_orphaned_events,
                           [:matched],
                           prefix: prefix,
                           name: :phoenix_kit_orphaned_events_matched_idx
                         )

    create_if_not_exists index(
                           :phoenix_kit_email_orphaned_events,
                           [:event_type, :received_at],
                           prefix: prefix,
                           name: :phoenix_kit_orphaned_events_type_received_idx
                         )

    # Create table for email system metrics tracking
    create_if_not_exists table(:phoenix_kit_email_metrics, prefix: prefix) do
      # Metric name/key
      add :metric_key, :string, null: false
      # Metric value (counter, gauge, etc.)
      add :value, :bigint, null: false, default: 0
      # Metric metadata
      add :metadata, :map, null: true, default: %{}
      # Date for the metric (for daily aggregations)
      add :metric_date, :date, null: false, default: fragment("CURRENT_DATE")

      timestamps(type: :utc_datetime_usec)
    end

    # Indexes for metrics
    create_if_not_exists unique_index(
                           :phoenix_kit_email_metrics,
                           [:metric_key, :metric_date],
                           prefix: prefix,
                           name: :phoenix_kit_email_metrics_key_date_uidx
                         )

    create_if_not_exists index(
                           :phoenix_kit_email_metrics,
                           [:metric_date],
                           prefix: prefix,
                           name: :phoenix_kit_email_metrics_date_idx
                         )

    # Create audit logs table for tracking administrative actions
    create_if_not_exists table(:phoenix_kit_audit_logs, prefix: prefix) do
      # ID of the user affected by the action
      add :target_user_id, :integer, null: false
      # ID of the admin who performed the action
      add :admin_user_id, :integer, null: false
      # Action type (admin_password_reset, user_created, etc.)
      add :action, :string, null: false
      # IP address from which the action was performed
      add :ip_address, :string, null: true
      # User agent string of the client
      add :user_agent, :text, null: true
      # Additional metadata (JSONB for flexibility)
      add :metadata, :map, null: true, default: %{}

      # Timestamp for when the action occurred (immutable, no updated_at)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Create performance indexes for audit logs
    # Index for querying logs by target user
    create_if_not_exists index(:phoenix_kit_audit_logs, [:target_user_id], prefix: prefix)
    # Index for querying logs by admin user
    create_if_not_exists index(:phoenix_kit_audit_logs, [:admin_user_id], prefix: prefix)
    # Index for querying logs by action type
    create_if_not_exists index(:phoenix_kit_audit_logs, [:action], prefix: prefix)
    # Index for chronological queries
    create_if_not_exists index(:phoenix_kit_audit_logs, [:inserted_at], prefix: prefix)

    # Composite indexes for common query patterns
    # Query logs for specific user and action type
    create_if_not_exists index(:phoenix_kit_audit_logs, [:target_user_id, :action],
                         prefix: prefix
                       )

    # Query logs by admin and action type
    create_if_not_exists index(:phoenix_kit_audit_logs, [:admin_user_id, :action],
                         prefix: prefix
                       )

    # Query logs by action and date range
    create_if_not_exists index(:phoenix_kit_audit_logs, [:action, :inserted_at],
                         prefix: prefix
                       )

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '22'"
  end

  @doc """
  Rollback the V22 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop audit logs indexes first
    drop_if_exists index(:phoenix_kit_audit_logs, [:action, :inserted_at], prefix: prefix)
    drop_if_exists index(:phoenix_kit_audit_logs, [:admin_user_id, :action], prefix: prefix)
    drop_if_exists index(:phoenix_kit_audit_logs, [:target_user_id, :action], prefix: prefix)
    drop_if_exists index(:phoenix_kit_audit_logs, [:inserted_at], prefix: prefix)
    drop_if_exists index(:phoenix_kit_audit_logs, [:action], prefix: prefix)
    drop_if_exists index(:phoenix_kit_audit_logs, [:admin_user_id], prefix: prefix)
    drop_if_exists index(:phoenix_kit_audit_logs, [:target_user_id], prefix: prefix)

    # Drop audit logs table
    drop_if_exists table(:phoenix_kit_audit_logs, prefix: prefix)

    # Drop metrics table and indexes
    drop_if_exists index(
                     :phoenix_kit_email_metrics,
                     [:metric_date],
                     prefix: prefix,
                     name: :phoenix_kit_email_metrics_date_idx
                   )

    drop_if_exists index(
                     :phoenix_kit_email_metrics,
                     [:metric_key, :metric_date],
                     prefix: prefix,
                     name: :phoenix_kit_email_metrics_key_date_uidx
                   )

    drop_if_exists table(:phoenix_kit_email_metrics, prefix: prefix)

    # Drop orphaned events table and indexes
    drop_if_exists index(
                     :phoenix_kit_email_orphaned_events,
                     [:event_type, :received_at],
                     prefix: prefix,
                     name: :phoenix_kit_orphaned_events_type_received_idx
                   )

    drop_if_exists index(
                     :phoenix_kit_email_orphaned_events,
                     [:matched],
                     prefix: prefix,
                     name: :phoenix_kit_orphaned_events_matched_idx
                   )

    drop_if_exists index(
                     :phoenix_kit_email_orphaned_events,
                     [:aws_message_id],
                     prefix: prefix,
                     name: :phoenix_kit_orphaned_events_aws_id_idx
                   )

    drop_if_exists table(:phoenix_kit_email_orphaned_events, prefix: prefix)

    # Drop email_events composite index
    drop_if_exists index(
                     :phoenix_kit_email_events,
                     [:email_log_id, :event_type],
                     prefix: prefix,
                     name: :phoenix_kit_email_events_log_type_idx
                   )

    # Drop email_logs composite index
    drop_if_exists index(
                     :phoenix_kit_email_logs,
                     [:message_id, :aws_message_id],
                     prefix: prefix,
                     name: :phoenix_kit_email_logs_message_ids_idx
                   )

    # Drop partial unique index on aws_message_id
    drop_if_exists index(
                     :phoenix_kit_email_logs,
                     [:aws_message_id],
                     prefix: prefix,
                     name: :phoenix_kit_email_logs_aws_message_id_uidx
                   )

    # Remove added columns from email_logs
    alter table(:phoenix_kit_email_logs, prefix: prefix) do
      remove_if_exists :clicked_at, :utc_datetime_usec
      remove_if_exists :opened_at, :utc_datetime_usec
      remove_if_exists :complained_at, :utc_datetime_usec
      remove_if_exists :bounced_at, :utc_datetime_usec
      remove_if_exists :aws_message_id, :string
    end

    # Update version comment to V21
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '21'"
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
