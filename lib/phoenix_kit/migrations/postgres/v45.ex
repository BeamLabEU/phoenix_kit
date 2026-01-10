defmodule PhoenixKit.Migrations.Postgres.V45 do
  @moduledoc """
  PhoenixKit V45 Migration: E-commerce Shop Module

  This migration creates the foundation for the Shop module with products and categories.

  ## Phase 1 (Current)
  - `phoenix_kit_shop_categories` - Product categories with nesting support
  - `phoenix_kit_shop_products` - Products (physical and digital)

  ## Phase 2 (Future additions to this migration)
  - `phoenix_kit_shop_variants` - Product variants (size, color)
  - `phoenix_kit_shop_inventory` - Inventory tracking
  - `phoenix_kit_shop_carts` - Shopping carts
  - `phoenix_kit_shop_cart_items` - Cart contents
  - `phoenix_kit_shop_shipping_methods` - Shipping options

  ## Settings
  - shop_enabled - Enable/disable shop module
  - shop_currency - Default currency (USD)
  - shop_tax_enabled - Enable tax calculations
  - shop_tax_rate - Default tax rate percentage
  - shop_inventory_tracking - Enable inventory tracking
  """
  use Ecto.Migration

  @doc """
  Run the V45 migration.
  """
  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix, do: "#{prefix}.", else: ""

    # ===========================================
    # 1. CATEGORIES TABLE
    # ===========================================

    execute """
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_shop_categories (
      id BIGSERIAL PRIMARY KEY,
      uuid UUID NOT NULL DEFAULT gen_random_uuid(),

      name VARCHAR(255) NOT NULL,
      slug VARCHAR(255) NOT NULL,
      description TEXT,
      image_url TEXT,

      parent_id BIGINT REFERENCES #{prefix_str}phoenix_kit_shop_categories(id) ON DELETE SET NULL,
      position INTEGER DEFAULT 0,

      metadata JSONB DEFAULT '{}',

      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW(),

      CONSTRAINT phoenix_kit_shop_categories_slug_unique UNIQUE (slug)
    );
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_categories_slug
    ON #{prefix_str}phoenix_kit_shop_categories(slug);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_categories_parent
    ON #{prefix_str}phoenix_kit_shop_categories(parent_id);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_categories_position
    ON #{prefix_str}phoenix_kit_shop_categories(position);
    """

    execute """
    COMMENT ON TABLE #{prefix_str}phoenix_kit_shop_categories IS
    'Product categories with hierarchical nesting support';
    """

    # ===========================================
    # 2. PRODUCTS TABLE
    # ===========================================

    execute """
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_shop_products (
      id BIGSERIAL PRIMARY KEY,
      uuid UUID NOT NULL DEFAULT gen_random_uuid(),

      -- Basic info
      title VARCHAR(255) NOT NULL,
      slug VARCHAR(255) NOT NULL,
      description TEXT,
      body_html TEXT,
      status VARCHAR(20) DEFAULT 'draft',

      -- Type
      product_type VARCHAR(20) DEFAULT 'physical',
      vendor VARCHAR(255),
      tags JSONB DEFAULT '[]',

      -- Pricing
      price DECIMAL(12,2) NOT NULL,
      compare_at_price DECIMAL(12,2),
      cost_per_item DECIMAL(12,2),
      currency VARCHAR(3) DEFAULT 'USD',
      taxable BOOLEAN DEFAULT true,

      -- Physical properties
      weight_grams INTEGER DEFAULT 0,
      requires_shipping BOOLEAN DEFAULT true,

      -- Variants
      has_variants BOOLEAN DEFAULT false,
      option_names JSONB DEFAULT '[]',

      -- Media
      images JSONB DEFAULT '[]',
      featured_image TEXT,

      -- SEO
      seo_title VARCHAR(255),
      seo_description TEXT,

      -- Digital products
      file_id UUID,
      download_limit INTEGER,
      download_expiry_days INTEGER,

      -- Extensibility
      metadata JSONB DEFAULT '{}',

      -- Relations
      category_id BIGINT REFERENCES #{prefix_str}phoenix_kit_shop_categories(id) ON DELETE SET NULL,
      created_by BIGINT REFERENCES #{prefix_str}phoenix_kit_users(id) ON DELETE SET NULL,

      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW(),

      CONSTRAINT phoenix_kit_shop_products_slug_unique UNIQUE (slug)
    );
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_products_slug
    ON #{prefix_str}phoenix_kit_shop_products(slug);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_products_status
    ON #{prefix_str}phoenix_kit_shop_products(status);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_products_category
    ON #{prefix_str}phoenix_kit_shop_products(category_id);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_products_type
    ON #{prefix_str}phoenix_kit_shop_products(product_type);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_products_tags
    ON #{prefix_str}phoenix_kit_shop_products USING GIN(tags);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_products_created_by
    ON #{prefix_str}phoenix_kit_shop_products(created_by);
    """

    execute """
    COMMENT ON TABLE #{prefix_str}phoenix_kit_shop_products IS
    'E-commerce products (physical and digital)';
    """

    # ===========================================
    # 3. SEED SETTINGS
    # ===========================================

    seed_settings(prefix_str)

    # ===========================================
    # 4. UPDATE VERSION
    # ===========================================

    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '45'"
  end

  @doc """
  Rollback the V45 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix, do: "#{prefix}.", else: ""

    # Drop products first (has FK to categories)
    execute "DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_shop_products CASCADE;"

    # Drop categories
    execute "DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_shop_categories CASCADE;"

    # Remove settings
    execute """
    DELETE FROM #{prefix_str}phoenix_kit_settings
    WHERE module = 'shop';
    """

    # Update version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '44'"
  end

  # Seed shop settings
  defp seed_settings(prefix_str) do
    execute """
    INSERT INTO #{prefix_str}phoenix_kit_settings (key, value, module, date_added, date_updated)
    VALUES
      ('shop_enabled', 'false', 'shop', NOW(), NOW()),
      ('shop_currency', 'USD', 'shop', NOW(), NOW()),
      ('shop_tax_enabled', 'true', 'shop', NOW(), NOW()),
      ('shop_tax_rate', '20', 'shop', NOW(), NOW()),
      ('shop_inventory_tracking', 'true', 'shop', NOW(), NOW())
    ON CONFLICT (key) DO NOTHING;
    """
  end
end
