defmodule PhoenixKit.Migrations.Postgres.V21 do
  @moduledoc """
  PhoenixKit V21 Migration: Optimize Message ID Search Performance

  This migration adds a composite index on (message_id, aws_message_id) to
  optimize the dual message ID search pattern used throughout the email system.

  ## Changes

  ### Email System Performance Optimization
  - Adds composite index on (message_id, aws_message_id) for faster lookups
  - Improves performance of AWS SES event correlation
  - Optimizes message ID search queries used in SQSProcessor and EmailLog

  ## Background

  The email system uses a dual message ID architecture:
  - `message_id`: Internal PhoenixKit ID (pk_ prefix) - primary identifier
  - `aws_message_id`: AWS SES ID - secondary identifier for AWS event correlation

  This composite index enables fast searches when querying either field or both,
  which is critical for processing AWS SES events and correlating them with
  email logs.

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Uses efficient B-tree index for string matching
  - Backward compatible with existing data
  """
  use Ecto.Migration

  @doc """
  Run the V21 migration to add composite message ID index.
  """
  def up(%{prefix: prefix} = _opts) do
    # Add composite index on (message_id, aws_message_id) for optimized dual searches
    # This index supports queries that search either message_id, aws_message_id, or both
    create_if_not_exists index(:phoenix_kit_email_logs, [:message_id, :aws_message_id],
                           prefix: prefix,
                           name: "phoenix_kit_email_logs_message_ids_idx"
                         )

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '21'"
  end

  @doc """
  Rollback the V21 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Remove composite index
    drop_if_exists index(:phoenix_kit_email_logs, [:message_id, :aws_message_id],
                     prefix: prefix,
                     name: "phoenix_kit_email_logs_message_ids_idx"
                   )

    # Update version comment on phoenix_kit table
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '20'"
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
