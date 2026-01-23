# Shop Module: Localized Fields Plan

## Overview

Refactor Shop module translations from separate `translations` JSONB field to localized fields approach, where each translatable field stores a map of language → value.

**Motivation**: Current approach has canonical fields without language tags. When importing data or changing default language, the original language of canonical data is ambiguous.

## Current Status: 📋 PLANNED

| Phase | Status |
|-------|--------|
| Phase 1: Database Migration | ⏳ Pending |
| Phase 2: Schema Updates | ⏳ Pending |
| Phase 3: Helper Module Refactor | ⏳ Pending |
| Phase 4: Slug Resolver Updates | ⏳ Pending |
| Phase 5: Context API Updates | ⏳ Pending |
| Phase 6: Admin UI Updates | ⏳ Pending |
| Phase 7: Public Storefront Updates | ⏳ Pending |
| Phase 8: CSV Import Updates | ⏳ Pending |

## Data Model Comparison

### Before (Current)

```elixir
%Product{
  title: "Geometric Planter",           # String (implicit language)
  slug: "geometric-planter",
  description: "Modern pot",
  translations: %{
    "ru" => %{"title" => "Кашпо", "slug" => "kashpo"}
  }
}
```

### After (Proposed)

```elixir
%Product{
  title: %{"en" => "Geometric Planter", "ru" => "Кашпо"},
  slug: %{"en" => "geometric-planter", "ru" => "kashpo"},
  description: %{"en" => "Modern pot"}
  # No translations field
}
```

## Localized Fields

### Product

| Field | Current Type | New Type | Notes |
|-------|--------------|----------|-------|
| title | `:string` | `:map` | Required for default language |
| slug | `:string` | `:map` | Unique per language |
| description | `:string` | `:map` | Optional |
| body_html | `:string` | `:map` | Optional HTML |
| seo_title | `:string` | `:map` | Max 60 chars |
| seo_description | `:string` | `:map` | Max 160 chars |
| translations | `:map` | ❌ Removed | Data merged into fields |

### Category

| Field | Current Type | New Type | Notes |
|-------|--------------|----------|-------|
| name | `:string` | `:map` | Required for default language |
| slug | `:string` | `:map` | Unique per language |
| description | `:string` | `:map` | Optional |
| translations | `:map` | ❌ Removed | Data merged into fields |

## Implementation Phases

### Phase 1: Database Migration

**File**: `lib/phoenix_kit/migrations/postgres/v47.ex` (new)

```elixir
defmodule PhoenixKit.Migrations.Postgres.V47 do
  @moduledoc """
  Convert Shop module to localized fields approach.

  Changes:
  - Convert string columns to JSONB for localized content
  - Merge translations into localized fields
  - Drop translations column
  """

  use Ecto.Migration

  def up do
    # Step 1: Add temporary columns for Products
    alter table(:phoenix_kit_shop_products) do
      add :title_new, :jsonb, default: "{}"
      add :slug_new, :jsonb, default: "{}"
      add :description_new, :jsonb, default: "{}"
      add :body_html_new, :jsonb, default: "{}"
      add :seo_title_new, :jsonb, default: "{}"
      add :seo_description_new, :jsonb, default: "{}"
    end

    alter table(:phoenix_kit_shop_categories) do
      add :name_new, :jsonb, default: "{}"
      add :slug_new, :jsonb, default: "{}"
      add :description_new, :jsonb, default: "{}"
    end

    # Step 2: Migrate canonical data to new JSONB fields
    # NOTE: User must set default_language before running migration
    execute """
    UPDATE phoenix_kit_shop_products
    SET
      title_new = CASE
        WHEN title IS NOT NULL AND title != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          title
        )
        ELSE '{}'::jsonb
      END,
      slug_new = CASE
        WHEN slug IS NOT NULL AND slug != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          slug
        )
        ELSE '{}'::jsonb
      END,
      description_new = CASE
        WHEN description IS NOT NULL AND description != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          description
        )
        ELSE '{}'::jsonb
      END,
      body_html_new = CASE
        WHEN body_html IS NOT NULL AND body_html != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          body_html
        )
        ELSE '{}'::jsonb
      END,
      seo_title_new = CASE
        WHEN seo_title IS NOT NULL AND seo_title != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          seo_title
        )
        ELSE '{}'::jsonb
      END,
      seo_description_new = CASE
        WHEN seo_description IS NOT NULL AND seo_description != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          seo_description
        )
        ELSE '{}'::jsonb
      END
    """

    execute """
    UPDATE phoenix_kit_shop_categories
    SET
      name_new = CASE
        WHEN name IS NOT NULL AND name != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          name
        )
        ELSE '{}'::jsonb
      END,
      slug_new = CASE
        WHEN slug IS NOT NULL AND slug != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          slug
        )
        ELSE '{}'::jsonb
      END,
      description_new = CASE
        WHEN description IS NOT NULL AND description != ''
        THEN jsonb_build_object(
          COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
          description
        )
        ELSE '{}'::jsonb
      END
    """

    # Step 3: Merge translations into new fields (with NULL-safe aggregation)
    # Products: merge each field from translations
    for field <- ~w(title slug description body_html seo_title seo_description) do
      execute """
      UPDATE phoenix_kit_shop_products p
      SET #{field}_new = #{field}_new || COALESCE(
        (SELECT jsonb_object_agg(lang, val)
         FROM (
           SELECT key AS lang, translations->key->>$1 AS val
           FROM phoenix_kit_shop_products, jsonb_object_keys(translations) AS key
           WHERE id = p.id AND translations->key->>$1 IS NOT NULL
         ) sub
        ), '{}'::jsonb)
      WHERE translations IS NOT NULL AND translations != '{}'::jsonb
      """, [field]
    end

    # Categories: merge each field from translations
    for field <- ~w(name slug description) do
      execute """
      UPDATE phoenix_kit_shop_categories c
      SET #{field}_new = #{field}_new || COALESCE(
        (SELECT jsonb_object_agg(lang, val)
         FROM (
           SELECT key AS lang, translations->key->>$1 AS val
           FROM phoenix_kit_shop_categories, jsonb_object_keys(translations) AS key
           WHERE id = c.id AND translations->key->>$1 IS NOT NULL
         ) sub
        ), '{}'::jsonb)
      WHERE translations IS NOT NULL AND translations != '{}'::jsonb
      """, [field]
    end

    # Step 4: Swap columns - drop old, rename new
    # Products
    alter table(:phoenix_kit_shop_products) do
      remove :title
      remove :slug
      remove :description
      remove :body_html
      remove :seo_title
      remove :seo_description
      remove :translations
    end

    rename table(:phoenix_kit_shop_products), :title_new, to: :title
    rename table(:phoenix_kit_shop_products), :slug_new, to: :slug
    rename table(:phoenix_kit_shop_products), :description_new, to: :description
    rename table(:phoenix_kit_shop_products), :body_html_new, to: :body_html
    rename table(:phoenix_kit_shop_products), :seo_title_new, to: :seo_title
    rename table(:phoenix_kit_shop_products), :seo_description_new, to: :seo_description

    # Categories
    alter table(:phoenix_kit_shop_categories) do
      remove :name
      remove :slug
      remove :description
      remove :translations
    end

    rename table(:phoenix_kit_shop_categories), :name_new, to: :name
    rename table(:phoenix_kit_shop_categories), :slug_new, to: :slug
    rename table(:phoenix_kit_shop_categories), :description_new, to: :description

    # Step 5: Create GIN indexes for slug lookups only (most common query pattern)
    create index(:phoenix_kit_shop_products, [:slug], using: :gin)
    create index(:phoenix_kit_shop_categories, [:slug], using: :gin)
  end

  def down do
    # Get default language for rollback
    default_lang = "en"

    # Step 1: Add back original columns
    alter table(:phoenix_kit_shop_products) do
      add :title_old, :string
      add :slug_old, :string
      add :description_old, :text
      add :body_html_old, :text
      add :seo_title_old, :string
      add :seo_description_old, :string
      add :translations_old, :map, default: %{}
    end

    alter table(:phoenix_kit_shop_categories) do
      add :name_old, :string
      add :slug_old, :string
      add :description_old, :text
      add :translations_old, :map, default: %{}
    end

    # Step 2: Extract default language values back to string columns
    execute """
    UPDATE phoenix_kit_shop_products
    SET
      title_old = title->>COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
      slug_old = slug->>COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
      description_old = description->>COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
      body_html_old = body_html->>COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
      seo_title_old = seo_title->>COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
      seo_description_old = seo_description->>COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en')
    """

    execute """
    UPDATE phoenix_kit_shop_categories
    SET
      name_old = name->>COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
      slug_old = slug->>COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en'),
      description_old = description->>COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en')
    """

    # Step 3: Rebuild translations map from non-default languages
    # NOTE: This is lossy - default language values become canonical strings
    execute """
    UPDATE phoenix_kit_shop_products p
    SET translations_old = COALESCE(
      (SELECT jsonb_object_agg(lang, jsonb_build_object(
        'title', p.title->lang,
        'slug', p.slug->lang,
        'description', p.description->lang,
        'body_html', p.body_html->lang,
        'seo_title', p.seo_title->lang,
        'seo_description', p.seo_description->lang
      ))
      FROM (
        SELECT DISTINCT key AS lang
        FROM jsonb_object_keys(p.title) AS key
        WHERE key != COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en')
      ) langs), '{}'::jsonb)
    """

    execute """
    UPDATE phoenix_kit_shop_categories c
    SET translations_old = COALESCE(
      (SELECT jsonb_object_agg(lang, jsonb_build_object(
        'name', c.name->lang,
        'slug', c.slug->lang,
        'description', c.description->lang
      ))
      FROM (
        SELECT DISTINCT key AS lang
        FROM jsonb_object_keys(c.name) AS key
        WHERE key != COALESCE((SELECT value FROM phoenix_kit_settings WHERE key = 'default_language'), 'en')
      ) langs), '{}'::jsonb)
    """

    # Step 4: Drop GIN indexes
    drop index(:phoenix_kit_shop_products, [:slug])
    drop index(:phoenix_kit_shop_categories, [:slug])

    # Step 5: Swap columns back
    alter table(:phoenix_kit_shop_products) do
      remove :title
      remove :slug
      remove :description
      remove :body_html
      remove :seo_title
      remove :seo_description
    end

    rename table(:phoenix_kit_shop_products), :title_old, to: :title
    rename table(:phoenix_kit_shop_products), :slug_old, to: :slug
    rename table(:phoenix_kit_shop_products), :description_old, to: :description
    rename table(:phoenix_kit_shop_products), :body_html_old, to: :body_html
    rename table(:phoenix_kit_shop_products), :seo_title_old, to: :seo_title
    rename table(:phoenix_kit_shop_products), :seo_description_old, to: :seo_description
    rename table(:phoenix_kit_shop_products), :translations_old, to: :translations

    alter table(:phoenix_kit_shop_categories) do
      remove :name
      remove :slug
      remove :description
    end

    rename table(:phoenix_kit_shop_categories), :name_old, to: :name
    rename table(:phoenix_kit_shop_categories), :slug_old, to: :slug
    rename table(:phoenix_kit_shop_categories), :description_old, to: :description
    rename table(:phoenix_kit_shop_categories), :translations_old, to: :translations
  end
end
```

### Phase 2: Schema Updates

**File**: `lib/modules/shop/schemas/product.ex`

```elixir
schema "phoenix_kit_shop_products" do
  # Localized fields (JSONB maps)
  field :title, :map, default: %{}
  field :slug, :map, default: %{}
  field :description, :map, default: %{}
  field :body_html, :map, default: %{}
  field :seo_title, :map, default: %{}
  field :seo_description, :map, default: %{}

  # Non-localized fields (unchanged)
  field :price, :decimal
  field :status, :string
  # ...
end
```

**File**: `lib/modules/shop/schemas/category.ex`

```elixir
schema "phoenix_kit_shop_categories" do
  # Localized fields
  field :name, :map, default: %{}
  field :slug, :map, default: %{}
  field :description, :map, default: %{}

  # Non-localized fields (unchanged)
  field :position, :integer
  # ...
end
```

### Phase 3: Helper Module Refactor

**File**: `lib/modules/shop/translations.ex`

```elixir
defmodule PhoenixKit.Modules.Shop.Translations do
  @moduledoc """
  Localized fields helper for Shop module.

  All translatable fields are maps: %{"en" => "value", "ru" => "значение"}
  """

  alias PhoenixKit.Modules.Languages

  @doc """
  Get localized value with fallback chain.

  ## Examples

      product.title
      #=> %{"en" => "Planter", "ru" => "Кашпо"}

      get(product, :title, "ru")
      #=> "Кашпо"

      get(product, :title, "fr")  # Not present
      #=> "Planter"  # Falls back to default language
  """
  def get(entity, field, language) do
    field_map = Map.get(entity, field) || %{}

    field_map[language] ||
      field_map[default_language()] ||
      first_available(field_map)
  end

  @doc """
  Set localized value for a language.

  ## Examples

      put(product, :title, "ru", "Новое название")
      #=> %Product{title: %{"en" => "Planter", "ru" => "Новое название"}}
  """
  def put(entity, field, language, value) do
    current = Map.get(entity, field) || %{}
    updated = Map.put(current, language, value)
    Map.put(entity, field, updated)
  end

  @doc """
  Build changeset attrs for localized field update.
  """
  def changeset_attrs(entity, field, language, value) do
    current = Map.get(entity, field) || %{}
    updated = Map.put(current, language, value)
    %{field => updated}
  end

  @doc """
  Get all languages that have a value for a field.
  """
  def available_languages(entity, field) do
    field_map = Map.get(entity, field) || %{}

    field_map
    |> Map.keys()
    |> Enum.filter(fn lang ->
      value = Map.get(field_map, lang)
      value != nil and value != ""
    end)
  end

  @doc """
  Check if translation exists for language.
  """
  def has_translation?(entity, field, language) do
    field_map = Map.get(entity, field) || %{}
    value = Map.get(field_map, language)
    value != nil and value != ""
  end

  @doc """
  Get translation completeness for a language.
  """
  def translation_status(entity, language, fields) do
    present = Enum.count(fields, fn field ->
      has_translation?(entity, field, language)
    end)

    total = length(fields)

    %{
      complete: present,
      total: total,
      percentage: if(total > 0, do: round(present / total * 100), else: 0)
    }
  end

  def default_language do
    if Code.ensure_loaded?(Languages) and Languages.enabled?() do
      Languages.get_default_language_code()
    else
      "en"
    end
  end

  defp first_available(map) when map == %{}, do: nil
  defp first_available(map) do
    {_key, value} = Enum.at(map, 0)
    value
  end
end
```

### Phase 4: Slug Resolver Updates

**File**: `lib/modules/shop/slug_resolver.ex`

```elixir
defmodule PhoenixKit.Modules.Shop.SlugResolver do
  @moduledoc """
  URL slug resolver for localized fields.
  """

  import Ecto.Query
  alias PhoenixKit.Modules.Shop.{Product, Category}

  @doc """
  Find product by localized slug.

  Query: slug->>'es' = 'maceta'
  """
  def find_product_by_slug(url_slug, language, opts \\ []) do
    lang = normalize_language(language)

    query = from(p in Product,
      where: fragment("slug->>? = ?", ^lang, ^url_slug),
      limit: 1
    )

    query = if exclude_id = opts[:exclude_id] do
      from(p in query, where: p.id != ^exclude_id)
    else
      query
    end

    case repo().one(query) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  @doc """
  Check if slug exists for language.
  """
  def product_slug_exists?(slug, language, opts \\ []) do
    case find_product_by_slug(slug, language, opts) do
      {:ok, _} -> true
      {:error, :not_found} -> false
    end
  end

  @doc """
  Get best slug for product and language.
  """
  def product_slug(product, language) do
    lang = normalize_language(language)
    product.slug[lang] || product.slug[default_language()] || first_slug(product.slug)
  end

  # Similar functions for Category...

  defp normalize_language(lang) when byte_size(lang) == 2 do
    # Convert base code to full dialect if DialectMapper available
    if Code.ensure_loaded?(PhoenixKit.Modules.Languages.DialectMapper) do
      PhoenixKit.Modules.Languages.DialectMapper.base_to_dialect(lang)
    else
      lang
    end
  end
  defp normalize_language(lang), do: lang

  defp default_language, do: PhoenixKit.Modules.Shop.Translations.default_language()
  defp first_slug(map) when map == %{}, do: nil
  defp first_slug(map), do: map |> Map.values() |> List.first()
  defp repo, do: PhoenixKit.RepoHelper.repo()
end
```

### Phase 5: Context API Updates

**File**: `lib/modules/shop/shop.ex`

Update all public functions to work with localized fields:

```elixir
# Get product with localized content
def get_product_localized(id, language) do
  product = get_product(id)

  %{product |
    _title: Translations.get(product, :title, language),
    _slug: Translations.get(product, :slug, language),
    _description: Translations.get(product, :description, language)
  }
end

# Update product translation
def update_product_translation(product, language, attrs) do
  changes =
    Enum.reduce(attrs, %{}, fn {field, value}, acc ->
      Map.merge(acc, Translations.changeset_attrs(product, field, language, value))
    end)

  update_product(product, changes)
end

# Find by localized slug
def get_product_by_slug_localized(slug, language, opts \\ []) do
  SlugResolver.find_product_by_slug(slug, language, opts)
end
```

### Phase 6: Admin UI Updates

**File**: `lib/modules/shop/web/product_form.ex`

- Keep language tabs UI
- Update form field bindings for map access
- Update save logic for localized fields

```elixir
# Form field for localized content
def translation_field(assigns) do
  # field_name format: product[title][en]
  field_name = "#{@form_prefix}[#{@field}][#{@language}]"
  current_value = @entity[@field][@language] || ""

  ~H"""
  <input type="text" name={field_name} value={current_value} />
  """
end
```

### Phase 7: Public Storefront Updates

**Files**:
- `lib/modules/shop/web/catalog_product.ex`
- `lib/modules/shop/web/catalog_category.ex`
- `lib/modules/shop/web/shop_catalog.ex`

```elixir
# In mount/render, use Translations helper
assigns = assign(socket, :localized_title, Translations.get(@product, :title, @current_language))
```

### Phase 8: CSV Import Updates

**File**: `lib/modules/shop/csv_import.ex`

Add language parameter to import:

```elixir
def import_products(file_path, language) do
  # Parse CSV
  rows = CSV.parse(file_path)

  # Create products with language-tagged fields
  Enum.map(rows, fn row ->
    %{
      title: %{language => row["title"]},
      slug: %{language => row["slug"]},
      description: %{language => row["description"]},
      price: row["price"]
    }
  end)
end
```

**Admin UI**: Add language selector dropdown before CSV upload.

## Validation

### Changeset Validations

```elixir
def changeset(product, attrs) do
  product
  |> cast(attrs, [:title, :slug, :description, ...])
  |> validate_localized_required(:title, default_language())
  |> validate_localized_unique(:slug)
end

defp validate_localized_required(changeset, field, language) do
  value = get_field(changeset, field)

  if value[language] in [nil, ""] do
    add_error(changeset, field, "#{language} translation is required")
  else
    changeset
  end
end

defp validate_localized_unique(changeset, field) do
  # Custom validation for slug uniqueness per language
end
```

## Testing Checklist

- [ ] Migration converts existing data correctly
- [ ] Fallback chain works (requested → default → first)
- [ ] Admin UI tabs show all languages
- [ ] Admin UI saves to correct language key
- [ ] CSV import with language parameter
- [ ] SEO URLs work with localized slugs
- [ ] Slug uniqueness enforced per language
- [ ] Public pages display localized content

## Rollback Plan

If issues arise, rollback migration:

1. Restore `translations` column
2. Convert localized fields back to strings + translations map
3. Revert schema changes
4. Revert helper functions

## Dependencies

- Languages module (for enabled languages, default language)
- Existing translation UI components (mostly reusable)

## Estimated Effort

| Phase | Complexity |
|-------|------------|
| Phase 1: Migration | High (data conversion) |
| Phase 2: Schema | Low |
| Phase 3: Helpers | Medium |
| Phase 4: Slug Resolver | Medium |
| Phase 5: Context API | Medium |
| Phase 6: Admin UI | Medium |
| Phase 7: Storefront | Low |
| Phase 8: CSV Import | Low |

**Total**: Significant refactor, but cleaner result.

## Decision

**Proceed?** This approach solves the language ambiguity problem but requires substantial refactoring. Evaluate based on:

1. How often CSV import is used
2. Likelihood of default language changes
3. Tolerance for current approach limitations
