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

    schema = if prefix && prefix != "public", do: prefix, else: "public"

    # Use a PL/pgSQL block so the column existence check and the ALTER TABLE
    # share the migration's single connection (no extra pool checkout needed).
    # If the column already exists, the ALTER is skipped and no lock is acquired.
    # Lock timeout of 30s applies only when the ALTER actually runs.
    # On PostgreSQL 11+, ADD COLUMN with a constant DEFAULT is metadata-only
    # so the lock is held for milliseconds once acquired.
    execute "SET LOCAL lock_timeout = '30s'"

    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name   = 'phoenix_kit_buckets'
          AND column_name  = 'access_type'
      ) THEN
        ALTER TABLE #{prefix_str}phoenix_kit_buckets
          ADD COLUMN access_type VARCHAR(20) DEFAULT 'public';
      END IF;
    END $$;
    """

    # Reset lock_timeout so subsequent migration steps are not affected
    execute "SET LOCAL lock_timeout = '0'"

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
