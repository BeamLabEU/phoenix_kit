# PR #339 — Fix Remaining Review Issues from PR #335 and PR #338

**Author:** timujinne
**Date:** 2026-02-15
**Base:** dev
**Status:** Merged

---

## What

Follow-up PR addressing the 7 remaining issues identified across Claude, Mistral, and Kimi reviews of PRs #335 and #338.

## Why

The previous PR (#338) fixed 5 of 10 issues from the #335 review. This PR tackles the remaining 5 open items plus 2 issues found during cross-review.

## Changes

### Security
- Added `Scope.admin?` authorization checks to single-record handlers (`archive_data`, `restore_data`, `toggle_status`) in Data Navigator

### Bug Fixes
- Replaced simple self-parent check with recursive circular reference validation in category changeset
- Added active-only filter to featured product dropdown query
- Added ancestor cycle prevention in `bulk_update_category_parent`

### Performance
- Split `load_categories` into `load_static_category_data` + `load_filtered_categories` to avoid reloading static data on every filter/search/page change

### Code Quality
- Moved `require Logger` to module level in `shop.ex`
- Removed unused `noop` event handler and `phx-click="noop"` attributes from categories template

### Repo Hygiene
- Removed 11 unused MIM demo images (8.2 MB)

## Files Changed

| File | +/- | Description |
|------|-----|-------------|
| `lib/modules/entities/web/data_navigator.ex` | +57/-45 | Auth checks on single-record handlers |
| `lib/modules/shop/schemas/category.ex` | +25/-10 | Recursive circular ref validation |
| `lib/modules/shop/shop.ex` | +25/-3 | Ancestor cycle prevention, active filter, Logger fix |
| `lib/modules/shop/web/categories.ex` | +32/-40 | Split load fn, remove noop handler |
| `priv/static/images/mim/**` | -11 files | Remove unused demo images |
