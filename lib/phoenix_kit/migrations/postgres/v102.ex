defmodule PhoenixKit.Migrations.Postgres.V102 do
  @moduledoc """
  V102: Catalogue discount + smart catalogues.

  Two related catalogue features shipped together:

  ## Discount

  Mirrors the markup columns added in V89 (catalogue) and V97 (item override):

  - `phoenix_kit_cat_catalogues.discount_percentage DECIMAL(7, 2)
    NOT NULL DEFAULT 0` — the catalogue-wide default discount applied on
    top of the post-markup sale price.
  - `phoenix_kit_cat_items.discount_percentage DECIMAL(7, 2)` — nullable
    per-item override. `NULL` = inherit the catalogue's discount; any set
    value (including `0`) overrides the catalogue's discount for that item.

  The pricing chain becomes `base → markup → discount`:

      sale_price   = base_price * (1 + effective_markup   / 100)
      final_price  = sale_price  * (1 -  effective_discount / 100)

  ## Smart catalogues

  A smart catalogue's items reference *other* catalogues with a value +
  unit (e.g. a "Delivery" item says "5% of Kitchen, 3% of Plumbing, plus
  $20 flat of Hardware"). Consumers do the math; this module stores the
  user's intent.

  - `phoenix_kit_cat_catalogues.kind VARCHAR(20) NOT NULL DEFAULT 'standard'`
    — one of `'standard'` (existing behavior) or `'smart'` (items
    reference other catalogues).
  - `phoenix_kit_cat_items.default_value DECIMAL(12, 4)` and
    `default_unit VARCHAR(20)` (both nullable) — per-item fallback that
    applies when a rule row has NULL `value`/`unit`.
  - New table `phoenix_kit_cat_item_catalogue_rules` storing one row per
    (item, referenced_catalogue) pair, with nullable `value` + `unit`
    (inherit from item defaults) and a `position INT` for UI ordering.
    Unit vocabulary is open-ended VARCHAR; v1 uses `'percent'` and
    `'flat'`. Self- and smart-to-smart references are intentionally
    allowed — consumers handle cycles at math time.

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    # ── Discount columns ─────────────────────────────────────────
    execute("""
    DO $$
    BEGIN
      -- Catalogue-wide discount: NOT NULL with a 0 default so all
      -- existing rows preserve today's "no discount" behavior.
      IF EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = '#{schema}' AND table_name = 'phoenix_kit_cat_catalogues'
      ) AND NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_cat_catalogues'
          AND column_name = 'discount_percentage'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_catalogues
          ADD COLUMN discount_percentage DECIMAL(7, 2) NOT NULL DEFAULT 0;
      END IF;

      -- Per-item discount override: nullable with no default. NULL = inherit.
      IF EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = '#{schema}' AND table_name = 'phoenix_kit_cat_items'
      ) AND NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_cat_items'
          AND column_name = 'discount_percentage'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_items
          ADD COLUMN discount_percentage DECIMAL(7, 2);
      END IF;

      -- Smart-catalogue `kind` flag on catalogues: standard (default) or smart.
      IF EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = '#{schema}' AND table_name = 'phoenix_kit_cat_catalogues'
      ) AND NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_cat_catalogues'
          AND column_name = 'kind'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_catalogues
          ADD COLUMN kind VARCHAR(20) NOT NULL DEFAULT 'standard';
      END IF;

      -- Per-item default value + unit for smart rules.
      IF EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = '#{schema}' AND table_name = 'phoenix_kit_cat_items'
      ) AND NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_cat_items'
          AND column_name = 'default_value'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_items
          ADD COLUMN default_value DECIMAL(12, 4);
      END IF;

      IF EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = '#{schema}' AND table_name = 'phoenix_kit_cat_items'
      ) AND NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_cat_items'
          AND column_name = 'default_unit'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_items
          ADD COLUMN default_unit VARCHAR(20);
      END IF;
    END $$;
    """)

    # ── Smart rules table ───────────────────────────────────────
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_item_catalogue_rules (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      item_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_cat_items(uuid) ON DELETE CASCADE,
      referenced_catalogue_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_cat_catalogues(uuid) ON DELETE CASCADE,
      value DECIMAL(12, 4),
      unit VARCHAR(20),
      position INTEGER NOT NULL DEFAULT 0,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_cat_item_catalogue_rules_pair_index
    ON #{p}phoenix_kit_cat_item_catalogue_rules (item_uuid, referenced_catalogue_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_cat_item_catalogue_rules_item_index
    ON #{p}phoenix_kit_cat_item_catalogue_rules (item_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_cat_item_catalogue_rules_referenced_index
    ON #{p}phoenix_kit_cat_item_catalogue_rules (referenced_catalogue_uuid)
    """)

    # ── Data-integrity constraints ─────────────────────────────
    # `kind` is a closed vocabulary at the DB layer (Ecto validates it
    # too, but raw INSERTs from import scripts / IEx must also be
    # blocked). `unit` stays open per the smart-catalogue moduledoc —
    # consumers can introduce new units without a migration.
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM pg_constraint
        WHERE conname = 'phoenix_kit_cat_catalogues_kind_check'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_catalogues
          ADD CONSTRAINT phoenix_kit_cat_catalogues_kind_check
          CHECK (kind IN ('standard', 'smart'));
      END IF;

      IF NOT EXISTS (
        SELECT FROM pg_constraint
        WHERE conname = 'phoenix_kit_cat_catalogues_discount_pct_check'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_catalogues
          ADD CONSTRAINT phoenix_kit_cat_catalogues_discount_pct_check
          CHECK (discount_percentage >= 0 AND discount_percentage <= 100);
      END IF;

      IF NOT EXISTS (
        SELECT FROM pg_constraint
        WHERE conname = 'phoenix_kit_cat_items_discount_pct_check'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_items
          ADD CONSTRAINT phoenix_kit_cat_items_discount_pct_check
          CHECK (discount_percentage IS NULL OR
                 (discount_percentage >= 0 AND discount_percentage <= 100));
      END IF;

      IF NOT EXISTS (
        SELECT FROM pg_constraint
        WHERE conname = 'phoenix_kit_cat_items_default_value_check'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_items
          ADD CONSTRAINT phoenix_kit_cat_items_default_value_check
          CHECK (default_value IS NULL OR default_value >= 0);
      END IF;

      IF NOT EXISTS (
        SELECT FROM pg_constraint
        WHERE conname = 'phoenix_kit_cat_item_catalogue_rules_value_check'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_item_catalogue_rules
          ADD CONSTRAINT phoenix_kit_cat_item_catalogue_rules_value_check
          CHECK (value IS NULL OR value >= 0);
      END IF;
    END $$;
    """)

    # Partial index: smart catalogues are typically <1% of total
    # catalogues but the smart-item edit form filters by them on every
    # mount. A standard b-tree on `kind` would be wasteful; this scoped
    # index covers the only query that filters by kind.
    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_cat_catalogues_kind_smart_index
    ON #{p}phoenix_kit_cat_catalogues (uuid)
    WHERE kind = 'smart'
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '102'")
  end

  @doc """
  Rolls V102 back: drops the rules table and both sets of added columns
  (discount + smart-catalogue).

  **Lossy rollback:** all discount values, smart-catalogue rules, item
  defaults, and the `kind` distinction are lost. Back up before rolling
  back in production.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Partial index + CHECK constraints first; PG drops them implicitly with
    # DROP COLUMN, but being explicit keeps `down` reversible and idempotent.
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_cat_catalogues_kind_smart_index")

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_item_catalogue_rules
      DROP CONSTRAINT IF EXISTS phoenix_kit_cat_item_catalogue_rules_value_check
    """)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_cat_item_catalogue_rules")

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_items
      DROP CONSTRAINT IF EXISTS phoenix_kit_cat_items_default_value_check,
      DROP CONSTRAINT IF EXISTS phoenix_kit_cat_items_discount_pct_check
    """)

    execute("ALTER TABLE #{p}phoenix_kit_cat_items DROP COLUMN IF EXISTS default_unit")
    execute("ALTER TABLE #{p}phoenix_kit_cat_items DROP COLUMN IF EXISTS default_value")

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_catalogues
      DROP CONSTRAINT IF EXISTS phoenix_kit_cat_catalogues_kind_check,
      DROP CONSTRAINT IF EXISTS phoenix_kit_cat_catalogues_discount_pct_check
    """)

    execute("ALTER TABLE #{p}phoenix_kit_cat_catalogues DROP COLUMN IF EXISTS kind")

    execute("ALTER TABLE #{p}phoenix_kit_cat_items DROP COLUMN IF EXISTS discount_percentage")

    execute(
      "ALTER TABLE #{p}phoenix_kit_cat_catalogues DROP COLUMN IF EXISTS discount_percentage"
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '101'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
