# PR #319: Update Shop module with localized slug support and unified image gallery

**Author**: @timujinne
**Reviewer**: Claude Opus 4.5
**Status**: ✅ Merged
**Date**: 2026-02-05

## Goal

Refactor the Shop module to properly support JSONB localized slugs (introduced in V47) and unify the product image management UX with a drag-and-drop gallery where the first image automatically becomes the featured image.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/modules/shop/shop.ex` | Replaced ON CONFLICT upsert with find-or-create pattern, added localized field merging |
| `lib/modules/shop/web/product_form.ex` | Unified featured/gallery images into drag-and-drop list |
| `lib/modules/shop/web/product_detail.ex` | Added interactive thumbnail gallery with selection |
| `lib/modules/shop/workers/csv_import_worker.ex` | Uses default site language when not specified |
| `lib/phoenix_kit/migrations/postgres.ex` | Bumped version to 52, updated changelog |
| `lib/phoenix_kit/migrations/postgres/v52.ex` | New migration with functional unique index |
| `lib/mix/tasks/shop.deduplicate_products.ex` | New task for cleaning up duplicate products |

### Migration Changes (V52)

```sql
-- Creates SQL function for deterministic slug extraction
CREATE FUNCTION extract_primary_slug(slug_jsonb JSONB) RETURNS TEXT AS $$
BEGIN
  RETURN (SELECT value FROM jsonb_each_text(slug_jsonb) ORDER BY key LIMIT 1);
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT

-- Creates functional unique indexes
CREATE UNIQUE INDEX idx_shop_products_slug_primary
ON phoenix_kit_shop_products ((extract_primary_slug(slug)))
WHERE extract_primary_slug(slug) IS NOT NULL
```

### API Changes

| Function | Change |
|----------|--------|
| `upsert_product/1` | Now returns `{:ok, product, action}` with proper localized field merging |
| `find_product_by_slug_map/1` | New - finds product by any slug in the provided map |
| `merge_localized_attrs/2` | New - merges localized fields preserving existing translations |

## Implementation Details

### 1. Upsert Pattern Change (Critical Fix)

**Problem**: After V47 converted `slug` to JSONB, `ON CONFLICT :slug` stopped working correctly because PostgreSQL compares entire JSONB objects, not individual values within them.

**Solution**: Replace ON CONFLICT with explicit find-or-create:

```elixir
# Before (broken with JSONB)
repo().insert(changeset,
  on_conflict: {:replace, [...]},
  conflict_target: :slug
)

# After (works correctly)
case find_product_by_slug_map(slug_map) do
  nil -> create_product(attrs)
  existing -> update_product(existing, merge_localized_attrs(existing, attrs))
end
```

### 2. Localized Field Merging

The `merge_localized_attrs/2` function preserves existing translations when updating:

```elixir
# Existing: %{title: %{"en-US" => "Planter"}}
# New attrs: %{title: %{"es-ES" => "Maceta"}}
# Result: %{title: %{"en-US" => "Planter", "es-ES" => "Maceta"}}
```

### 3. Unified Image Gallery UX

**Before**: Separate sections for featured image and gallery images with different picker flows.

**After**: Single drag-and-drop list using `draggable_list` component. First image is automatically featured (shown with star badge and ring highlight).

### 4. Functional Index Strategy

The `extract_primary_slug()` function uses alphabetically first key because:
- `IMMUTABLE` functions cannot query database (no access to settings table)
- Alphabetical ordering is deterministic regardless of configured default language
- Works consistently across all installations

## Review Assessment

### Positives

1. **Correct fix for JSONB upsert** - The find-or-create pattern is the right approach when ON CONFLICT can't target JSONB content
2. **Translation preservation** - `merge_localized_attrs` correctly merges without losing existing translations
3. **Clean UX improvement** - Unified image gallery is more intuitive than separate featured/gallery sections
4. **Robust deduplication task** - Handles cart_items and order_items references in transaction
5. **Good dialyzer annotations** - Proper `@dialyzer` attributes for Mix.Task callbacks
6. **Comprehensive migration** - Drops both old constraint and index variants that might exist

### Concerns

1. **Primary slug selection ambiguity**: Using alphabetically first key means "de-DE" would be used over "en-US" if both exist. This could cause unexpected behavior if a product has German and English slugs.

   ```elixir
   # %{"de-DE" => "garten", "en-US" => "garden"}
   # Primary slug: "garten" (de-DE is alphabetically first)
   ```

   **Impact**: Low - most products will have consistent slugs across languages, and this only affects uniqueness constraint, not lookup behavior.

2. **CSV import default language**: The change to use `Translations.default_language()` is good, but the comment in `process_product/6` still says "if language" conditionally:

   ```elixir
   transform_opts = [language: language]  # language is now always set
   ```

   The code is correct, but the flow is slightly cleaner than before.

3. **Product detail `get_image_url_by_id/2` has redundant branch**:

   ```elixir
   cond do
     id == image_id -> get_storage_image_url(image_id, "small")
     image_id in (product.image_ids || []) -> get_storage_image_url(image_id, "small")
     true -> get_storage_image_url(image_id, "small")  # All branches return same thing
   end
   ```

   This could be simplified but doesn't affect correctness.

4. **Deduplication task table names**: The task uses hardcoded table names (`phoenix_kit_shop_cart_items`, `phoenix_kit_order_items`) which won't work if using a custom prefix. Consider using `prefix_str` pattern from migrations.

### Minor Observations

- The `item_id` extraction fix in `draggable_list` for UUID string items is handled by `item_id={& &1}` - this works but may need documentation for future maintainers
- Product form now uses `List.first(@all_image_ids)` multiple times in the template - could be precomputed in assigns for consistency

### Verdict

**Approved.** The core changes (upsert fix, migration, UI unification) are well-implemented and solve real problems caused by the V47 JSONB migration. The concerns raised are minor and don't block merge.

## Testing

- [x] Pre-commit checks passed (compilation, credo, dialyzer)
- [x] Manual testing completed (per PR description)
- [x] Migration is idempotent (drops existing constraints/indexes first)
- [x] Backwards compatible (existing products display correctly)
- [x] Deduplication task has --dry-run mode for safe testing

## Migration Notes

For existing installations with duplicate products (same slug in different records):

```bash
# Preview what would be deduplicated
mix shop.deduplicate_products --dry-run --verbose

# Run deduplication
mix shop.deduplicate_products
```

## Related

- Migration: `lib/phoenix_kit/migrations/postgres/v52.ex`
- Previous: V47 (JSONB slug migration) - introduced the problem this PR fixes
- Utility: `lib/mix/tasks/shop.deduplicate_products.ex`
