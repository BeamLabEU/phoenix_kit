defmodule PhoenixKit.Migrations.Postgres.V49 do
  @moduledoc """
  V49: Shop Import Enhancements

  Adds option_mappings to import_configs and product_ids to import_logs
  for enhanced CSV import functionality.

  ## Changes

  - Adds option_mappings JSONB column to import_configs for storing
    CSV option to global option mappings configuration
  - Adds product_ids INTEGER[] column to import_logs for tracking
    which products were created/updated during a CSV import

  ## option_mappings Structure

  ```json
  [
    {
      "csv_name": "Cup Color",
      "slot_key": "cup_color",
      "source_key": "color",
      "auto_add": true,
      "label": {"en": "Cup Color", "ru": "Цвет чашки"}
    }
  ]
  ```
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Add option_mappings to import_configs
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_import_configs
    ADD COLUMN IF NOT EXISTS option_mappings JSONB DEFAULT '[]'::jsonb
    """

    # Add product_ids to import_logs
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

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_import_configs
    DROP COLUMN IF EXISTS option_mappings
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '48'"
  end
end
