defmodule PhoenixKit.Migrations.Postgres.V89 do
  @moduledoc """
  V89: Catalogue pricing — rename price to base_price, add markup_percentage.

  Changes:
  - Rename `price` to `base_price` in `phoenix_kit_cat_items`
  - Add `markup_percentage` decimal column to `phoenix_kit_cat_catalogues`
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    execute("""
    DO $$
    BEGIN
      -- Rename price to base_price in items
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_cat_items'
          AND column_name = 'price'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_items
          RENAME COLUMN price TO base_price;
      END IF;

      -- Add markup_percentage to catalogues
      IF EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = '#{schema}' AND table_name = 'phoenix_kit_cat_catalogues'
      ) AND NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_cat_catalogues'
          AND column_name = 'markup_percentage'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_catalogues
          ADD COLUMN markup_percentage DECIMAL(7, 2) NOT NULL DEFAULT 0;
      END IF;
    END $$;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '89'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    execute("""
    DO $$
    BEGIN
      -- Rename base_price back to price in items
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_cat_items'
          AND column_name = 'base_price'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_items
          RENAME COLUMN base_price TO price;
      END IF;

      -- Drop markup_percentage from catalogues
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_cat_catalogues'
          AND column_name = 'markup_percentage'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_catalogues
          DROP COLUMN markup_percentage;
      END IF;
    END $$;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '88'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
