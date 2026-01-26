defmodule PhoenixKit.Migrations.Postgres.V48 do
  @moduledoc """
  V48: Add option_mappings to import_configs

  Adds option_mappings JSONB column to import_configs table for storing
  CSV option to global option mappings configuration.

  ## Changes

  - Adds option_mappings JSONB column with default empty array

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

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_import_configs
    ADD COLUMN IF NOT EXISTS option_mappings JSONB DEFAULT '[]'::jsonb
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '48'"
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_import_configs
    DROP COLUMN IF EXISTS option_mappings
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '47'"
  end
end
