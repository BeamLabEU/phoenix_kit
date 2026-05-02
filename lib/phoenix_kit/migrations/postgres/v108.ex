defmodule PhoenixKit.Migrations.Postgres.V108 do
  @moduledoc """
  V108: Add `position` columns for drag-and-drop reordering on three
  list surfaces.

  Three independent admin lists previously sat in insertion order
  (latest first or alphabetical) with no user-driven order:

  - `phoenix_kit_entities` — the entity-definitions list at
    `/admin/entities`
  - `phoenix_kit_cat_catalogues` — the catalogues index at
    `/admin/catalogue`
  - `phoenix_kit_cat_items` — items shown on a catalogue's detail page
    and inside categories

  Categories and smart-catalogue rules already carry their own
  `position` columns (V87 and V102 respectively), so they're untouched
  here. The `phoenix_kit_entity_data` table got its `position` column
  in V81 along with a `(entity_uuid, position)` composite index for
  the manual-sort query, so it's also already covered.

  ## Up

  Adds a nullable `position integer` to each of the three tables with a
  default of `0`. New rows get `0`; the LV reorder handlers re-index
  the visible group to `1..N` on the first user drag, so the default is
  only ever observed transiently.

  No indexes on the three new `position` columns themselves — entity /
  catalogue / item-per-catalogue lists are small (≤ a few hundred
  rows) and have other indexed scope filters; a position-only btree
  would burn write amplification for no real read win.

  ## Down

  Drops the three columns. Lossy — any user-set ordering is discarded.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    ALTER TABLE #{p}phoenix_kit_entities
    ADD COLUMN IF NOT EXISTS position integer DEFAULT 0
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_catalogues
    ADD COLUMN IF NOT EXISTS position integer DEFAULT 0
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_items
    ADD COLUMN IF NOT EXISTS position integer DEFAULT 0
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '108'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_items
    DROP COLUMN IF EXISTS position
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_catalogues
    DROP COLUMN IF EXISTS position
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_entities
    DROP COLUMN IF EXISTS position
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '107'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
