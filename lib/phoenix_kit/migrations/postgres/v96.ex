defmodule PhoenixKit.Migrations.Postgres.V96 do
  @moduledoc """
  V96: Attach catalogue items directly to a catalogue.

  Adds a nullable `catalogue_uuid` FK on `phoenix_kit_cat_items` so items
  can belong to a catalogue independently of having a category. This lets
  "uncategorized" items (items with no category) still be scoped to a
  catalogue instead of floating in a global pool.

  - Adds `catalogue_uuid` column with a FK to `phoenix_kit_cat_catalogues`
    (`on_delete: :nilify_all`) — in-app cascades handle soft-delete lifecycle
  - Backfills existing items from their category's catalogue_uuid
  - Pins any remaining orphans (items with no category at all) to the
    oldest non-deleted catalogue so they stay visible in the UI
  - Adds indexes on `catalogue_uuid` and `(catalogue_uuid, status)`

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    # 1. Add catalogue_uuid column (nullable FK, nilify on catalogue hard-delete)
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_cat_items'
          AND column_name = 'catalogue_uuid'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_items
          ADD COLUMN catalogue_uuid uuid
          REFERENCES #{p}phoenix_kit_cat_catalogues(uuid) ON DELETE SET NULL;
      END IF;
    END $$;
    """)

    # 2. Backfill catalogue_uuid from the item's category
    execute("""
    UPDATE #{p}phoenix_kit_cat_items AS i
       SET catalogue_uuid = c.catalogue_uuid
      FROM #{p}phoenix_kit_cat_categories AS c
     WHERE i.category_uuid = c.uuid
       AND i.catalogue_uuid IS NULL
    """)

    # 3. Backfill any remaining orphans (items with no category at all) into
    # the oldest non-deleted catalogue. In the pre-v95 world these items
    # showed up on every catalogue detail page as "global uncategorized";
    # pinning them to the first active catalogue keeps them visible and
    # behaves the same way in the common single-catalogue case.
    #
    # We filter out `status = 'deleted'` so we never land orphans inside a
    # trashed catalogue (which would immediately soft-delete them via the
    # normal cascade semantics). If no non-deleted catalogues exist, the
    # subquery returns NULL and nothing is updated — the items stay orphaned
    # until one does.
    execute("""
    UPDATE #{p}phoenix_kit_cat_items
       SET catalogue_uuid = (
         SELECT uuid FROM #{p}phoenix_kit_cat_catalogues
          WHERE status <> 'deleted'
          ORDER BY inserted_at ASC
          LIMIT 1
       )
     WHERE catalogue_uuid IS NULL
    """)

    # 4. Index on catalogue_uuid for per-catalogue queries, plus a composite
    # index on (catalogue_uuid, status) because every per-catalogue query
    # (`item_count_for_catalogue`, `list_items_for_catalogue`,
    # `item_counts_by_catalogue`, `search_items_in_catalogue`) filters on
    # both columns. The composite lets the planner satisfy the filter
    # without a separate status check.
    create_if_not_exists(index(:phoenix_kit_cat_items, [:catalogue_uuid], prefix: prefix))

    create_if_not_exists(
      index(:phoenix_kit_cat_items, [:catalogue_uuid, :status], prefix: prefix)
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '96'")
  end

  @doc """
  Rolls V96 back by dropping the `catalogue_uuid` column (and its indexes).

  **Lossy rollback:** items that were created *after* V96 as uncategorized
  (no category) have their catalogue linkage stored solely in
  `catalogue_uuid`. Dropping the column means those items can no longer
  be attributed to a catalogue — they'll become global orphans again
  (their pre-V96 shape). Back up before rolling back in production.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(index(:phoenix_kit_cat_items, [:catalogue_uuid, :status], prefix: prefix))

    drop_if_exists(index(:phoenix_kit_cat_items, [:catalogue_uuid], prefix: prefix))

    execute("ALTER TABLE #{p}phoenix_kit_cat_items DROP COLUMN IF EXISTS catalogue_uuid")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '95'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
