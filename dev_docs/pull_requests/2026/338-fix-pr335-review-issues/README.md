# PR #338 — Fix PR #335 Review Issues

**Author:** timujeen
**Date:** 2026-02-14
**Status:** Merged
**Base Branch:** dev

---

## What

Follow-up PR addressing issues identified in the PR #335 AI review. Fixes authorization gaps, N+1 query, category dropdown UX bug, admin edit URL, and silent error swallowing.

## Why

PR #335 was approved with observations — several medium and low severity issues were flagged across the entity data navigator, shop catalog, and shop context. This PR resolves the highest-priority items.

## How

- **Authorization:** Added `Scope.admin?()` checks to all 5 entity data navigator bulk action handlers (archive, restore, delete, change_category, change_status)
- **N+1 elimination:** Rewrote `bulk_update_category/2` from N individual `repo().update()` calls to a single PostgreSQL `jsonb_set` query via `update_all`
- **Category dropdown fix:** Extracted `available_categories` before the category filter in `apply_filters/1` so the dropdown always shows all options
- **Admin edit URL:** Fixed legacy `mount_with_product` to use `product.uuid` instead of `product.id`, added missing `/edit` suffix
- **Error logging:** Replaced bare `rescue _ -> %{}` with `Logger.warning` in `product_counts_by_category`

## Files Changed (4)

| File | Change |
|------|--------|
| `lib/modules/entities/entity_data.ex` | Rewrite `bulk_update_category` to single `jsonb_set` query |
| `lib/modules/entities/web/data_navigator.ex` | Add `Scope.admin?` to bulk actions, fix category extraction order |
| `lib/modules/shop/shop.ex` | Add `Logger.warning` to `product_counts_by_category` rescue |
| `lib/modules/shop/web/catalog_product.ex` | Fix admin edit URL: `product.id` to `product.uuid`, add `/edit` |
