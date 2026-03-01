defmodule PhoenixKit.Migrations.Postgres.V50 do
  @moduledoc """
  V50: Add access_type to storage buckets

  Adds access_type field to buckets for controlling how files are served:
  - "public" - redirect to public URL (default, works with public S3 buckets)
  - "private" - proxy through server (for ACL-protected buckets)
  - "signed" - presigned URLs (future implementation)

  ## Changes

  - Adds access_type VARCHAR column to phoenix_kit_buckets with default "public"
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Check at the Elixir level first — if the column already exists, skip the
    # ALTER TABLE entirely. This avoids acquiring ACCESS EXCLUSIVE lock when the
    # column is already present (common on retry after a previous lock timeout).
    # Only attempt the DDL when the column is genuinely missing.
    unless column_exists?(:phoenix_kit_buckets, :access_type, prefix: prefix) do
      # On PostgreSQL 11+, ADD COLUMN with a constant DEFAULT is a metadata-only
      # operation — the lock is held for milliseconds once acquired. Set a 30s
      # timeout so we wait long enough for a brief window in production traffic.
      execute "SET LOCAL lock_timeout = '30s'"

      execute """
      ALTER TABLE #{prefix_str}phoenix_kit_buckets
      ADD COLUMN IF NOT EXISTS access_type VARCHAR(20) DEFAULT 'public'
      """

      # Reset lock_timeout so subsequent migration steps are not affected
      execute "SET LOCAL lock_timeout = '0'"
    end

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '50'"
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    execute "SET LOCAL lock_timeout = '10s'"

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_buckets
    DROP COLUMN IF EXISTS access_type
    """

    execute "SET LOCAL lock_timeout = '0'"

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '49'"
  end
end
