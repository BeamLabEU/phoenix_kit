defmodule PhoenixKit.Migrations.Postgres.V26 do
  @moduledoc """
  Migration V26: Rename checksum fields and add per-user deduplication.

  This migration renames checksum fields for clarity and adds per-user file deduplication
  while preserving the ability to query for popular files across all users.

  ## Changes
  - Renames `checksum` column to `file_checksum` (for clarity)
  - Drops unique index on `file_checksum` (allows same file from different users)
  - Adds `user_file_checksum` column (SHA256 of user_id + file_checksum)
  - Creates unique index on `user_file_checksum` to enforce per-user uniqueness
  - Backfills existing records with calculated user_file_checksum values

  ## Purpose
  - Same user cannot upload the same file twice (duplicate prevention via user_file_checksum)
  - Different users CAN upload the same file (no unique constraint on file_checksum)
  - Original `file_checksum` field preserved for finding most popular images across all users
  - Clearer naming: file_checksum vs user_file_checksum
  """

  use Ecto.Migration

  def up(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")

    # Drop the unique index on checksum (from V24)
    drop_if_exists unique_index(:phoenix_kit_files, [:checksum], prefix: prefix)

    # Rename checksum to file_checksum for clarity
    rename table(:phoenix_kit_files, prefix: prefix), :checksum, to: :file_checksum

    # Add user_file_checksum column
    alter table(:phoenix_kit_files, prefix: prefix) do
      add :user_file_checksum, :string
    end

    # Backfill existing records with user_file_checksum
    execute """
    UPDATE #{prefix}.phoenix_kit_files
    SET user_file_checksum = encode(digest(CAST(user_id AS text) || file_checksum, 'sha256'), 'hex')
    WHERE user_file_checksum IS NULL
    """

    # Make the column NOT NULL after backfill
    alter table(:phoenix_kit_files, prefix: prefix) do
      modify :user_file_checksum, :string, null: false
    end

    # Create unique index on user_file_checksum for fast per-user duplicate detection
    create unique_index(:phoenix_kit_files, [:user_file_checksum],
             prefix: prefix,
             name: "#{prefix}_phoenix_kit_files_user_file_checksum_index"
           )
  end

  def down(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")

    # Drop the user_file_checksum unique index
    drop_if_exists unique_index(:phoenix_kit_files, [:user_file_checksum],
                     prefix: prefix,
                     name: "#{prefix}_phoenix_kit_files_user_file_checksum_index"
                   )

    # Remove user_file_checksum column
    alter table(:phoenix_kit_files, prefix: prefix) do
      remove :user_file_checksum
    end

    # Rename file_checksum back to checksum
    rename table(:phoenix_kit_files, prefix: prefix), :file_checksum, to: :checksum

    # Restore the unique index on checksum (from V24)
    create_if_not_exists unique_index(:phoenix_kit_files, [:checksum], prefix: prefix)
  end
end
