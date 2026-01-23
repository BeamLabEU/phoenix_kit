defmodule PhoenixKit.Migrations.Postgres.V46 do
  @moduledoc """
  V46: Product Options with Dynamic Pricing + Import Logs + Translations

  This migration adds:
  - phoenix_kit_shop_config table for global Shop configuration
  - option_schema JSONB column to categories for category-specific options
  - image_id BIGINT column to categories for Storage media integration
  - featured_image_id and image_ids columns to products for Storage integration
  - selected_specs JSONB column to cart_items for specification storage
  - phoenix_kit_shop_import_logs table for CSV import history tracking
  - translations JSONB column to products and categories for multi-language support

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

    # 2. Add option_schema, image_id, status, and translations to categories
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    ADD COLUMN IF NOT EXISTS option_schema JSONB DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS image_id UUID,
    ADD COLUMN IF NOT EXISTS status VARCHAR(20) DEFAULT 'active',
    ADD COLUMN IF NOT EXISTS translations JSONB DEFAULT '{}';
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_categories_status
    ON #{prefix_str}phoenix_kit_shop_categories(status);
    """

    # 3. Add new columns to products (including translations for multi-language)
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    ADD COLUMN IF NOT EXISTS made_to_order BOOLEAN DEFAULT false,
    ADD COLUMN IF NOT EXISTS featured_image_id UUID,
    ADD COLUMN IF NOT EXISTS image_ids UUID[] DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS translations JSONB DEFAULT '{}';
    """

    # 3b. Create GIN indexes for translations JSONB fields
    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_products_translations
    ON #{prefix_str}phoenix_kit_shop_products USING GIN(translations);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_categories_translations
    ON #{prefix_str}phoenix_kit_shop_categories USING GIN(translations);
    """

    # 4. Add selected_specs to cart_items for storing user selections
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_cart_items
    ADD COLUMN IF NOT EXISTS selected_specs JSONB DEFAULT '{}';
    """

    # 5. Create GIN index for selected_specs JSONB for efficient querying
    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_cart_items_selected_specs
    ON #{prefix_str}phoenix_kit_shop_cart_items USING GIN(selected_specs);
    """

    # 6. Create import_logs table for CSV import history
    execute """
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_shop_import_logs (
      id BIGSERIAL PRIMARY KEY,
      uuid UUID DEFAULT gen_random_uuid(),
      filename VARCHAR(255) NOT NULL,
      file_path VARCHAR(1024),
      status VARCHAR(50) DEFAULT 'pending',

      total_rows INTEGER DEFAULT 0,
      processed_rows INTEGER DEFAULT 0,
      imported_count INTEGER DEFAULT 0,
      updated_count INTEGER DEFAULT 0,
      skipped_count INTEGER DEFAULT 0,
      error_count INTEGER DEFAULT 0,

      options JSONB DEFAULT '{}',
      error_details JSONB DEFAULT '[]',

      started_at TIMESTAMP,
      completed_at TIMESTAMP,

      user_id BIGINT REFERENCES #{prefix_str}phoenix_kit_users(id) ON DELETE SET NULL,

      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW()
    );
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_shop_import_logs_uuid
    ON #{prefix_str}phoenix_kit_shop_import_logs(uuid);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_import_logs_status
    ON #{prefix_str}phoenix_kit_shop_import_logs(status);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_import_logs_inserted_at
    ON #{prefix_str}phoenix_kit_shop_import_logs(inserted_at DESC);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_import_logs_user_id
    ON #{prefix_str}phoenix_kit_shop_import_logs(user_id);
    """

    # 7. Create import_configs table for configurable CSV import filtering
    execute """
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_shop_import_configs (
      id BIGSERIAL PRIMARY KEY,
      uuid UUID DEFAULT gen_random_uuid(),
      name VARCHAR(255) NOT NULL,
      include_keywords TEXT[] DEFAULT '{}',
      exclude_keywords TEXT[] DEFAULT '{}',
      exclude_phrases TEXT[] DEFAULT '{}',
      skip_filter BOOLEAN DEFAULT false,
      category_rules JSONB DEFAULT '[]',
      default_category_slug VARCHAR(255),
      required_columns TEXT[] DEFAULT ARRAY['Handle', 'Title', 'Variant Price'],
      is_default BOOLEAN DEFAULT false,
      active BOOLEAN DEFAULT true,
      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW()
    );
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_shop_import_configs_uuid
    ON #{prefix_str}phoenix_kit_shop_import_configs(uuid);
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_shop_import_configs_name
    ON #{prefix_str}phoenix_kit_shop_import_configs(name);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_import_configs_is_default
    ON #{prefix_str}phoenix_kit_shop_import_configs(is_default) WHERE is_default = true;
    """

    # 8. Update version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '46'"
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Drop import_configs table and indexes
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_import_configs_is_default;"
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_import_configs_name;"
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_import_configs_uuid;"
    execute "DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_shop_import_configs CASCADE;"

    # Drop import_logs table and indexes
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_import_logs_user_id;"
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_import_logs_inserted_at;"
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_import_logs_status;"
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_import_logs_uuid;"
    execute "DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_shop_import_logs CASCADE;"

    # Drop GIN index for selected_specs
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_cart_items_selected_specs;"

    # Remove selected_specs from cart_items
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_cart_items
    DROP COLUMN IF EXISTS selected_specs;
    """

    # Drop translations GIN indexes
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_products_translations;"
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_categories_translations;"

    # Remove new columns from products
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    DROP COLUMN IF EXISTS made_to_order,
    DROP COLUMN IF EXISTS featured_image_id,
    DROP COLUMN IF EXISTS image_ids,
    DROP COLUMN IF EXISTS translations;
    """

    # Remove option_schema, image_id, status, and translations from categories
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_categories_status;"

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    DROP COLUMN IF EXISTS option_schema,
    DROP COLUMN IF EXISTS image_id,
    DROP COLUMN IF EXISTS status,
    DROP COLUMN IF EXISTS translations;
    """

    # Drop shop_config table
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_config_uuid;"
    execute "DROP INDEX IF EXISTS #{prefix_str}idx_shop_config_key;"
    execute "DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_shop_config CASCADE;"

    # Update version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '45'"
  end
end
