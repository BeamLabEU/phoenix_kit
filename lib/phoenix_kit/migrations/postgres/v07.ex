defmodule PhoenixKit.Migrations.Postgres.V07 do
  @moduledoc """
  PhoenixKit V07 Migration: Email System

  This migration introduces comprehensive email tracking capabilities including
  logging of outgoing emails, event tracking (open, click, bounce), and 
  integration with AWS SES for delivery monitoring.

  ## Changes

  ### Email  System
  - Adds phoenix_kit_email_logs table for comprehensive email logging
  - Adds phoenix_kit_email_events table for tracking delivery events
  - Supports AWS SES integration with configuration sets
  - Provides detailed analytics and monitoring capabilities
  - Includes rate limiting and security features

  ### New Tables
  - **phoenix_kit_email_logs**: Main email logging with extended metadata
  - **phoenix_kit_email_events**: Event tracking (open, click, bounce, complaint)

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Optimized indexes for performance
  - JSONB fields for flexible metadata storage
  """
  use Ecto.Migration

  @doc """
  Run the V07 migration to add email tracking system.
  """
  def up(%{prefix: prefix} = _opts) do
    # Create email logs table
    create_if_not_exists table(:phoenix_kit_email_logs, prefix: prefix) do
      # Unique ID from email provider
      add :message_id, :string, null: false
      # Recipient email
      add :to, :string, null: false
      # Sender email
      add :from, :string, null: false
      # Email subject
      add :subject, :string, null: true
      # JSONB headers without duplication
      add :headers, :map, null: true, default: %{}
      # First 500+ characters preview
      add :body_preview, :text, null: true
      # Full email body (optional)
      add :body_full, :text, null: true
      # Email template identifier
      add :template_name, :string, null: true
      # Campaign/group identifier
      add :campaign_id, :string, null: true
      # Number of attachments
      add :attachments_count, :integer, null: false, default: 0
      # Email size in bytes
      add :size_bytes, :integer, null: true
      # Send retry attempts
      add :retry_count, :integer, null: false, default: 0
      # Error message if failed
      add :error_message, :text, null: true
      # sent, delivered, bounced, opened, clicked, failed
      add :status, :string, null: false, default: "sent"
      # Send timestamp
      add :sent_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      # Delivery timestamp
      add :delivered_at, :utc_datetime_usec, null: true
      # AWS SES configuration set
      add :configuration_set, :string, null: true
      # JSONB tags for grouping
      add :message_tags, :map, null: true, default: %{}
      # aws_ses, smtp, local, etc.
      add :provider, :string, null: false, default: "unknown"
      # FK to users for auth integration
      add :user_id, :integer, null: true

      # Timestamps for tracking record creation/update
      timestamps(type: :utc_datetime_usec)
    end

    # Create email events table
    create_if_not_exists table(:phoenix_kit_email_events, prefix: prefix) do
      # FK to email_logs
      add :email_log_id, :integer, null: false
      # open, click, bounce, complaint, delivery, send
      add :event_type, :string, null: false
      # JSONB event-specific data
      add :event_data, :map, null: true, default: %{}
      # Event timestamp
      add :occurred_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      # IP for open/click events
      add :ip_address, :string, null: true
      # User agent for open/click
      add :user_agent, :string, null: true
      # JSONB geo data (country, region, city)
      add :geo_location, :map, null: true, default: %{}
      # URL for click events
      add :link_url, :string, null: true
      # hard, soft for bounce events
      add :bounce_type, :string, null: true
      # abuse, auth-failure, fraud, etc.
      add :complaint_type, :string, null: true

      # Timestamps for tracking record creation/update
      timestamps(type: :utc_datetime_usec)
    end

    # Create indexes for email_logs table
    # Performance indexes for common queries
    create_if_not_exists index(:phoenix_kit_email_logs, [:to, :sent_at],
                           prefix: prefix,
                           name: :phoenix_kit_email_logs_to_sent_at_idx
                         )

    create_if_not_exists index(:phoenix_kit_email_logs, [:status, :sent_at],
                           prefix: prefix,
                           name: :phoenix_kit_email_logs_status_sent_at_idx
                         )

    create_if_not_exists index(:phoenix_kit_email_logs, [:sent_at],
                           prefix: prefix,
                           name: :phoenix_kit_email_logs_sent_at_idx
                         )

    # Unique constraint on message_id
    create_if_not_exists unique_index(:phoenix_kit_email_logs, [:message_id],
                           prefix: prefix,
                           name: :phoenix_kit_email_logs_message_id_uidx
                         )

    # Indexes for filtering and analytics
    create_if_not_exists index(:phoenix_kit_email_logs, [:user_id],
                           prefix: prefix,
                           name: :phoenix_kit_email_logs_user_id_idx
                         )

    create_if_not_exists index(:phoenix_kit_email_logs, [:campaign_id],
                           prefix: prefix,
                           name: :phoenix_kit_email_logs_campaign_id_idx
                         )

    create_if_not_exists index(:phoenix_kit_email_logs, [:template_name],
                           prefix: prefix,
                           name: :phoenix_kit_email_logs_template_name_idx
                         )

    create_if_not_exists index(:phoenix_kit_email_logs, [:provider, :sent_at],
                           prefix: prefix,
                           name: :phoenix_kit_email_logs_provider_sent_at_idx
                         )

    # Create indexes for email_events table
    create_if_not_exists index(:phoenix_kit_email_events, [:email_log_id],
                           prefix: prefix,
                           name: :phoenix_kit_email_events_email_log_id_idx
                         )

    create_if_not_exists index(:phoenix_kit_email_events, [:event_type, :occurred_at],
                           prefix: prefix,
                           name: :phoenix_kit_email_events_type_occurred_at_idx
                         )

    create_if_not_exists index(:phoenix_kit_email_events, [:occurred_at],
                           prefix: prefix,
                           name: :phoenix_kit_email_events_occurred_at_idx
                         )

    # Add foreign key constraint for email_events to email_logs
    alter table(:phoenix_kit_email_events, prefix: prefix) do
      modify :email_log_id,
             references(:phoenix_kit_email_logs, on_delete: :delete_all, prefix: prefix)
    end

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '7'"
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"

  def down(%{prefix: prefix} = _opts) do
    # Drop indexes first
    drop_if_exists index(:phoenix_kit_email_events, [:occurred_at],
                     prefix: prefix,
                     name: :phoenix_kit_email_events_occurred_at_idx
                   )

    drop_if_exists index(:phoenix_kit_email_events, [:event_type, :occurred_at],
                     prefix: prefix,
                     name: :phoenix_kit_email_events_type_occurred_at_idx
                   )

    drop_if_exists index(:phoenix_kit_email_events, [:email_log_id],
                     prefix: prefix,
                     name: :phoenix_kit_email_events_email_log_id_idx
                   )

    drop_if_exists index(:phoenix_kit_email_logs, [:provider, :sent_at],
                     prefix: prefix,
                     name: :phoenix_kit_email_logs_provider_sent_at_idx
                   )

    drop_if_exists index(:phoenix_kit_email_logs, [:template_name],
                     prefix: prefix,
                     name: :phoenix_kit_email_logs_template_name_idx
                   )

    drop_if_exists index(:phoenix_kit_email_logs, [:campaign_id],
                     prefix: prefix,
                     name: :phoenix_kit_email_logs_campaign_id_idx
                   )

    drop_if_exists index(:phoenix_kit_email_logs, [:user_id],
                     prefix: prefix,
                     name: :phoenix_kit_email_logs_user_id_idx
                   )

    drop_if_exists index(:phoenix_kit_email_logs, [:message_id],
                     prefix: prefix,
                     name: :phoenix_kit_email_logs_message_id_uidx
                   )

    drop_if_exists index(:phoenix_kit_email_logs, [:sent_at],
                     prefix: prefix,
                     name: :phoenix_kit_email_logs_sent_at_idx
                   )

    drop_if_exists index(:phoenix_kit_email_logs, [:status, :sent_at],
                     prefix: prefix,
                     name: :phoenix_kit_email_logs_status_sent_at_idx
                   )

    drop_if_exists index(:phoenix_kit_email_logs, [:to, :sent_at],
                     prefix: prefix,
                     name: :phoenix_kit_email_logs_to_sent_at_idx
                   )

    # Drop email events table (foreign key will be dropped automatically)
    drop_if_exists table(:phoenix_kit_email_events, prefix: prefix)

    # Drop email logs table
    drop_if_exists table(:phoenix_kit_email_logs, prefix: prefix)

    # Set version comment back to V06
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '6'"
  end
end
