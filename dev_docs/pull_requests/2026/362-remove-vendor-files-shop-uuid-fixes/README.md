# PR #362 — Remove orphaned vendor file copy, fix shop UUID field references

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/362
**Author:** @alexdont
**Merged:** 2026-02-24 into `dev`
**Additions:** +24 | **Deletions:** -85

---

## Goal

Three independent clean-up fixes bundled into one PR:

1. Remove dead `copy_vendor_files/1` code from the update Mix task that was never called after the install task switched strategies.
2. Fix a silent pattern match failure across 9 shop modules — they were still matching `featured_image_id` after the field was renamed to `featured_image_uuid` during the UUID migration.
3. Correct the Dialyzer ignore list: remove 3 entries that were genuinely resolved, keep 2 that remain necessary on Erlang 27.

---

## What Changed

### 1. `lib/mix/tasks/phoenix_kit.update.ex` — Remove orphaned vendor copy

**Problem:** The `update` task called `copy_vendor_files(js_path)` and `get_phoenix_kit_assets_dir/0`, which copied `phoenix_kit.js` and `phoenix_kit_sortable.js` into `assets/js/vendor/` on every update run. This copying was made obsolete in commit `819fd400` when the `install` task switched to direct `deps/` imports — the vendored copies were never loaded and were silently written to disk on each run.

**Fix:** Deleted `copy_vendor_files/1` (38 lines) and `get_phoenix_kit_assets_dir/0` (17 lines). The `update_js_imports/1` path no longer calls them.

**Files:**
| File | Change |
|------|--------|
| `lib/mix/tasks/phoenix_kit.update.ex` | Removed `-55` lines |

---

### 2. Shop module — Fix `featured_image_id` → `featured_image_uuid` references

**Problem:** During the UUID migration, the `Product` schema field `featured_image_id` was renamed to `featured_image_uuid`. However, 9 web modules and the `ImageMigrationWorker` were never updated. Because the old field name was used in pattern match heads (not in map access), errors were **silent** — Elixir fell through to the next function clause or returned `nil` instead of raising. Real-world impact:

- Products with storage images would not display their featured image in product detail, catalog, or category views.
- `has_storage_images?/1` always returned `false` for products with a featured image.
- `product_form.ex` submitted `featured_image_id` as a string map key, which the changeset ignored (wrong key), leaving `featured_image_uuid` blank on save.
- `ImageMigrationWorker` built `attrs` with key `:featured_image_id` instead of `:featured_image_uuid`, so migrated images were never persisted.

**Files:**

| File | Change |
|------|--------|
| `lib/modules/shop/schemas/category.ex` | Doc comment only |
| `lib/modules/shop/web/catalog_category.ex` | `first_image/1` pattern match |
| `lib/modules/shop/web/catalog_product.ex` | `first_image/1`, `has_storage_images?/1`, `product_image_ids/1` (×2) |
| `lib/modules/shop/web/product_detail.ex` | `has_multiple_images?/1`, `get_first_image_id/1`, `get_image_url_by_id/2`, `get_all_product_images/1` |
| `lib/modules/shop/web/product_form.ex` | `Map.put("featured_image_id", ...)` → `Map.put("featured_image_uuid", ...)` |
| `lib/modules/shop/web/products.ex` | `get_product_thumbnail/1` |
| `lib/modules/shop/web/shop_catalog.ex` | `first_image/1` |
| `lib/modules/shop/web/test_shop.ex` | Display text in test page |
| `lib/modules/shop/workers/image_migration_worker.ex` | Variable names + attrs key |

---

### 3. `.dialyzer_ignore.exs` — Correct ignore list after UUID migration

**Context:** Commit 2 ("Fix featured_image_id references…") also removed 5 Dialyzer ignores marked as stale. Commit 3 ("Fix dialyzer ignore for conn_case/data_case on Erlang 27 CI") restored 2 of them after discovering they still trigger on Erlang 27 used in CI.

**Net result** (3 entries removed, 2 kept with updated comment):

| Entry | Action | Reason |
|-------|--------|--------|
| `publishing/web/editor.ex` `unused_fun` | Removed | Genuinely resolved |
| `publishing/workers/migrate_legacy_structure_worker.ex` `pattern_match` | Removed | Genuinely resolved |
| `migrations/uuid_fk_columns.ex` `pattern_match` | Removed | UUID FK migration complete; false positive gone |
| `test/support/conn_case.ex` `unknown_function` | Kept | Erlang 27 (CI) still triggers; resolved in Erlang 28 |
| `test/support/data_case.ex` `unknown_function` | Kept | Same as above |

---

## Impact

- **No schema or migration changes** — this is a pure code fix; existing DB data is unaffected.
- **No API or config changes** — internal field rename was already done at the schema level.
- **Silent data loss fixed** — `product_form.ex` was the most dangerous: product saves would silently clear the featured image on every edit. This is now corrected.
- **Worker fix** — `ImageMigrationWorker` jobs previously imported images but failed to link them; re-running jobs on affected products will now correctly persist `featured_image_uuid`.
