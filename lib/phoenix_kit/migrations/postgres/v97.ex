defmodule PhoenixKit.Migrations.Postgres.V97 do
  @moduledoc """
  V97: Per-item markup override.

  Adds a nullable `markup_percentage DECIMAL(7, 2)` column on
  `phoenix_kit_cat_items`. When `NULL`, pricing falls back to the parent
  catalogue's `markup_percentage`; when set (including `0`), the item
  uses its own value.

  This lets individual items carry a different margin from the rest of
  the catalogue without needing a second catalogue or a separate
  pricing table. `NULL` vs. `0` is load-bearing: `0` means "explicitly
  sell at base price", `NULL` means "inherit whatever the catalogue
  currently uses".

  The column is nullable with no default, matching the semantic
  distinction. Existing rows stay `NULL` and continue to inherit — no
  backfill is needed.
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
          AND table_name = 'phoenix_kit_cat_items'
          AND column_name = 'markup_percentage'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_items
          ADD COLUMN markup_percentage DECIMAL(7, 2);
      END IF;
    END $$;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '97'")
  end

  @doc """
  Rolls V97 back by dropping the per-item `markup_percentage` column.

  **Lossy rollback:** any per-item overrides set after V97 are lost —
  affected items revert to the catalogue's markup. Back up before
  rolling back in production.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("ALTER TABLE #{p}phoenix_kit_cat_items DROP COLUMN IF EXISTS markup_percentage")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '96'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
