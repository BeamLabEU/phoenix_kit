defmodule PhoenixKit.Migrations.Postgres.V54 do
  @moduledoc """
  V54: Category Featured Product + Import Config download_images

  Categories currently have two image fields: image_id (Storage upload) and
  image_url (external URL fallback). This migration replaces image_url with
  featured_product_id — a FK to products — so the category image automatically
  comes from a representative product.

  Also adds the missing download_images column to import_configs that was
  present in the Ecto schema but never added via migration.

  ## Changes

  - Adds featured_product_id BIGINT column to categories with FK to products
  - Creates index on featured_product_id
  - Auto-populates featured_product_id for categories without image_id
    (picks first active product with featured_image_id)
  - Drops image_url column
  - Adds download_images BOOLEAN column to import_configs (default: false)

  ## Image Resolution Priority (new)

  1. image_id — direct Storage upload (unchanged)
  2. featured_product_id → product's featured_image_id
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Step 1: Add featured_product_id column with FK (IF NOT EXISTS for idempotency)
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    ADD COLUMN IF NOT EXISTS featured_product_id BIGINT
      REFERENCES #{prefix_str}phoenix_kit_shop_products(id) ON DELETE SET NULL
    """

    # Step 2: Create index
    execute """
    CREATE INDEX IF NOT EXISTS idx_shop_categories_featured_product
    ON #{prefix_str}phoenix_kit_shop_categories(featured_product_id)
    """

    # Step 3: Auto-populate for categories without image_id
    # Pick first active product with featured_image_id per category
    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_categories c
    SET featured_product_id = sub.product_id
    FROM (
      SELECT DISTINCT ON (p.category_id) p.category_id, p.id AS product_id
      FROM #{prefix_str}phoenix_kit_shop_products p
      WHERE p.status = 'active' AND p.featured_image_id IS NOT NULL
      ORDER BY p.category_id, p.id
    ) sub
    WHERE c.id = sub.category_id AND c.image_id IS NULL
    """

    # Step 4: Drop image_url column
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    DROP COLUMN IF EXISTS image_url
    """

    # Step 5: Add download_images to import_configs (was in schema but missing from DB)
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_import_configs
    ADD COLUMN IF NOT EXISTS download_images BOOLEAN DEFAULT false
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '54'"
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Drop download_images from import_configs
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_import_configs
    DROP COLUMN IF EXISTS download_images
    """

    # Restore image_url column
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    ADD COLUMN image_url TEXT
    """

    # Drop index
    execute """
    DROP INDEX IF EXISTS #{prefix_str}idx_shop_categories_featured_product
    """

    # Drop featured_product_id column
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    DROP COLUMN IF EXISTS featured_product_id
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '53'"
  end
end
