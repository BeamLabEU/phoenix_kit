defmodule PhoenixKit.Migrations.Postgres.V24 do
  @moduledoc """
  PhoenixKit V24 Migration: File Checksum Unique Index

  This migration adds a unique index on the checksum field of the phoenix_kit_files table
  to enable efficient duplicate file detection and prevent duplicate file storage.

  ## Changes

  ### File Deduplication Support
  - Adds unique index on phoenix_kit_files.checksum for O(1) duplicate lookups
  - Enables automatic deduplication of uploaded files
  - Prevents redundant storage of identical files

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Creates unique index for fast duplicate detection
  """
  use Ecto.Migration

  @doc """
  Run the V24 file checksum indexing migration.

  Handles existing duplicate checksums by keeping the oldest file and deleting newer duplicates.
  """
  def up(%{prefix: prefix} = _opts) do
    # First, remove duplicate checksums by keeping the oldest file (first inserted)
    # This ensures the migration won't fail due to existing duplicates
    remove_duplicate_checksums(prefix)

    # Create unique index on checksum for duplicate detection
    create_if_not_exists unique_index(:phoenix_kit_files, [:checksum], prefix: prefix)

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '24'"
  end

  @doc """
  Rollback the V24 file checksum indexing migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop unique index on checksum
    drop_if_exists unique_index(:phoenix_kit_files, [:checksum], prefix: prefix)

    # Update version comment on phoenix_kit table to previous version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '23'"
  end

  # Helper function to remove duplicate checksums
  # Keeps the oldest file (earliest inserted_at) and deletes newer duplicates
  defp remove_duplicate_checksums(prefix) do
    table_name = prefix_table_name("phoenix_kit_files", prefix)

    sql = """
    DELETE FROM #{table_name} f1
    WHERE id NOT IN (
      SELECT DISTINCT ON (checksum) id
      FROM #{table_name}
      ORDER BY checksum, inserted_at ASC
    )
    """

    execute(sql)
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
