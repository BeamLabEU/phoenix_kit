defmodule PhoenixKit.Migrations.Postgres.V47 do
  @moduledoc """
  V47: Shop Localized Fields

  Converts Shop module from separate translations JSONB to localized fields approach.

  ## Changes

  - Product fields (title, slug, description, body_html, seo_title, seo_description)
    change from VARCHAR/TEXT to JSONB maps
  - Category fields (name, slug, description) change from VARCHAR/TEXT to JSONB maps
  - Removes translations column from both tables
  - Each field stores language → value map: %{"en" => "Product", "ru" => "Продукт"}

  ## Migration Strategy

  1. Add temporary _new columns as JSONB
  2. Migrate canonical data with default language key from settings
  3. Merge existing translations into new fields
  4. Drop old columns, rename _new to original names
  5. Create GIN indexes for slug lookups

  ## Rollback

  Extracts default language values back to string columns and rebuilds
  the translations map from non-default language data.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Step 1: Add temporary columns for Products
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    ADD COLUMN IF NOT EXISTS title_new JSONB DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS slug_new JSONB DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS description_new JSONB DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS body_html_new JSONB DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS seo_title_new JSONB DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS seo_description_new JSONB DEFAULT '{}'::jsonb
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    ADD COLUMN IF NOT EXISTS name_new JSONB DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS slug_new JSONB DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS description_new JSONB DEFAULT '{}'::jsonb
    """

    # Step 2: Migrate canonical data to new JSONB fields
    # NOTE: User should set default_language in phoenix_kit_settings before migration
    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_products
    SET
      title_new = CASE
        WHEN title IS NOT NULL AND title != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          title
        )
        ELSE '{}'::jsonb
      END,
      slug_new = CASE
        WHEN slug IS NOT NULL AND slug != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          slug
        )
        ELSE '{}'::jsonb
      END,
      description_new = CASE
        WHEN description IS NOT NULL AND description != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          description
        )
        ELSE '{}'::jsonb
      END,
      body_html_new = CASE
        WHEN body_html IS NOT NULL AND body_html != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          body_html
        )
        ELSE '{}'::jsonb
      END,
      seo_title_new = CASE
        WHEN seo_title IS NOT NULL AND seo_title != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          seo_title
        )
        ELSE '{}'::jsonb
      END,
      seo_description_new = CASE
        WHEN seo_description IS NOT NULL AND seo_description != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          seo_description
        )
        ELSE '{}'::jsonb
      END
    """

    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_categories
    SET
      name_new = CASE
        WHEN name IS NOT NULL AND name != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          name
        )
        ELSE '{}'::jsonb
      END,
      slug_new = CASE
        WHEN slug IS NOT NULL AND slug != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          slug
        )
        ELSE '{}'::jsonb
      END,
      description_new = CASE
        WHEN description IS NOT NULL AND description != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          description
        )
        ELSE '{}'::jsonb
      END
    """

    # Step 3: Merge translations into new fields (with NULL-safe aggregation)
    # Products: merge each field from translations
    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_products p
    SET title_new = p.title_new || COALESCE(
      (SELECT jsonb_object_agg(key, p.translations->key->>'title')
       FROM jsonb_object_keys(p.translations) AS key
       WHERE p.translations->key->>'title' IS NOT NULL
      ), '{}'::jsonb)
    WHERE p.translations IS NOT NULL AND p.translations != '{}'::jsonb
    """

    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_products p
    SET slug_new = p.slug_new || COALESCE(
      (SELECT jsonb_object_agg(key, p.translations->key->>'slug')
       FROM jsonb_object_keys(p.translations) AS key
       WHERE p.translations->key->>'slug' IS NOT NULL
      ), '{}'::jsonb)
    WHERE p.translations IS NOT NULL AND p.translations != '{}'::jsonb
    """

    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_products p
    SET description_new = p.description_new || COALESCE(
      (SELECT jsonb_object_agg(key, p.translations->key->>'description')
       FROM jsonb_object_keys(p.translations) AS key
       WHERE p.translations->key->>'description' IS NOT NULL
      ), '{}'::jsonb)
    WHERE p.translations IS NOT NULL AND p.translations != '{}'::jsonb
    """

    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_products p
    SET body_html_new = p.body_html_new || COALESCE(
      (SELECT jsonb_object_agg(key, p.translations->key->>'body_html')
       FROM jsonb_object_keys(p.translations) AS key
       WHERE p.translations->key->>'body_html' IS NOT NULL
      ), '{}'::jsonb)
    WHERE p.translations IS NOT NULL AND p.translations != '{}'::jsonb
    """

    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_products p
    SET seo_title_new = p.seo_title_new || COALESCE(
      (SELECT jsonb_object_agg(key, p.translations->key->>'seo_title')
       FROM jsonb_object_keys(p.translations) AS key
       WHERE p.translations->key->>'seo_title' IS NOT NULL
      ), '{}'::jsonb)
    WHERE p.translations IS NOT NULL AND p.translations != '{}'::jsonb
    """

    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_products p
    SET seo_description_new = p.seo_description_new || COALESCE(
      (SELECT jsonb_object_agg(key, p.translations->key->>'seo_description')
       FROM jsonb_object_keys(p.translations) AS key
       WHERE p.translations->key->>'seo_description' IS NOT NULL
      ), '{}'::jsonb)
    WHERE p.translations IS NOT NULL AND p.translations != '{}'::jsonb
    """

    # Categories: merge each field from translations
    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_categories c
    SET name_new = c.name_new || COALESCE(
      (SELECT jsonb_object_agg(key, c.translations->key->>'name')
       FROM jsonb_object_keys(c.translations) AS key
       WHERE c.translations->key->>'name' IS NOT NULL
      ), '{}'::jsonb)
    WHERE c.translations IS NOT NULL AND c.translations != '{}'::jsonb
    """

    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_categories c
    SET slug_new = c.slug_new || COALESCE(
      (SELECT jsonb_object_agg(key, c.translations->key->>'slug')
       FROM jsonb_object_keys(c.translations) AS key
       WHERE c.translations->key->>'slug' IS NOT NULL
      ), '{}'::jsonb)
    WHERE c.translations IS NOT NULL AND c.translations != '{}'::jsonb
    """

    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_categories c
    SET description_new = c.description_new || COALESCE(
      (SELECT jsonb_object_agg(key, c.translations->key->>'description')
       FROM jsonb_object_keys(c.translations) AS key
       WHERE c.translations->key->>'description' IS NOT NULL
      ), '{}'::jsonb)
    WHERE c.translations IS NOT NULL AND c.translations != '{}'::jsonb
    """

    # Step 4: Drop old columns (including unique constraint on slug)
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    DROP CONSTRAINT IF EXISTS phoenix_kit_shop_products_slug_key
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    DROP COLUMN IF EXISTS title,
    DROP COLUMN IF EXISTS slug,
    DROP COLUMN IF EXISTS description,
    DROP COLUMN IF EXISTS body_html,
    DROP COLUMN IF EXISTS seo_title,
    DROP COLUMN IF EXISTS seo_description,
    DROP COLUMN IF EXISTS translations
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    DROP CONSTRAINT IF EXISTS phoenix_kit_shop_categories_slug_key
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    DROP COLUMN IF EXISTS name,
    DROP COLUMN IF EXISTS slug,
    DROP COLUMN IF EXISTS description,
    DROP COLUMN IF EXISTS translations
    """

    # Step 5: Rename _new columns to original names
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    RENAME COLUMN title_new TO title
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    RENAME COLUMN slug_new TO slug
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    RENAME COLUMN description_new TO description
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    RENAME COLUMN body_html_new TO body_html
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    RENAME COLUMN seo_title_new TO seo_title
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    RENAME COLUMN seo_description_new TO seo_description
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    RENAME COLUMN name_new TO name
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    RENAME COLUMN slug_new TO slug
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    RENAME COLUMN description_new TO description
    """

    # Step 6: Create GIN indexes for slug lookups (most common query pattern)
    execute """
    CREATE INDEX IF NOT EXISTS phoenix_kit_shop_products_slug_gin_idx
    ON #{prefix_str}phoenix_kit_shop_products USING gin (slug)
    """

    execute """
    CREATE INDEX IF NOT EXISTS phoenix_kit_shop_categories_slug_gin_idx
    ON #{prefix_str}phoenix_kit_shop_categories USING gin (slug)
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '47'"
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Step 1: Add back original columns
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    ADD COLUMN IF NOT EXISTS title_old VARCHAR(255),
    ADD COLUMN IF NOT EXISTS slug_old VARCHAR(255),
    ADD COLUMN IF NOT EXISTS description_old TEXT,
    ADD COLUMN IF NOT EXISTS body_html_old TEXT,
    ADD COLUMN IF NOT EXISTS seo_title_old VARCHAR(255),
    ADD COLUMN IF NOT EXISTS seo_description_old TEXT,
    ADD COLUMN IF NOT EXISTS translations_old JSONB DEFAULT '{}'::jsonb
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    ADD COLUMN IF NOT EXISTS name_old VARCHAR(255),
    ADD COLUMN IF NOT EXISTS slug_old VARCHAR(255),
    ADD COLUMN IF NOT EXISTS description_old TEXT,
    ADD COLUMN IF NOT EXISTS translations_old JSONB DEFAULT '{}'::jsonb
    """

    # Step 2: Extract default language values back to string columns
    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_products
    SET
      title_old = title->>COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
      slug_old = slug->>COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
      description_old = description->>COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
      body_html_old = body_html->>COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
      seo_title_old = seo_title->>COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
      seo_description_old = seo_description->>COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en')
    """

    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_categories
    SET
      name_old = name->>COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
      slug_old = slug->>COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en'),
      description_old = description->>COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en')
    """

    # Step 3: Rebuild translations map from non-default languages
    # NOTE: This is lossy - default language values become canonical strings
    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_products p
    SET translations_old = COALESCE(
      (SELECT jsonb_object_agg(key, jsonb_build_object(
        'title', p.title->key,
        'slug', p.slug->key,
        'description', p.description->key,
        'body_html', p.body_html->key,
        'seo_title', p.seo_title->key,
        'seo_description', p.seo_description->key
      ))
      FROM jsonb_object_keys(p.title) AS key
      WHERE key != COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en')
      ), '{}'::jsonb)
    """

    execute """
    UPDATE #{prefix_str}phoenix_kit_shop_categories c
    SET translations_old = COALESCE(
      (SELECT jsonb_object_agg(key, jsonb_build_object(
        'name', c.name->key,
        'slug', c.slug->key,
        'description', c.description->key
      ))
      FROM jsonb_object_keys(c.name) AS key
      WHERE key != COALESCE((SELECT value FROM #{prefix_str}phoenix_kit_settings WHERE key = 'default_language'), 'en')
      ), '{}'::jsonb)
    """

    # Step 4: Drop GIN indexes
    execute """
    DROP INDEX IF EXISTS #{prefix_str}phoenix_kit_shop_products_slug_gin_idx
    """

    execute """
    DROP INDEX IF EXISTS #{prefix_str}phoenix_kit_shop_categories_slug_gin_idx
    """

    # Step 5: Drop JSONB columns
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    DROP COLUMN IF EXISTS title,
    DROP COLUMN IF EXISTS slug,
    DROP COLUMN IF EXISTS description,
    DROP COLUMN IF EXISTS body_html,
    DROP COLUMN IF EXISTS seo_title,
    DROP COLUMN IF EXISTS seo_description
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    DROP COLUMN IF EXISTS name,
    DROP COLUMN IF EXISTS slug,
    DROP COLUMN IF EXISTS description
    """

    # Step 6: Rename _old columns back to original names
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    RENAME COLUMN title_old TO title
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    RENAME COLUMN slug_old TO slug
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    RENAME COLUMN description_old TO description
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    RENAME COLUMN body_html_old TO body_html
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    RENAME COLUMN seo_title_old TO seo_title
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    RENAME COLUMN seo_description_old TO seo_description
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    RENAME COLUMN translations_old TO translations
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    RENAME COLUMN name_old TO name
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    RENAME COLUMN slug_old TO slug
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    RENAME COLUMN description_old TO description
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    RENAME COLUMN translations_old TO translations
    """

    # Step 7: Recreate unique constraints on slug
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_products
    ADD CONSTRAINT phoenix_kit_shop_products_slug_key UNIQUE (slug)
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_shop_categories
    ADD CONSTRAINT phoenix_kit_shop_categories_slug_key UNIQUE (slug)
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '46'"
  end
end
