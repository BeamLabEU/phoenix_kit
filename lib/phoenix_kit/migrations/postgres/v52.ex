defmodule PhoenixKit.Migrations.Postgres.V52 do
  @moduledoc """
  V52: Shop localized slug functional unique index

  After V47 converted slug fields to JSONB maps, the old unique constraint
  on the slug column no longer works correctly for upsert operations.

  PostgreSQL's ON CONFLICT compares entire JSONB objects, so:
  - {"en-US": "my-slug"} and {"en-US": "my-slug", "es-ES": "otro"} are different

  This migration creates a functional unique index that extracts the primary
  slug value for uniqueness checking.

  ## Changes

  - Creates extract_primary_slug() SQL function to get the primary slug value
  - Creates unique functional index on products using the function
  - Creates unique functional index on categories using the function
  - Removes old incorrect unique indexes if they exist

  ## Primary Slug Resolution

  The function extracts the slug value from the alphabetically first language key.
  This is deterministic, language-agnostic, and works regardless of which language
  is configured as default. The function must be IMMUTABLE for the unique index
  to work, so it cannot query the settings table for default_language.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Step 1: Drop any old incorrect unique indexes
    execute """
    DROP INDEX IF EXISTS #{prefix_str}phoenix_kit_shop_products_slug_unique_idx
    """

    execute """
    DROP INDEX IF EXISTS #{prefix_str}phoenix_kit_shop_categories_slug_unique_idx
    """

    # Drop constraint-based unique if it exists on JSONB
    # V45 creates 'phoenix_kit_shop_products_slug_unique'
    # V47 rollback creates 'phoenix_kit_shop_products_slug_key'
    # Both are incorrect on JSONB columns, so drop whichever exists
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    DROP CONSTRAINT IF EXISTS phoenix_kit_shop_products_slug_unique
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    DROP CONSTRAINT IF EXISTS phoenix_kit_shop_products_slug_key
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    DROP CONSTRAINT IF EXISTS phoenix_kit_shop_categories_slug_unique
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    DROP CONSTRAINT IF EXISTS phoenix_kit_shop_categories_slug_key
    """

    # Step 2: Create SQL function to extract primary slug from JSONB
    # Uses alphabetically first key for deterministic, language-agnostic extraction.
    # The function is IMMUTABLE (required for unique index) so it cannot query
    # the settings table for default_language. Alphabetical key order ensures
    # consistent behavior regardless of which language is configured as default.
    execute """
    CREATE OR REPLACE FUNCTION #{prefix_str}extract_primary_slug(slug_jsonb JSONB)
    RETURNS TEXT AS $$
    BEGIN
      RETURN (SELECT value FROM jsonb_each_text(slug_jsonb) ORDER BY key LIMIT 1);
    END;
    $$ LANGUAGE plpgsql IMMUTABLE STRICT
    """

    # Step 3: Create functional unique index for products
    # Only include products that have a non-null primary slug
    execute """
    CREATE UNIQUE INDEX idx_shop_products_slug_primary
    ON #{prefix_str}phoenix_kit_shop_products (
      (#{prefix_str}extract_primary_slug(slug))
    )
    WHERE #{prefix_str}extract_primary_slug(slug) IS NOT NULL
    """

    # Step 4: Create functional unique index for categories
    execute """
    CREATE UNIQUE INDEX idx_shop_categories_slug_primary
    ON #{prefix_str}phoenix_kit_shop_categories (
      (#{prefix_str}extract_primary_slug(slug))
    )
    WHERE #{prefix_str}extract_primary_slug(slug) IS NOT NULL
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '52'"
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Drop functional indexes
    execute """
    DROP INDEX IF EXISTS #{prefix_str}idx_shop_products_slug_primary
    """

    execute """
    DROP INDEX IF EXISTS #{prefix_str}idx_shop_categories_slug_primary
    """

    # Drop the function
    execute """
    DROP FUNCTION IF EXISTS #{prefix_str}extract_primary_slug(JSONB)
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '51'"
  end
end
