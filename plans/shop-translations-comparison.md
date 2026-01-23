# Shop Translations: Approach Comparison

## Overview

Comparison of two approaches for multi-language support in Shop module (Products, Categories).

| Aspect | Current: Separate translations JSONB | Proposed: Localized Fields |
|--------|--------------------------------------|---------------------------|
| Status | ✅ Implemented | 📋 Planned |
| Data model | Canonical field + translations map | All-in-one map per field |
| Language tagging | Implicit for canonical | Explicit for all |

## Approach 1: Separate translations JSONB (Current)

### Data Structure

```elixir
# Product schema
%Product{
  title: "Geometric Planter",           # String, implicit default language
  slug: "geometric-planter",            # String
  description: "Modern faceted pot",    # String
  translations: %{                      # JSONB
    "ru" => %{
      "title" => "Геометрическое кашпо",
      "slug" => "geometricheskoe-kashpo",
      "description" => "Современное кашпо"
    },
    "es" => %{
      "title" => "Maceta Geométrica",
      "slug" => "maceta-geometrica"
    }
  }
}
```

### Pros

1. **Backward compatible** - Existing code works unchanged
2. **Simple single-language queries** - `product.title` returns string directly
3. **Compact for single language** - No overhead when only one language used
4. **Implemented and tested** - All phases complete, UI working

### Cons

1. **Language ambiguity** - Canonical fields have no language tag
2. **CSV import problem** - Can't determine language of imported data
3. **Default language change** - If default changes, canonical data becomes orphaned
4. **Nested access** - `translations["ru"]["title"]` vs `title["ru"]`
5. **Duplication of structure** - Field names repeated in translations

### Problem Example: CSV Import

```elixir
# Import from CSV: title = "Геометрическое кашпо"
# System default language: "en"
#
# Result: title stored as canonical (English?)
# Later: User realizes it's Russian
# Problem: Can't retroactively tag the language

%Product{
  title: "Геометрическое кашпо",  # Actually Russian, but tagged as default (en)
  translations: %{}
}
```

---

## Approach 2: Localized Fields (Proposed)

### Data Structure

```elixir
# Product schema
%Product{
  title: %{                             # JSONB map
    "en" => "Geometric Planter",
    "ru" => "Геометрическое кашпо",
    "es" => "Maceta Geométrica"
  },
  slug: %{                              # JSONB map
    "en" => "geometric-planter",
    "ru" => "geometricheskoe-kashpo",
    "es" => "maceta-geometrica"
  },
  description: %{                       # JSONB map
    "en" => "Modern faceted pot",
    "ru" => "Современное кашпо"
  }
  # No separate translations field
}
```

### Pros

1. **Explicit language tagging** - Every value has a language key
2. **CSV import clarity** - Specify language at import time
3. **Default language change safe** - Data integrity preserved
4. **Simpler access pattern** - `title["ru"]` directly
5. **Self-documenting** - Clear what languages exist
6. **Single source of truth** - No canonical/translations split

### Cons

1. **Breaking change** - Requires migration of existing data
2. **Schema refactoring** - All `field :title, :string` → `field :title, :map`
3. **Helper functions required** - Need `get_title(product, "ru")` for fallback
4. **Larger data for single language** - `%{"en" => "X"}` vs `"X"`
5. **Index complexity** - GIN indexes on each localized field
6. **Query changes** - All queries need updating

### Problem Solved: CSV Import

```elixir
# Import from CSV: title = "Геометрическое кашпо"
# User specifies: language = "ru"
#
# Result: Properly tagged

%Product{
  title: %{"ru" => "Геометрическое кашпо"},
  slug: %{"ru" => "geometricheskoe-kashpo"}
}

# Later: Add English translation
%Product{
  title: %{
    "ru" => "Геометрическое кашпо",
    "en" => "Geometric Planter"
  }
}
```

---

## Technical Comparison

### Database Schema

| Aspect | Current | Proposed |
|--------|---------|----------|
| title column | `VARCHAR` | `JSONB` |
| slug column | `VARCHAR` | `JSONB` |
| description column | `TEXT` | `JSONB` |
| translations column | `JSONB` | ❌ Removed |
| Indexes | GIN on translations | GIN on each field |

### Query Patterns

**Get translated title:**

```elixir
# Current
Translations.get_field(product, :title, "ru")
# Falls back: translations["ru"]["title"] → product.title

# Proposed
product.title["ru"] || product.title[default_lang()]
# Or: Translations.get(product, :title, "ru")
```

**Find by slug:**

```sql
-- Current
WHERE translations->'ru'->>'slug' = 'maceta' OR slug = 'maceta'

-- Proposed
WHERE slug->'ru' = '"maceta"'
```

### Migration Path

```sql
-- Convert title from string to JSONB map
ALTER TABLE phoenix_kit_shop_products
ALTER COLUMN title TYPE jsonb
USING jsonb_build_object('en', title);

-- Merge existing translations
UPDATE phoenix_kit_shop_products
SET title = title || translations->'ru'->'title'
WHERE translations->'ru'->'title' IS NOT NULL;

-- Drop translations column
ALTER TABLE phoenix_kit_shop_products
DROP COLUMN translations;
```

### Ecto Schema Changes

```elixir
# Current
schema "phoenix_kit_shop_products" do
  field :title, :string
  field :slug, :string
  field :description, :string
  field :translations, :map, default: %{}
end

# Proposed
schema "phoenix_kit_shop_products" do
  field :title, :map, default: %{}
  field :slug, :map, default: %{}
  field :description, :map, default: %{}
  # translations field removed
end
```

---

## Recommendation

### For New Projects: Localized Fields

- Cleaner data model
- No language ambiguity
- Better for multi-language from start

### For PhoenixKit Shop: Evaluate Migration Cost

Current implementation is complete and working. Migration to Localized Fields requires:

1. Database migration with data conversion
2. Schema changes (6 fields for Product, 3 for Category)
3. All helper functions rewritten
4. Admin UI updates
5. Public storefront updates
6. CSV import updates
7. Testing all scenarios

**Decision**: Create implementation plan for Localized Fields approach as v2, keeping current approach as v1 for stability.

---

## Files Reference

### Current Implementation (v1)
- `lib/modules/shop/translations.ex` - Translation helpers
- `lib/modules/shop/slug_resolver.ex` - Slug lookup
- `lib/modules/shop/web/components/translation_tabs.ex` - UI component
- `plans/shop-translations.md` - Original plan

### Proposed Implementation (v2)
- `plans/shop-localized-fields.md` - New plan (to be created)
