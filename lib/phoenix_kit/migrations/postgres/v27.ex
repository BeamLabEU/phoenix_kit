defmodule PhoenixKit.Migrations.Postgres.V27 do
  @moduledoc """
  Migration V27: Add Oban tables for background job processing.

  This migration creates Oban tables required for background job processing,
  including file processing (storage system) and email handling.

  ## Changes
  - Creates `oban_jobs` table for job queue management
  - Creates `oban_peers` table for distributed coordination
  - Adds indexes for efficient job processing
  - Sets up Oban schema to latest version (uses Oban.Migration.up/1)

  ## Requirements
  - PostgreSQL database
  - Oban dependency (`{:oban, "~> 2.17"}`)

  ## Purpose
  - Enable background job processing for:
    - File variant generation (thumbnails, resizes)
    - Video processing (transcoding, thumbnails)
    - Email sending and tracking
    - Metadata extraction (dimensions, duration, EXIF)
    - Multi-bucket redundancy uploads

  ## Queue Configuration
  After running this migration, configure Oban queues in config/config.exs:

      config :phoenix_kit, Oban,
        repo: MyApp.Repo,
        queues: [
          default: 10,
          emails: 50,
          file_processing: 20
        ],
        plugins: [Oban.Plugins.Pruner]

  ## Notes
  - Oban tables are created in the same schema prefix as PhoenixKit tables
  - Uses Oban's latest schema version automatically (forward-compatible)
  - Idempotent: Safe to run multiple times
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    # Run Oban migrations to create required tables
    # Uses latest Oban schema version automatically (forward-compatible)
    Oban.Migration.up(prefix: prefix)

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '27'"
  end

  def down(%{prefix: prefix} = _opts) do
    # Remove Oban tables by downgrading to version 1 (minimum required version)
    Oban.Migration.down(prefix: prefix, version: 1)

    # Update version comment on phoenix_kit table to previous version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '26'"
  end

  # Helper functions

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
