defmodule PhoenixKit.Migrations.Postgres.V60 do
  @moduledoc """
  V60: Email Templates UUID FK Columns

  Adds `created_by_user_uuid` and `updated_by_user_uuid` columns to
  `phoenix_kit_email_templates`. These columns are referenced by the
  `PhoenixKit.Modules.Emails.Template` schema but were never created
  by V15 (which only had integer FK columns).

  Fresh installs now get these columns from V15 directly. This migration
  covers existing installs that already ran V15 without them.

  ## Idempotency

  Uses column_exists checks — safe to re-run and safe on fresh installs.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Add created_by_user_uuid if missing
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{escape_prefix(prefix)}'
          AND table_name = 'phoenix_kit_email_templates'
          AND column_name = 'created_by_user_uuid'
      ) THEN
        ALTER TABLE #{prefix_str}phoenix_kit_email_templates
          ADD COLUMN created_by_user_uuid UUID NULL;
      END IF;
    END
    $$
    """)

    # Add updated_by_user_uuid if missing
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{escape_prefix(prefix)}'
          AND table_name = 'phoenix_kit_email_templates'
          AND column_name = 'updated_by_user_uuid'
      ) THEN
        ALTER TABLE #{prefix_str}phoenix_kit_email_templates
          ADD COLUMN updated_by_user_uuid UUID NULL;
      END IF;
    END
    $$
    """)

    # Record migration version
    execute("COMMENT ON TABLE #{prefix_str}phoenix_kit IS '60'")
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    execute("""
    ALTER TABLE #{prefix_str}phoenix_kit_email_templates
      DROP COLUMN IF EXISTS updated_by_user_uuid,
      DROP COLUMN IF EXISTS created_by_user_uuid
    """)

    execute("COMMENT ON TABLE #{prefix_str}phoenix_kit IS '59'")
  end

  defp escape_prefix(prefix), do: String.replace(prefix, "'", "\\'")
end
