defmodule PhoenixKit.Migrations.Postgres.V46 do
  @moduledoc """
  V46: Product Options with Dynamic Pricing

  This migration adds:
  - phoenix_kit_shop_config table for global Shop configuration
  - option_schema JSONB column to categories for category-specific options
  - featured_image_id and image_ids columns to products for Storage integration
  - selected_specs JSONB column to cart_items for specification storage

  ## Option Schema Format

  Options support dynamic pricing with two modifier types:

      %{
        "key" => "material",
        "label" => "Material",
        "type" => "select",
        "options" => ["PLA", "ABS", "PETG"],
        "affects_price" => true,
        "modifier_type" => "fixed",  # "fixed" or "percent"
        "price_modifiers" => %{
          "PLA" => "0",
          "ABS" => "5.00",
          "PETG" => "10.00"
        }
      }

  ## Price Calculation Order

  1. Sum all fixed modifiers
  2. Add to base price (intermediate price)
  3. Sum all percent modifiers
  4. Apply percent to intermediate price

  Example: Base $20 + PETG ($10 fixed) + Premium (20% percent)
  Result: ($20 + $10) * 1.20 = $36
  """
  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # 1. Create shop_config table for global settings (key-value JSONB)
    execute """
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_shop_config (
      id BIGSERIAL PRIMARY KEY,
      uuid UUID DEFAULT gen_random_uuid(),
      key VARCHAR(255) NOT NULL,
      value JSONB DEFAULT '{}',
      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW()
    );
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_shop_config_key
    ON #{prefix_str}phoenix_kit_shop_config(key);
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_shop_config_uuid
    ON #{prefix_str}phoenix_kit_shop_config(uuid);
    """

    # 2. Add option_schema to categories
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    ADD COLUMN IF NOT EXISTS option_schema JSONB DEFAULT '[]';
    """

    # 3. Add new columns to products
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    ADD COLUMN IF NOT EXISTS made_to_order BOOLEAN DEFAULT false,
    ADD COLUMN IF NOT EXISTS featured_image_id UUID,
    ADD COLUMN IF NOT EXISTS image_ids UUID[] DEFAULT '{}';
    """

    # 4. Add selected_specs to cart_items for storing user selections
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_cart_items
    ADD COLUMN IF NOT EXISTS selected_specs JSONB DEFAULT '{}';
    """

    # 5. Update version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '46'"
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Remove selected_specs from cart_items
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_cart_items
    DROP COLUMN IF EXISTS selected_specs;
    """

    # Remove new columns from products
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    DROP COLUMN IF EXISTS made_to_order,
    DROP COLUMN IF EXISTS featured_image_id,
    DROP COLUMN IF EXISTS image_ids;
    """

    # Remove option_schema from categories
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    DROP COLUMN IF EXISTS option_schema;
    """

    # Drop shop_config table
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_config_uuid;"
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_config_key;"
    execute "DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_shop_config CASCADE;"

    # Update version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '45'"
  end
end
