defmodule PhoenixKit.Migrations.Postgres.V14 do
  @moduledoc """
  PhoenixKit V14 Migration: Email Body Compression Support

  This migration adds support for email body compression to optimize storage
  and improve archival functionality.

  ## Changes

  ### Email Log Enhancements
  - Adds body_compressed boolean field to track compression status
  - Enables efficient archival and storage management

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Backward compatible with existing data
  - Sets default value for existing records
  """
  use Ecto.Migration

  @doc """
  Run the V14 migration to add body compression support.
  """
  def up(%{prefix: prefix} = _opts) do
    # Add body_compressed field to phoenix_kit_email_logs table
    alter table(:phoenix_kit_email_logs, prefix: prefix) do
      add :body_compressed, :boolean, null: false, default: false
    end

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '14'"
  end

  @doc """
  Rollback the V14 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Remove body_compressed field from phoenix_kit_email_logs table
    alter table(:phoenix_kit_email_logs, prefix: prefix) do
      remove :body_compressed
    end

    # Update version comment on phoenix_kit table
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '13'"
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
