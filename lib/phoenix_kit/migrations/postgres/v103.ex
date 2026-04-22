defmodule PhoenixKit.Migrations.Postgres.V103 do
  @moduledoc """
  V103: Nested categories.

  Adds a nullable self-referential `parent_uuid` column on
  `phoenix_kit_cat_categories`, turning the previously flat one-level
  taxonomy into an arbitrary-depth tree. Existing rows stay
  `parent_uuid = NULL` and become roots — no backfill needed.

  The column is nullable (roots have no parent) with no `ON DELETE`
  cascade: parent/child linkage is managed by the context layer, which
  runs subtree-walking cascades inside a transaction. A DB-level cascade
  would bypass the soft-delete machinery and the activity log.

  A plain b-tree index on `(parent_uuid)` covers the "list children"
  query used when rendering the tree. The existing index on
  `(catalogue_uuid)` still covers "list all categories in a catalogue".
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
          AND table_name = 'phoenix_kit_cat_categories'
          AND column_name = 'parent_uuid'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_categories
          ADD COLUMN parent_uuid UUID
          REFERENCES #{p}phoenix_kit_cat_categories(uuid);
      END IF;
    END $$;
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_cat_categories_parent_index
    ON #{p}phoenix_kit_cat_categories (parent_uuid)
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '103'")
  end

  @doc """
  Rolls V103 back by dropping the parent index and column.

  **Lossy rollback:** the tree collapses — every category becomes a
  root and all parent linkage is lost. Back up before rolling back in
  production.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_cat_categories_parent_index")

    execute("ALTER TABLE #{p}phoenix_kit_cat_categories DROP COLUMN IF EXISTS parent_uuid")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '102'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
