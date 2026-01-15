defmodule PhoenixKit.Migrations.Postgres.V45 do
  @moduledoc """
  PhoenixKit V45 Migration: E-commerce Shop Module

  This migration creates the foundation for the Shop module.

  ## Tables
  - `phoenix_kit_shop_categories` - Product categories with nesting support
  - `phoenix_kit_shop_products` - Products (physical and digital)
  - `phoenix_kit_shop_shipping_methods` - Shipping options with constraints
  - `phoenix_kit_shop_carts` - Shopping carts for users and guests
  - `phoenix_kit_shop_cart_items` - Cart contents with price snapshots
  - `phoenix_kit_payment_options` - Payment methods for checkout

  ## Future Tables
  - `phoenix_kit_shop_variants` - Product variants (size, color)
  - `phoenix_kit_shop_inventory` - Inventory tracking

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
    # 3. SHIPPING METHODS TABLE
    # ===========================================

    execute """
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_shop_shipping_methods (
      id BIGSERIAL PRIMARY KEY,
      uuid UUID NOT NULL DEFAULT gen_random_uuid(),

      name VARCHAR(255) NOT NULL,
      slug VARCHAR(100) NOT NULL,
      description TEXT,

      -- Pricing
      price DECIMAL(12,2) NOT NULL DEFAULT 0,
      currency VARCHAR(3) DEFAULT 'USD',
      free_above_amount DECIMAL(12,2),

      -- Constraints
      min_weight_grams INTEGER DEFAULT 0,
      max_weight_grams INTEGER,
      min_order_amount DECIMAL(12,2),
      max_order_amount DECIMAL(12,2),

      -- Geographic
      countries JSONB DEFAULT '[]',
      excluded_countries JSONB DEFAULT '[]',

      -- Status
      active BOOLEAN DEFAULT true,
      position INTEGER DEFAULT 0,

      -- Delivery info
      estimated_days_min INTEGER,
      estimated_days_max INTEGER,
      tracking_supported BOOLEAN DEFAULT false,

      metadata JSONB DEFAULT '{}',

      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW(),

      CONSTRAINT phoenix_kit_shop_shipping_methods_slug_unique UNIQUE (slug)
    );
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_shipping_active
    ON #{prefix_str}phoenix_kit_shop_shipping_methods(active);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_shipping_position
    ON #{prefix_str}phoenix_kit_shop_shipping_methods(position);
    """

    execute """
    COMMENT ON TABLE #{prefix_str}phoenix_kit_shop_shipping_methods IS
    'Shipping methods with weight, price, and geographic constraints';
    """

    # ===========================================
    # 4. CARTS TABLE
    # ===========================================

    execute """
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_shop_carts (
      id BIGSERIAL PRIMARY KEY,
      uuid UUID NOT NULL DEFAULT gen_random_uuid(),

      -- Identity (one required)
      user_id BIGINT REFERENCES #{prefix_str}phoenix_kit_users(id) ON DELETE SET NULL,
      session_id VARCHAR(64),

      -- Status: active, merged, converted, abandoned, expired
      status VARCHAR(20) DEFAULT 'active',

      -- Shipping
      shipping_method_id BIGINT REFERENCES #{prefix_str}phoenix_kit_shop_shipping_methods(id) ON DELETE SET NULL,
      shipping_country VARCHAR(2),

      -- Totals (cached)
      subtotal DECIMAL(12,2) DEFAULT 0,
      shipping_amount DECIMAL(12,2) DEFAULT 0,
      tax_amount DECIMAL(12,2) DEFAULT 0,
      discount_amount DECIMAL(12,2) DEFAULT 0,
      total DECIMAL(12,2) DEFAULT 0,
      currency VARCHAR(3) DEFAULT 'USD',

      discount_code VARCHAR(100),
      total_weight_grams INTEGER DEFAULT 0,
      items_count INTEGER DEFAULT 0,

      metadata JSONB DEFAULT '{}',
      expires_at TIMESTAMP,
      converted_at TIMESTAMP,
      merged_into_cart_id BIGINT,

      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW(),

      CONSTRAINT phoenix_kit_shop_carts_identity CHECK (user_id IS NOT NULL OR session_id IS NOT NULL)
    );
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_carts_user
    ON #{prefix_str}phoenix_kit_shop_carts(user_id) WHERE user_id IS NOT NULL;
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_carts_session
    ON #{prefix_str}phoenix_kit_shop_carts(session_id) WHERE session_id IS NOT NULL;
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_carts_status
    ON #{prefix_str}phoenix_kit_shop_carts(status);
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_shop_carts_active_user
    ON #{prefix_str}phoenix_kit_shop_carts(user_id)
    WHERE user_id IS NOT NULL AND status = 'active';
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_shop_carts_active_session
    ON #{prefix_str}phoenix_kit_shop_carts(session_id)
    WHERE session_id IS NOT NULL AND status = 'active' AND user_id IS NULL;
    """

    execute """
    COMMENT ON TABLE #{prefix_str}phoenix_kit_shop_carts IS
    'Shopping carts for users and guests with status tracking';
    """

    # ===========================================
    # 5. CART ITEMS TABLE
    # ===========================================

    execute """
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_shop_cart_items (
      id BIGSERIAL PRIMARY KEY,
      uuid UUID NOT NULL DEFAULT gen_random_uuid(),

      cart_id BIGINT NOT NULL REFERENCES #{prefix_str}phoenix_kit_shop_carts(id) ON DELETE CASCADE,
      product_id BIGINT REFERENCES #{prefix_str}phoenix_kit_shop_products(id) ON DELETE SET NULL,

      -- Snapshot at add time
      product_title VARCHAR(255) NOT NULL,
      product_slug VARCHAR(255),
      product_sku VARCHAR(100),
      product_image VARCHAR(500),

      -- Pricing (snapshot)
      unit_price DECIMAL(12,2) NOT NULL,
      compare_at_price DECIMAL(12,2),
      currency VARCHAR(3) DEFAULT 'USD',

      quantity INTEGER NOT NULL DEFAULT 1,
      line_total DECIMAL(12,2) NOT NULL,

      weight_grams INTEGER DEFAULT 0,
      taxable BOOLEAN DEFAULT true,

      -- For variants (future)
      variant_id BIGINT,
      variant_options JSONB DEFAULT '{}',

      metadata JSONB DEFAULT '{}',

      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW(),

      CONSTRAINT phoenix_kit_shop_cart_items_quantity_positive CHECK (quantity > 0)
    );
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_cart_items_cart
    ON #{prefix_str}phoenix_kit_shop_cart_items(cart_id);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_cart_items_product
    ON #{prefix_str}phoenix_kit_shop_cart_items(product_id);
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_shop_cart_items_unique
    ON #{prefix_str}phoenix_kit_shop_cart_items(cart_id, product_id)
    WHERE variant_id IS NULL;
    """

    execute """
    COMMENT ON TABLE #{prefix_str}phoenix_kit_shop_cart_items IS
    'Cart items with price snapshots for consistency';
    """

    # ===========================================
    # 6. PAYMENT OPTIONS TABLE
    # ===========================================

    execute """
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_payment_options (
      id BIGSERIAL PRIMARY KEY,
      uuid UUID NOT NULL DEFAULT gen_random_uuid(),

      -- Identity
      name VARCHAR(255) NOT NULL,
      code VARCHAR(50) NOT NULL,
      type VARCHAR(20) NOT NULL DEFAULT 'offline',

      -- Provider (for online payments)
      provider VARCHAR(50),

      -- Display
      description TEXT,
      instructions TEXT,
      icon VARCHAR(100) DEFAULT 'hero-banknotes',

      -- Configuration
      active BOOLEAN DEFAULT false,
      position INTEGER DEFAULT 0,
      requires_billing_profile BOOLEAN DEFAULT true,

      -- Additional settings
      settings JSONB DEFAULT '{}',

      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW(),

      CONSTRAINT phoenix_kit_payment_options_code_unique UNIQUE (code)
    );
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_payment_options_active
    ON #{prefix_str}phoenix_kit_payment_options(active);
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_payment_options_position
    ON #{prefix_str}phoenix_kit_payment_options(position);
    """

    execute """
    COMMENT ON TABLE #{prefix_str}phoenix_kit_payment_options IS
    'Available payment methods for checkout (COD, bank transfer, online payments)';
    """

    # ===========================================
    # 7. ADD PAYMENT OPTION TO CARTS
    # ===========================================

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_carts
    ADD COLUMN IF NOT EXISTS payment_option_id BIGINT
    REFERENCES #{prefix_str}phoenix_kit_payment_options(id) ON DELETE SET NULL;
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_carts_payment_option
    ON #{prefix_str}phoenix_kit_shop_carts(payment_option_id);
    """

    # ===========================================
    # 8. SEED SETTINGS AND PAYMENT OPTIONS
    # ===========================================

    seed_settings(prefix_str)
    seed_payment_options(prefix_str)

    # ===========================================
    # 9. UPDATE VERSION
    # ===========================================

    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '45'"
  end

  @doc """
  Rollback the V45 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix, do: "#{prefix}.", else: ""

    # Drop cart items first (has FK to carts)
    execute "DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_shop_cart_items CASCADE;"

    # Drop carts (has FK to shipping_methods and payment_options)
    execute "DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_shop_carts CASCADE;"

    # Drop payment options
    execute "DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_payment_options CASCADE;"

    # Drop shipping methods
    execute "DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_shop_shipping_methods CASCADE;"

    # Drop products (has FK to categories)
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

  # Seed default payment options
  defp seed_payment_options(prefix_str) do
    execute """
    INSERT INTO #{prefix_str}phoenix_kit_payment_options
      (name, code, type, provider, description, instructions, icon, active, position, requires_billing_profile)
    VALUES
      (
        'Cash on Delivery',
        'cod',
        'offline',
        NULL,
        'Pay when you receive your order',
        'Payment will be collected upon delivery. Please have the exact amount ready.',
        'hero-banknotes',
        true,
        1,
        true
      ),
      (
        'Bank Transfer',
        'bank_transfer',
        'offline',
        NULL,
        'Pay via bank transfer',
        'You will receive invoice with bank details after order confirmation.',
        'hero-building-library',
        false,
        2,
        true
      ),
      (
        'Pay with Card',
        'stripe',
        'online',
        'stripe',
        'Secure payment with credit or debit card',
        NULL,
        'hero-credit-card',
        false,
        3,
        false
      ),
      (
        'PayPal',
        'paypal',
        'online',
        'paypal',
        'Pay securely with your PayPal account',
        NULL,
        'hero-credit-card',
        false,
        4,
        false
      )
    ON CONFLICT (code) DO UPDATE SET
      name = EXCLUDED.name,
      description = EXCLUDED.description,
      instructions = EXCLUDED.instructions,
      icon = EXCLUDED.icon,
      position = EXCLUDED.position,
      requires_billing_profile = EXCLUDED.requires_billing_profile;
    """
  end
end
