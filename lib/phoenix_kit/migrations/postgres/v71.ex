defmodule PhoenixKit.Migrations.Postgres.V71 do
  @moduledoc """
  V71: Rename product_ids → product_uuids in shop import logs.

  The shop module has migrated from integer primary keys to UUIDs. The
  `product_ids` column (integer[]) held UUID values incorrectly typed; this
  migration replaces it with a proper `product_uuids uuid[]` column.

  ## Changes

  - Add `product_uuids uuid[] DEFAULT '{}'` to `phoenix_kit_shop_import_logs`
  - Drop `product_ids integer[]` from `phoenix_kit_shop_import_logs`

  All operations are idempotent (guarded by table/column existence checks).
  """

  use Ecto.Migration

  @table "phoenix_kit_shop_import_logs"

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    flush()

    if table_exists?(@table, escaped_prefix) do
      table = prefix_table(@table, prefix)

      unless column_exists?(@table, "product_uuids", escaped_prefix) do
        execute("ALTER TABLE #{table} ADD COLUMN product_uuids uuid[] DEFAULT '{}'")
      end

      if column_exists?(@table, "product_ids", escaped_prefix) do
        execute("ALTER TABLE #{table} DROP COLUMN product_ids")
      end
    end

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '71'")
  end

  def down(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    if table_exists?(@table, escaped_prefix) do
      table = prefix_table(@table, prefix)

      unless column_exists?(@table, "product_ids", escaped_prefix) do
        execute("ALTER TABLE #{table} ADD COLUMN product_ids integer[] DEFAULT '{}'")
      end

      if column_exists?(@table, "product_uuids", escaped_prefix) do
        execute("ALTER TABLE #{table} DROP COLUMN product_uuids")
      end
    end

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '70'")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp table_exists?(table, escaped_prefix) do
    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.tables
             WHERE table_name = '#{table}'
             AND table_schema = '#{escaped_prefix}'
           )
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp column_exists?(table, column, escaped_prefix) do
    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.columns
             WHERE table_name = '#{table}'
             AND column_name = '#{column}'
             AND table_schema = '#{escaped_prefix}'
           )
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_table(table_name, nil), do: table_name
  defp prefix_table(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table(table_name, prefix), do: "#{prefix}.#{table_name}"
end
