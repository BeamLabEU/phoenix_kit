defmodule PhoenixKit.Migrations.Postgres.V49 do
  @moduledoc """
  V49: Add product_ids to import_logs

  Adds product_ids INTEGER[] column to import_logs table for tracking
  which products were created/updated during a CSV import.

  ## Changes

  - Adds product_ids INTEGER[] column with default empty array
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_import_logs
    ADD COLUMN IF NOT EXISTS product_ids INTEGER[] DEFAULT '{}'
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '49'"
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_import_logs
    DROP COLUMN IF EXISTS product_ids
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '48'"
  end
end
