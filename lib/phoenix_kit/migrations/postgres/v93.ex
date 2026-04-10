defmodule PhoenixKit.Migrations.Postgres.V93 do
  @moduledoc """
  V93: Add prefix index on settings key column for integration queries.

  The integrations system queries settings by key prefix
  (e.g., `LIKE 'integration:google:%'`). Without a supporting index,
  these queries cause full table scans. This migration adds a
  `text_pattern_ops` B-tree index that PostgreSQL can use for
  prefix LIKE queries.

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    # Add text_pattern_ops index for efficient LIKE 'prefix%' queries
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM pg_indexes
        WHERE schemaname = '#{schema}'
          AND tablename = 'phoenix_kit_settings'
          AND indexname = 'phoenix_kit_settings_key_prefix_idx'
      ) THEN
        CREATE INDEX phoenix_kit_settings_key_prefix_idx
          ON #{p}phoenix_kit_settings (key text_pattern_ops);
      END IF;
    END $$;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '93'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_settings_key_prefix_idx")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '92'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
