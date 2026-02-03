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

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_buckets
    ADD COLUMN IF NOT EXISTS access_type VARCHAR(20) DEFAULT 'public'
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '50'"
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_buckets
    DROP COLUMN IF EXISTS access_type
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '49'"
  end
end
