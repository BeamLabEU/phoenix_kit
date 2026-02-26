# PR #370 — Rename SubscriptionPlan to SubscriptionType, fix PR #365 review items

**Author:** timujinne (Tymofii Shapovalov)
**Merged:** 2026-02-26
**Reviewer:** Claude Opus 4.6

## Summary

Large PR with 3 major workstreams:
1. Rename `SubscriptionPlan` to `SubscriptionType` (schema, context, routes, LiveViews, workers, migration V65)
2. Add orphaned media file cleanup system (mix task, Oban worker, UI)
3. Fix PR #365 review items (post_id -> post_uuid, defp proxy -> import)

9 commits, +1425 / -495 lines, 43 files changed.

## Verdict: NEEDS FIXES

## Critical Issues

### 1. `orphaned_files_query/0` references non-existent `phoenix_kit_shop_variants` table

**File:** `lib/modules/storage/storage.ex:728-741`
**Severity:** CRITICAL — will crash at runtime

```elixir
|> where([f], fragment("NOT EXISTS (SELECT 1 FROM phoenix_kit_shop_variants sv WHERE sv.featured_image_id = ?)", f.uuid))
|> where([f], fragment("NOT EXISTS (SELECT 1 FROM phoenix_kit_shop_variants sv WHERE ? = ANY(sv.image_ids))", f.uuid))
```

The `phoenix_kit_shop_variants` table is documented as a "Future Table" in V45 migration but was **never created**. Any call to `find_orphaned_files/1`, `count_orphaned_files/0`, or `file_orphaned?/1` will crash with:

```
** (Postgrex.Error) ERROR 42P01 (undefined_table) relation "phoenix_kit_shop_variants" does not exist
```

This also breaks:
- `mix phoenix_kit.cleanup_orphaned_files` mix task
- Media admin UI orphan filter toggle
- "Delete all orphaned" button in Media UI

**Fix:** Remove both WHERE clauses referencing `phoenix_kit_shop_variants`.

### 2. Default preload `:plan` not updated to `:subscription_type`

**File:** `lib/modules/billing/billing.ex:2628,2669`
**Severity:** HIGH — silent data loss (preload returns nil instead of loaded association)

```elixir
# Line 2628 — list_subscriptions/1
preloads = Keyword.get(opts, :preload, [:plan])

# Line 2669 — list_user_subscriptions/2
preloads = Keyword.get(opts, :preload, [:plan])
```

The Subscription schema's association was renamed from `:plan` to `:subscription_type` (line 83 of subscription.ex), but these two defaults still reference `:plan`. Any caller relying on the default preload will get an Ecto error or silently unloaded association.

**Fix:** Change both to `[:subscription_type]`. Also update the @doc strings at lines 2616 and 2660.

### 3. Empty orphaned files left in working tree

**Files:**
- `lib/modules/billing/web/subscription_plan_form.ex` (0 bytes)
- `lib/modules/billing/web/subscription_plans.ex` (0 bytes)

**Severity:** LOW — clutter, but could confuse developers

These empty files are the old `SubscriptionPlan`-era LiveViews that should have been deleted during the rename.

**Fix:** Delete both files.

## Medium Issues

### 4. Hardcoded table names in orphan detection (no prefix support)

**File:** `lib/modules/storage/storage.ex:677-770`
**Severity:** MEDIUM — breaks multi-tenancy installations

All 13 NOT EXISTS subqueries use hardcoded table names (`phoenix_kit_post_media`, `phoenix_kit_shop_products`, etc.) without respecting the configurable database prefix. Won't work with prefixed schemas.

### 5. `Elixir.TestDeprecated.beam` and `Elixir.TestUsage.beam` committed

**Severity:** LOW — fixed in PR #371

Two compiled BEAM files were accidentally committed in this PR. PR #371 removed them and added `*.beam` to `.gitignore`.

## What's Correct

- V65 migration: properly renames table, columns, indexes with idempotent guards
- SubscriptionType schema: correctly uses UUID primary key, all fields renamed
- Subscription belongs_to: correctly references `:subscription_type` with UUID FK
- Workers (dunning, renewal): correctly use `subscription.subscription_type`
- All LiveViews properly renamed and functional
- Route rename from `/admin/billing/plans` to `/admin/billing/subscription-types`
- PR #365 fixes (post_id -> post_uuid, defp proxy -> import) are clean
- Orphaned file Oban worker: correctly checks file still exists and still orphaned before deleting
- Mix task: proper dry-run mode with `--delete` flag requirement

## Action Items

| # | Issue | Severity | Fix |
|---|-------|----------|-----|
| 1 | Remove `phoenix_kit_shop_variants` from orphan query | CRITICAL | Delete 2 WHERE clauses |
| 2 | Fix default preload `:plan` -> `:subscription_type` | HIGH | 2 lines + 2 doc lines |
| 3 | Delete empty legacy files | LOW | Delete 2 files |
| 4 | Add prefix support to orphan SQL | MEDIUM | Refactor needed |
