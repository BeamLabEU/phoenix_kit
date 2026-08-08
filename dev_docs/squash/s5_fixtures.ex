defmodule PhoenixKit.Squash.S5Fixtures do
  @moduledoc """
  Fixtures for `verify.exs`'s S5 scenario (spec 2026-07-14, section 8.2 S5,
  and section 5.3's "consumer-app compatibility" guarantee).

  ## Provenance

  Mined 2026-08-07 by reading (never modifying — CLAUDE.md forbids touching
  that directory) `/www/app/priv/repo/migrations/`: 54 files matching
  `*phoenix_kit*`, in filename-timestamp order —

    * 1 unpinned installer (`add_phoenix_kit_tables.exs`,
      `PhoenixKit.Migrations.up([])`)
    * 48 pinned update wrappers (`phoenix_kit_update_vNN_to_vMM.exs`,
      `PhoenixKit.Migrations.up(prefix:, version:, create_schema: false)` /
      `.down(prefix:, version: NN)`, `@disable_ddl_transaction true`) —
      `wrapper_versions/0` below
    * 5 consumer-authored migrations that touch PK-owned tables directly,
      interleaved among the above at their real chronological positions —
      `consumer_migrations_after/1` below

  `add_phoenix_kit_tables.exs` and every `phoenix_kit_update_vNN_to_vMM.exs`
  are STRUCTURALLY IDENTICAL modulo the two version numbers, so
  `wrapper_versions/0` represents them as `{from, to}` integer pairs rather
  than 48 near-duplicate fixture files — the version numbers themselves ARE
  the trace (spec 5.3: "traced and test-pinned").

  The 5 consumer-authored ones are reproduced with their REAL DDL shape
  (not literal file copies — Andi's files hardcode `public.`/bare
  unqualified table names because Andi always runs unprefixed; these take
  `prefix` and schema-qualify explicitly so they are safe to run against a
  throwaway scratch schema instead).

  ## Why `to`-keyed interleaving, not a flat ordered list

  Each consumer file's real position is "immediately after the update
  wrapper whose `to` version is `X`" (verified from the real filenames'
  timestamps). Keying by `to` lets the S5 runner walk `wrapper_versions/0`
  and splice in `consumer_migrations_after(to)` after each step, without a
  second parallel data structure that could drift out of sync.

  | after wrapper `to=` | real file | note |
  |---|---|---|
  | 88 | `phoenix_kit_catalogue_v013_markup_percentage.exs` | new column, `add_if_not_exists` — always safe |
  | 88 | `phoenix_kit_catalogue_v013_base_price.exs` | **the S5(iii) precedent** — core V89 renamed `phoenix_kit_cat_items.price` to `base_price` (a below-floor version); this file's `IF EXISTS` guard is why it "survives" replay against the squashed baseline (which already has `base_price`, never `price`) — spec 5.3 |
  | 104 | `add_prefix_to_phoenix_kit_cat_catalogues.exs` | the "shows the unguarded pattern" example (spec 5.3) — unguarded, but adds a column Andi owns exclusively (never in PK's own chain), so it is benign regardless of squash |
  | 138 | `add_primary_supplier_uuid_to_phoenix_kit_cat_items.exs` | new column + FK to an existing table, unguarded, safe |
  | 139 | `create_phoenix_kit_warehouse_tables.exs` | byte-faithful early copy of core V140's DDL, entirely `IF NOT EXISTS`-guarded; reproduced here for ONE representative table (`phoenix_kit_warehouse_stock` + its unique index + check constraint) rather than all six — the additional five are the same idempotent-creation shape and add no further proof value; disclosed here rather than silently trimmed |

  S5(iii) additionally builds an UNGUARDED sibling of the `base_price` rename
  (`unguarded_price_rename/1`) — a synthetic negative fixture, not a real
  Andi file — to pin the "documented, actionable failure mode" spec 5.3
  promises for the breakage class this guarded file happens to survive.
  """

  @doc """
  The 48 real `phoenix_kit_update_vNN_to_vMM.exs` `{from, to}` pairs, in
  filename-timestamp (chronological) order. `to` of the last entry (163) is
  the compiled chain's `current_version/0` as of the mining date above —
  re-verify against `MigrationRunner.current_version/0` if replaying this
  fixture on a materially newer chain.
  """
  @spec wrapper_versions() :: [{pos_integer(), pos_integer()}]
  def wrapper_versions do
    [
      {84, 87},
      {87, 88},
      {88, 92},
      {92, 93},
      {93, 96},
      {96, 98},
      {98, 99},
      {99, 102},
      {102, 103},
      {103, 104},
      {104, 108},
      {108, 109},
      {109, 110},
      {110, 111},
      {111, 113},
      {113, 116},
      {116, 117},
      {117, 118},
      {118, 119},
      {119, 120},
      {120, 121},
      {121, 124},
      {124, 125},
      {125, 128},
      {128, 130},
      {130, 132},
      {132, 134},
      {134, 135},
      {135, 136},
      {136, 137},
      {137, 138},
      {138, 139},
      {139, 142},
      {142, 146},
      {146, 147},
      {147, 148},
      {148, 149},
      {149, 151},
      {151, 152},
      {152, 153},
      {153, 155},
      {155, 156},
      {156, 158},
      {158, 159},
      {159, 160},
      {160, 161},
      {161, 162},
      {162, 163}
    ]
  end

  @doc """
  Consumer-authored fixtures that run immediately after the update wrapper
  whose `to` version is `to_version` — `[]` for every `to_version` not in
  the table in the moduledoc. Each entry is `%{name:, disable_ddl_transaction:,
  up: (prefix -> quoted), down: (prefix -> quoted)}`.
  """
  @spec consumer_migrations_after(pos_integer()) :: [map()]
  def consumer_migrations_after(to_version), do: Map.get(interleaved(), to_version, [])

  defp interleaved do
    %{
      88 => [markup_percentage(), base_price()],
      104 => [add_prefix()],
      138 => [add_primary_supplier_uuid()],
      139 => [create_warehouse_tables_sample()]
    }
  end

  # phoenix_kit_catalogue_v013_markup_percentage.exs
  defp markup_percentage do
    %{
      name: "catalogue_v013_markup_percentage",
      disable_ddl_transaction: false,
      up: fn prefix ->
        sql = """
        ALTER TABLE #{prefix}.phoenix_kit_cat_catalogues
        ADD COLUMN IF NOT EXISTS markup_percentage numeric DEFAULT 0 NOT NULL
        """

        quote(do: execute(unquote(sql)))
      end,
      down: fn prefix ->
        sql = """
        ALTER TABLE #{prefix}.phoenix_kit_cat_catalogues
        DROP COLUMN IF EXISTS markup_percentage
        """

        quote(do: execute(unquote(sql)))
      end
    }
  end

  # phoenix_kit_catalogue_v013_base_price.exs — the REAL guarded rename that
  # "survives only via its hand-added IF EXISTS guard" (spec 5.3).
  defp base_price do
    %{
      name: "catalogue_v013_base_price",
      disable_ddl_transaction: false,
      up: fn prefix -> quote(do: execute(unquote(guarded_rename_sql(prefix, :up)))) end,
      down: fn prefix -> quote(do: execute(unquote(guarded_rename_sql(prefix, :down)))) end
    }
  end

  defp guarded_rename_sql(prefix, :up) do
    """
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{prefix}' AND table_name = 'phoenix_kit_cat_items'
          AND column_name = 'price'
      ) THEN
        ALTER TABLE #{prefix}.phoenix_kit_cat_items RENAME COLUMN price TO base_price;
      END IF;
    END $$;
    """
  end

  defp guarded_rename_sql(prefix, :down) do
    """
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{prefix}' AND table_name = 'phoenix_kit_cat_items'
          AND column_name = 'base_price'
      ) THEN
        ALTER TABLE #{prefix}.phoenix_kit_cat_items RENAME COLUMN base_price TO price;
      END IF;
    END $$;
    """
  end

  @doc """
  S5(iii)'s synthetic negative fixture: the SAME rename as `base_price/0`
  above, minus its `IF EXISTS` guard — models "what if the guard had been
  missing" for the exact below-floor object (core V89's
  `phoenix_kit_cat_items.price` -> `base_price` rename) spec 5.3 names as
  the flagship real breakage class. Not a real Andi file. `down/1` is
  intentionally omitted (S5(iii) never reaches it — the `up` is expected to
  raise).
  """
  @spec unguarded_price_rename(String.t()) :: Macro.t()
  def unguarded_price_rename(prefix) do
    sql = "ALTER TABLE #{prefix}.phoenix_kit_cat_items RENAME COLUMN price TO base_price"
    quote(do: execute(unquote(sql)))
  end

  # add_prefix_to_phoenix_kit_cat_catalogues.exs — spec 5.3's "shows the
  # unguarded pattern" example. Adds a column Andi owns exclusively (never
  # part of PK's own chain), so it stays benign regardless of squash.
  defp add_prefix do
    %{
      name: "add_prefix_to_phoenix_kit_cat_catalogues",
      disable_ddl_transaction: false,
      up: fn prefix ->
        add_col = "ALTER TABLE #{prefix}.phoenix_kit_cat_catalogues ADD COLUMN prefix varchar(16)"

        add_idx =
          "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_catalogues_prefix_index " <>
            "ON #{prefix}.phoenix_kit_cat_catalogues (prefix)"

        quote do
          execute(unquote(add_col))
          execute(unquote(add_idx))
        end
      end,
      down: fn prefix ->
        drop_idx = "DROP INDEX IF EXISTS #{prefix}.phoenix_kit_cat_catalogues_prefix_index"

        drop_col =
          "ALTER TABLE #{prefix}.phoenix_kit_cat_catalogues DROP COLUMN IF EXISTS prefix"

        quote do
          execute(unquote(drop_idx))
          execute(unquote(drop_col))
        end
      end
    }
  end

  # add_primary_supplier_uuid_to_phoenix_kit_cat_items.exs — new column + FK
  # to an already-existing table, unguarded, safe (never touches a
  # renamed/dropped shape).
  defp add_primary_supplier_uuid do
    %{
      name: "add_primary_supplier_uuid_to_phoenix_kit_cat_items",
      disable_ddl_transaction: false,
      up: fn prefix ->
        sql = """
        ALTER TABLE #{prefix}.phoenix_kit_cat_items
        ADD COLUMN primary_supplier_uuid uuid
        REFERENCES #{prefix}.phoenix_kit_cat_suppliers(uuid) ON DELETE SET NULL
        """

        quote(do: execute(unquote(sql)))
      end,
      down: fn prefix ->
        sql = """
        ALTER TABLE #{prefix}.phoenix_kit_cat_items
        DROP COLUMN IF EXISTS primary_supplier_uuid
        """

        quote(do: execute(unquote(sql)))
      end
    }
  end

  # create_phoenix_kit_warehouse_tables.exs — trimmed to ONE representative
  # table (see moduledoc table note): phoenix_kit_warehouse_stock, its
  # unique index, and its non-negative-quantity check constraint. Real file
  # creates five more tables the same IF-NOT-EXISTS-guarded way; V140 (which
  # runs later in this same replay, per wrapper_versions/0's 139->142 step)
  # then finds all of them already present and no-ops on every one —
  # exactly like it does for this one table alone.
  defp create_warehouse_tables_sample do
    %{
      name: "create_phoenix_kit_warehouse_tables(sample: stock)",
      disable_ddl_transaction: true,
      up: fn prefix ->
        create_sql = """
        CREATE TABLE IF NOT EXISTS #{prefix}.phoenix_kit_warehouse_stock (
          uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
          item_uuid UUID NOT NULL,
          location_uuid UUID NOT NULL,
          quantity NUMERIC NOT NULL DEFAULT 0,
          unit_value NUMERIC,
          inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """

        index_sql = """
        CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_stock_item_location_index
        ON #{prefix}.phoenix_kit_warehouse_stock (item_uuid, location_uuid)
        """

        check_sql = """
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1 FROM pg_constraint c
            JOIN pg_class t ON t.oid = c.conrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE c.conname = 'phoenix_kit_warehouse_stock_quantity_non_negative'
              AND t.relname = 'phoenix_kit_warehouse_stock'
              AND n.nspname = '#{prefix}'
          ) THEN
            ALTER TABLE #{prefix}.phoenix_kit_warehouse_stock
            ADD CONSTRAINT phoenix_kit_warehouse_stock_quantity_non_negative
            CHECK (quantity >= 0);
          END IF;
        END $$;
        """

        quote do
          execute(unquote(create_sql))
          execute(unquote(index_sql))
          execute(unquote(check_sql))
        end
      end,
      down: fn prefix ->
        sql = "DROP TABLE IF EXISTS #{prefix}.phoenix_kit_warehouse_stock"
        quote(do: execute(unquote(sql)))
      end
    }
  end
end
