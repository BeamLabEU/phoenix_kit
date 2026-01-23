# Shop Module Translations Plan

## Overview

Add multi-language support to the Shop module (Products, Categories) using JSONB storage pattern, integrating with the existing Languages module infrastructure.

## Current Status: ✅ ALL PHASES COMPLETE

| Phase | Status |
|-------|--------|
| Phase 1: Database Schema | ✅ Complete |
| Phase 3: Translation Helper Module | ✅ Complete |
| Phase 4: URL Slug Resolver | ✅ Complete |
| Phase 5: Context API Updates | ✅ Complete |
| Phase 6: Admin UI - Product Form | ✅ Complete |
| Phase 7: Admin UI - Category Form | ✅ Complete |
| Phase 8: Public Storefront Integration | ✅ Complete |

### Backend Implementation Summary

| Aspect | Status |
|--------|--------|
| Migration V46 | ✅ Updated with translations columns |
| Products `translations` field | ✅ Added and working |
| Categories `translations` field | ✅ Added and working |
| GIN indexes | ✅ Created for efficient queries |
| Schema updates | ✅ Product.ex and Category.ex updated |
| Languages module | ✅ Fully functional, used by Publishing |
| Translations helper | ✅ `lib/modules/shop/translations.ex` |
| SlugResolver | ✅ `lib/modules/shop/slug_resolver.ex` |
| Context API | ✅ Localized functions in `shop.ex` |
| TranslationTabs component | ✅ `lib/modules/shop/web/components/translation_tabs.ex` |
| Product Form UI | ✅ Language tabs integrated in `product_form.ex` |
| Category Form UI | ✅ Language tabs integrated in `category_form.ex` |
| Public Storefront | ✅ Localized lookup in `catalog_product.ex`, `catalog_category.ex`, `shop_catalog.ex` |

## Research Summary (Historical)

### Decision: Separate `translations` JSONB field

**Why not use existing `metadata`:**
- Products `metadata` already stores pricing/options data
- Mixing concerns leads to coupling issues
- Harder to index for URL slug lookups
- Harder to validate translation structure

**Why JSONB over separate table:**
- Fewer JOINs for listing pages (most common query pattern)
- Atomic updates (product + translations in one operation)
- Consistent with existing JSONB patterns (`tags`, `images`, `option_schema`)
- Simpler schema evolution (add fields without migrations)

## Translation Schema Design

### Products Translation Structure

```json
{
  "en-US": {
    "title": "Geometric Planter",
    "slug": "geometric-planter",
    "description": "Modern faceted plant pot...",
    "body_html": "<p>Full HTML description...</p>",
    "seo_title": "Geometric Planter | Modern Home Decor",
    "seo_description": "Buy our modern geometric planter..."
  },
  "es-ES": {
    "title": "Maceta Geométrica",
    "slug": "maceta-geometrica",
    "description": "Maceta moderna facetada...",
    "body_html": "<p>Descripción completa...</p>",
    "seo_title": "Maceta Geométrica | Decoración Moderna",
    "seo_description": "Compra nuestra maceta geométrica..."
  }
}
```

### Categories Translation Structure

```json
{
  "en-US": {
    "name": "Vases & Planters",
    "slug": "vases-planters",
    "description": "Beautiful planters for your home"
  },
  "es-ES": {
    "name": "Jarrones y Macetas",
    "slug": "jarrones-macetas",
    "description": "Hermosas macetas para tu hogar"
  }
}
```

### Translatable Fields

| Entity | Field | Type | Notes |
|--------|-------|------|-------|
| **Product** | title | string | Required per language |
| | slug | string | URL-friendly, unique per language |
| | description | text | Short description |
| | body_html | text | Full HTML content |
| | seo_title | string | Max 60 chars |
| | seo_description | string | Max 160 chars |
| **Category** | name | string | Required per language |
| | slug | string | URL-friendly, unique per language |
| | description | text | Optional |

### Non-translatable Fields (remain in main table)

- `price`, `compare_at_price`, `cost_per_item` (numeric)
- `currency`, `taxable`, `weight_grams` (configuration)
- `status`, `product_type` (system)
- `images`, `featured_image_id` (media)
- `tags` (could be translated later, but low priority)
- `metadata._option_values`, `metadata._price_modifiers` (pricing)

## Implementation Phases

### Phase 1: Database Schema ✅ COMPLETE

**Approach**: Instead of new V47 migration, updated V46 and applied changes directly via Tidewave MCP.

**Changes made**:
1. Added `translations JSONB DEFAULT '{}'` to `phoenix_kit_shop_products`
2. Added `translations JSONB DEFAULT '{}'` to `phoenix_kit_shop_categories`
3. Created GIN indexes for efficient JSONB queries
4. Updated V46 migration for new installations

**Files modified**:
- `lib/phoenix_kit/migrations/postgres/v46.ex` - Added translations columns
- `lib/modules/shop/schemas/product.ex` - Added `field :translations, :map, default: %{}`
- `lib/modules/shop/schemas/category.ex` - Added `field :translations, :map, default: %{}`

**Verified working**:
```elixir
# Test update
{:ok, product} = Shop.update_product(product, %{translations: %{
  "en-US" => %{"title" => "...", "slug" => "..."},
  "es-ES" => %{"title" => "...", "slug" => "..."}
}})

# Test query by slug
SELECT * FROM phoenix_kit_shop_products
WHERE translations->'es-ES'->>'slug' = 'maceta-geometrica-moderna'
```

### Phase 3: Translation Helper Module ✅ COMPLETE

**File**: `lib/modules/shop/translations.ex`

**Key Functions:**
- `get_field(entity, field, language)` - Get translated field with fallback chain
- `get_slug(entity, language)` - Get translated URL slug
- `put_translation(entity, language, map)` - Set translations for a language
- `has_translation?(entity, language)` - Check if translation exists
- `translation_status(entity, language)` - Get completeness stats
- `available_languages(entity)` - List languages with translations
- `translation_changeset_attrs(current, language, params)` - Build changeset attrs

**Fallback Chain:**
1. Exact language match (e.g., "es-ES")
2. Default language from Languages module
3. Canonical field on main entity

### Phase 4: URL Slug Resolver ✅ COMPLETE

**File**: `lib/modules/shop/slug_resolver.ex`

**Key Functions:**
- `find_product_by_slug(slug, language, opts)` - Find product by localized slug
- `find_category_by_slug(slug, language, opts)` - Find category by localized slug
- `product_slug_exists?(slug, language, opts)` - Check slug uniqueness
- `product_slug(product, language)` - Get best slug for language
- Base code normalization (e.g., "en" → "en-US")

### Phase 5: Context API Updates ✅ COMPLETE

**File**: `lib/modules/shop/shop.ex` - Added new section "LOCALIZED API"

**New Functions:**
```elixir
# Get by slug with language awareness
Shop.get_product_by_slug_localized("maceta-geometrica", "es-ES")
Shop.get_category_by_slug_localized("jarrones-macetas", "es-ES")

# Update translations
Shop.update_product_translation(product, "es-ES", %{"title" => "..."})
Shop.update_category_translation(category, "es-ES", %{"name" => "..."})

# List with localized virtual fields
Shop.list_products_localized("es-ES", status: "active")
Shop.list_categories_localized("es-ES")

# Slug helpers
Shop.get_product_slug(product, "es-ES")
Shop.product_slug_exists?("slug", "es-ES", exclude_id: 123)
```

---

**LEGACY PLAN CODE (for reference):**

```elixir
# Original plan code moved to implementation
defmodule PhoenixKit.Modules.Shop.Translations do
  @doc "Set a single translated field"
  def put_field(entity, field, language, value) do
    translations = entity.translations || %{}
    lang_data = Map.get(translations, language, %{})
    updated_lang = Map.put(lang_data, to_string(field), value)
    updated_translations = Map.put(translations, language, updated_lang)
    %{entity | translations: updated_translations}
  end

  @doc "Set full translation for a language"
  def put_translation(entity, language, translation_map) do
    translations = entity.translations || %{}
    # Convert atom keys to strings for consistency
    string_keyed = Map.new(translation_map, fn {k, v} -> {to_string(k), v} end)
    updated = Map.put(translations, language, string_keyed)
    %{entity | translations: updated}
  end

  @doc "Check if entity has translation for language"
  def has_translation?(entity, language) do
    translations = entity.translations || %{}
    case Map.get(translations, language) do
      nil -> false
      map when map == %{} -> false
      _ -> true
    end
  end

  @doc "List available languages for entity"
  def available_languages(entity) do
    translations = entity.translations || %{}
    translations
    |> Map.keys()
    |> Enum.filter(fn lang ->
      Map.get(translations, lang) != %{}
    end)
  end

  @doc "Build changeset attrs with translations"
  def translation_changeset_attrs(current_translations, language, params) do
    lang_data = Map.get(current_translations || %{}, language, %{})
    updated_lang = Map.merge(lang_data, params)
    %{"translations" => Map.put(current_translations || %{}, language, updated_lang)}
  end

  @doc "Translatable fields for products"
  def product_fields, do: @product_fields

  @doc "Translatable fields for categories"
  def category_fields, do: @category_fields
end
```

### Phase 4: URL Slug Lookup

**File**: `lib/modules/shop/slug_resolver.ex`

```elixir
defmodule PhoenixKit.Modules.Shop.SlugResolver do
  @moduledoc """
  Resolves URL slugs to products/categories with language awareness.

  Supports:
  - Per-language URL slugs for SEO
  - Fallback to canonical slug
  - Base code matching (en matches en-US)
  """

  import Ecto.Query
  alias PhoenixKit.Modules.Shop.{Product, Category}
  alias PhoenixKit.Modules.Languages.DialectMapper

  @doc """
  Find product by URL slug for a specific language.

  ## Examples

      find_product_by_slug("maceta-geometrica", "es-ES")
      # => {:ok, %Product{}}

      find_product_by_slug("geometric-planter", "en")
      # => {:ok, %Product{}} (matches en-US via base code)
  """
  def find_product_by_slug(url_slug, language) do
    # Normalize language (en -> en-US)
    lang = normalize_language(language)

    # Query: check translations->'lang'->>'slug' = url_slug
    query = from p in Product,
      where: fragment(
        "translations->?->>'slug' = ? OR slug = ?",
        ^lang, ^url_slug, ^url_slug
      ),
      limit: 1

    case repo().one(query) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  @doc """
  Find category by URL slug for a specific language.
  """
  def find_category_by_slug(url_slug, language) do
    lang = normalize_language(language)

    query = from c in Category,
      where: fragment(
        "translations->?->>'slug' = ? OR slug = ?",
        ^lang, ^url_slug, ^url_slug
      ),
      limit: 1

    case repo().one(query) do
      nil -> {:error, :not_found}
      category -> {:ok, category}
    end
  end

  defp normalize_language(lang) when byte_size(lang) == 2 do
    # Convert base code to full dialect
    DialectMapper.base_to_dialect(lang)
  end
  defp normalize_language(lang), do: lang

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
```

### Phase 5: Context API Updates

**File**: `lib/modules/shop/shop.ex`

Add new functions:

```elixir
# Product translations
def get_product_by_slug_localized(slug, language, opts \\ [])
def update_product_translation(product, language, attrs)
def list_products_localized(language, opts \\ [])

# Category translations
def get_category_by_slug_localized(slug, language, opts \\ [])
def update_category_translation(category, language, attrs)
def list_categories_localized(language, opts \\ [])
```

### Phase 6: Admin UI - Product Form

**File**: `lib/modules/shop/web/product_form.ex`

Add language tabs to product edit form:
- Show enabled languages as tabs
- Each tab shows translatable fields
- Save updates translations JSONB
- Visual indicator for missing translations

### Phase 7: Admin UI - Category Form

**File**: `lib/modules/shop/web/category_form.ex`

Same pattern as product form:
- Language tabs
- Translatable fields per language
- Save to translations JSONB

### Phase 8: Public Storefront Integration

Update storefront templates to use `Translations.get_field/3`:

```heex
<%!-- Product title with language awareness --%>
<h1><%= Translations.get_field(@product, :title, @current_language) %></h1>

<%!-- Product description --%>
<p><%= Translations.get_field(@product, :description, @current_language) %></p>
```

## URL Routing Strategy

### Language-prefixed URLs

```
/shop/products/geometric-planter           # Default language
/es/shop/products/maceta-geometrica        # Spanish (SEO slug)
/ru/shop/products/geometricheskoe-kashpo   # Russian (SEO slug)
```

### Router Integration

Leverage existing language routing from Publishing module pattern:
- Language detection from URL prefix
- Fallback to default language
- Pass `current_language` to assigns

## Testing Strategy

### Unit Tests

1. `Translations` helper functions
2. `SlugResolver` query logic
3. Changeset validation for translations

### Integration Tests

1. Product CRUD with translations
2. Category CRUD with translations
3. URL slug resolution with language fallback

## Acceptance Criteria

- [ ] Products can have translations for title, slug, description, body_html, seo_title, seo_description
- [ ] Categories can have translations for name, slug, description
- [ ] Admin UI shows language tabs when Languages module enabled
- [ ] Admin UI hides language tabs when Languages module disabled (single-language mode)
- [ ] URL slugs can be different per language
- [ ] Slug lookup works with language parameter
- [ ] Fallback to default language when translation missing
- [ ] Fallback to canonical field when no translations exist
- [ ] GIN indexes created for efficient JSONB queries

## Files to Create/Modify

### New Files

| File | Purpose |
|------|---------|
| `lib/phoenix_kit/migrations/postgres/v47.ex` | Add translations columns |
| `lib/modules/shop/translations.ex` | Translation helpers |
| `lib/modules/shop/slug_resolver.ex` | URL slug lookup |

### Modified Files

| File | Changes |
|------|---------|
| `lib/modules/shop/schemas/product.ex` | Add `translations` field |
| `lib/modules/shop/schemas/category.ex` | Add `translations` field |
| `lib/modules/shop/shop.ex` | Add localized API functions |
| `lib/modules/shop/web/product_form.ex` | Language tabs UI |
| `lib/modules/shop/web/category_form.ex` | Language tabs UI |

## Dependencies

- Languages module (for enabled languages list)
- DialectMapper (for base code → dialect conversion)
- Settings (for content language fallback)

## Future Considerations

### Phase 2: AI Auto-Translation (separate plan)

- Universal AI Translator in AI module
- TranslateProductWorker using Translator
- Batch translation for categories + products

### Phase 3: Cart Item Translations

- Store translated product title in cart item
- Snapshot at time of add to cart

### Phase 4: Option Values Translation

- Translate option labels and values
- More complex structure in `option_schema`
