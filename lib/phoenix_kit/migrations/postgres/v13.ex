defmodule PhoenixKit.Migrations.Postgres.V13 do
  @moduledoc """
  PhoenixKit V13 Migration: Enhanced Email Tracking with AWS SES Integration

  This migration enhances the email tracking system to support comprehensive
  AWS SES event types and improved message ID synchronization.

  ## Changes

  ### Email Log Enhancements
  - Adds aws_message_id column for improved AWS SES message correlation
  - Adds timestamp columns for detailed event tracking (bounced_at, complained_at, opened_at, clicked_at)
  - Expands status enum to include all AWS SES event types
  - Adds partial unique index on aws_message_id for duplicate prevention (only for non-NULL values)

  ### Email Event Enhancements
  - Adds support for reject, delivery_delay, subscription, and rendering_failure events
  - Adds specific fields for new event types (reject_reason, delay_type, subscription_type, failure_reason)
  - Expands event_type enum validation

  ### New Event Types Supported
  - **reject**: Email rejected by SES before sending
  - **delivery_delay**: Temporary delivery delays
  - **subscription**: List subscription/unsubscription events
  - **rendering_failure**: Template rendering failures

  ### New Status Types
  - **rejected**: Email rejected by SES
  - **delayed**: Email delivery temporarily delayed
  - **hard_bounced**: Permanent bounce (non-recoverable)
  - **soft_bounced**: Temporary bounce (recoverable)
  - **complaint**: Spam complaint received

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Uses proper timestamp types for event tracking
  - Adds necessary constraints for data integrity
  - Backward compatible with existing data
  """
  use Ecto.Migration

  @doc """
  Run the V13 migration to enhance email tracking system.
  """
  def up(%{prefix: prefix} = _opts) do
    # Enhance phoenix_kit_email_logs table
    alter table(:phoenix_kit_email_logs, prefix: prefix) do
      # Add aws_message_id for improved correlation with AWS SES
      add :aws_message_id, :string, null: true

      # Add specific timestamp fields for different event types
      add :bounced_at, :utc_datetime_usec, null: true
      add :complained_at, :utc_datetime_usec, null: true
      add :opened_at, :utc_datetime_usec, null: true
      add :clicked_at, :utc_datetime_usec, null: true
    end

    # Add partial unique constraint on aws_message_id to prevent duplicates
    # Only applies when aws_message_id IS NOT NULL (for AWS SES emails)
    # Allows multiple NULL values for non-AWS providers (SMTP, Local, Mailgun, etc.)
    create unique_index(:phoenix_kit_email_logs, [:aws_message_id],
             prefix: prefix,
             name: "phoenix_kit_email_logs_aws_message_id_index",
             where: "aws_message_id IS NOT NULL"
           )

    # Enhance phoenix_kit_email_events table
    alter table(:phoenix_kit_email_events, prefix: prefix) do
      # Add fields for new event types
      add :reject_reason, :string, null: true
      add :delay_type, :string, null: true
      add :subscription_type, :string, null: true
      add :failure_reason, :string, null: true
    end

    # Update status enum validation in application code will handle:
    # sent, delivered, bounced, hard_bounced, soft_bounced, opened,
    # clicked, failed, rejected, delayed, complaint

    # Update event_type enum validation in application code will handle:
    # send, delivery, bounce, complaint, open, click, reject,
    # delivery_delay, subscription, rendering_failure

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '13'"
  end

  @doc """
  Rollback the V13 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Remove partial unique constraint on aws_message_id
    drop_if_exists unique_index(:phoenix_kit_email_logs, [:aws_message_id],
                     prefix: prefix,
                     name: "phoenix_kit_email_logs_aws_message_id_index",
                     where: "aws_message_id IS NOT NULL"
                   )

    # Remove enhancements from phoenix_kit_email_logs table
    alter table(:phoenix_kit_email_logs, prefix: prefix) do
      remove :aws_message_id
      remove :bounced_at
      remove :complained_at
      remove :opened_at
      remove :clicked_at
    end

    # Remove enhancements from phoenix_kit_email_events table
    alter table(:phoenix_kit_email_events, prefix: prefix) do
      remove :reject_reason
      remove :delay_type
      remove :subscription_type
      remove :failure_reason
    end

    # Update version comment on phoenix_kit table
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '12'"
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
