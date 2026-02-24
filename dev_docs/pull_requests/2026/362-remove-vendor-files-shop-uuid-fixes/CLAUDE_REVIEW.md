# PR #362 Review — Remove orphaned vendor file copy, fix shop UUID field references

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/362
**Author:** @alexdont
**Merged:** 2026-02-24 into `dev`
**Reviewer:** Claude Sonnet 4.6

---

## Verdict: Clean fixes — no issues found

Three self-contained clean-ups. The code changes are correct, safe, and complete. The UUID field rename sweep across shop modules is the most impactful fix — it closes a silent data-loss path in `product_form.ex`.

| Area | Assessment |
|------|------------|
| Dead code removal (`copy_vendor_files`) | Clean deletion, no callers missed |
| Shop UUID field rename (9 files + worker) | All occurrences corrected; pattern matches, map keys, variable names, and comments |
| Dialyzer ignore list | Correctly pruned; Erlang 27-specific entries preserved |

---

## Commit 1 — Remove orphaned `copy_vendor_files` from update task

**File:** `lib/mix/tasks/phoenix_kit.update.ex`

The deletion is correct. `copy_vendor_files/1` was the only caller of `get_phoenix_kit_assets_dir/0`, and it was called in exactly one place (`update_js_imports/1`) which is now removed. Nothing else in the codebase depended on the vendor directory being populated by this task.

The removed `get_phoenix_kit_assets_dir/0` had a multi-path fallback strategy (`:code.priv_dir` → common locations) that is no longer needed since the install task switched to `import "../../deps/phoenix_kit/..."` style imports. Keeping it would have been misleading dead code.

**No concerns.**

---

## Commit 2 — Fix `featured_image_id` → `featured_image_uuid` in shop module

**Files:** 9 web modules + `ImageMigrationWorker`

### Correctness

All 14 occurrences of `featured_image_id` in shop code have been updated. The fix correctly handles three distinct usage patterns:

**Pattern match heads** (8 occurrences across 6 files): The old pattern silently fell through to the next function clause — typically a fallback returning `nil`. The fix is straightforward and correct.

```elixir
# Before (silently fell through to nil fallback)
defp first_image(%{featured_image_id: id}) when is_binary(id) do

# After
defp first_image(%{featured_image_uuid: id}) when is_binary(id) do
```

**Map key in form params** (`product_form.ex`): This was the highest-impact bug. The changeset cast for `featured_image_uuid` was receiving a map with key `"featured_image_id"` — which it ignored. The fix:

```elixir
# Before (changeset discarded this — wrong key)
|> Map.put("featured_image_id", featured_id)

# After
|> Map.put("featured_image_uuid", featured_id)
```

**Variable names in `image_migration_worker.ex`**: The local variable rename (`featured_image_id` → `featured_image_uuid`) is cosmetically correct and matches the final `attrs` key. The logic is unchanged.

### Completeness check

The fix covers the web layer and the migration worker. The schema itself (`lib/modules/shop/schemas/product.ex`) had already been updated previously — this PR updates the consumers.

`test_shop.ex` updates a documentation string in the test UI, which is a correct but low-priority change.

### Severity of original bugs (for historical record)

| Bug | Impact |
|-----|--------|
| `product_form.ex` wrong map key | **High** — every product save silently cleared featured image |
| `catalog_product.ex` `has_storage_images?/1` | **Medium** — image gallery UI never shown for storage-backed products |
| `catalog_product.ex` `product_image_ids/1` | **Medium** — image list always started from gallery images, featured was skipped |
| `product_detail.ex` multi-image detection | **Medium** — product image carousel not shown |
| `image_migration_worker.ex` attrs key | **Medium** — image migration jobs completed without error but data wasn't persisted |
| `first_image/1` in catalog/shop views | **Low** — product thumbnails fell back to legacy image URL path |

**No concerns with the fix itself.**

---

## Commit 3 — Fix Dialyzer ignore for `conn_case`/`data_case` on Erlang 27

The backstory: commit 2 removed 5 "stale" Dialyzer ignores including the ExUnit `unknown_function` entries for `conn_case.ex` and `data_case.ex`. Commit 3 restores those two because CI runs on Erlang 27 where they still trigger (the issue is resolved in Erlang 28 used locally).

The net diff to `.dialyzer_ignore.exs` across the whole PR:

| Entry removed | Reason correct |
|---------------|----------------|
| `publishing/web/editor.ex` `unused_fun` | Yes — publishing module was refactored |
| `publishing/workers/migrate_legacy_structure_worker.ex` `pattern_match` | Yes — worker was migrated |
| `migrations/uuid_fk_columns.ex` `pattern_match` | Yes — UUID FK migration is complete; the prefix-vs-nil pattern match is no longer a Dialyzer false positive |

The updated comment on the ExUnit entries correctly documents the Erlang version dependency, which will help future maintainers understand why they're still needed.

**No concerns.**

---

## Minor Notes (non-blocking)

1. **`image_migration_worker.ex` logger message** — The log line `"featured_image_id=#{featured_image_uuid}"` label text was updated to `"featured_image_uuid=#{featured_image_uuid}"`. This is cosmetically correct and makes future log parsing accurate.

2. **`test_shop.ex` doc string** — The string `"featured_image_id - main product image"` → `"featured_image_uuid - main product image"` in the test UI is correct. Not a functional fix but keeps the test page accurate.

3. **`category.ex` doc comment only** — The `Category` module's `get_image/2` docstring mentions `featured_image_id` in the priority list; updating it to `featured_image_uuid` is correct documentation hygiene.

---

## Summary

This is a well-scoped clean-up PR. The vendor file removal is safe dead code elimination. The shop UUID fixes resolve real silent failures — particularly the product form saving with the wrong map key, which would have wiped featured images on every edit. The Dialyzer ignore correction is careful and accurately documents the Erlang 27/28 difference. No follow-up work needed.
