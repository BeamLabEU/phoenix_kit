defmodule PhoenixKit.Migrations.Postgres.V97 do
  @moduledoc """
  V97: Add alternative_formats to storage dimensions.

  Adds a `text[]` column to `phoenix_kit_storage_dimensions` so each
  dimension can specify additional output formats (e.g., WebP, AVIF)
  alongside the primary format. The variant generator creates one
  extra file instance per alternative format per dimension.

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_storage_dimensions'
          AND column_name = 'alternative_formats'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_storage_dimensions
          ADD COLUMN alternative_formats text[] NOT NULL DEFAULT '{}'::text[];
      END IF;
    END $$;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '97'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute(
      "ALTER TABLE #{p}phoenix_kit_storage_dimensions DROP COLUMN IF EXISTS alternative_formats"
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '96'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
