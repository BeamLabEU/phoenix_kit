# PR #335 — Add admin edit buttons and improve shop catalog UX

**Author:** timujinne (Tymofii Shapovalov)
**Merged:** 2026-02-14
**Base:** dev
**Files changed:** 30 (1,319 additions, 184 deletions)

## What

This PR adds four distinct capabilities:

1. **Admin edit buttons on catalog frontend** — Admin users see "Edit Product" / "Edit Category" buttons in the user dropdown menu when viewing shop catalog pages, enabling quick jumps to admin editing without navigating through the admin sidebar.

2. **Category management overhaul** — The admin categories list page (`categories.ex`) was rewritten from a simple list to a full-featured management page with search, filtering (by status, parent), pagination, bulk operations (change status, change parent, delete), selection checkboxes, and product count display.

3. **Entity data navigator enhancements** — Category filtering added to the data navigator, plus bulk operations (archive, restore, delete, change status, change category) with multi-select checkboxes.

4. **Email template route fix** — Renamed `/admin/modules/emails/templates` to `/admin/emails/templates` to match the convention used by all other email routes.

## Why

- Admin users needed a fast path from frontend catalog browsing to admin editing without context-switching through the admin panel navigation.
- Category management lacked basic management tools (search, filter, pagination, bulk ops) that were already present in other admin modules.
- Email template routes were inconsistent with the rest of the email module's URL scheme (`/admin/emails/*`).

## How

### Admin Edit Buttons
- Added `admin_edit_url` and `admin_edit_label` assigns to `CatalogProduct` and `CatalogCategory` LiveViews
- Extended `UserDashboardNav.user_dropdown/1` component with new `admin_edit_url` and `admin_edit_label` attrs
- Dashboard layout passes these assigns through to the user dropdown

### Category Management
- Rewrote `Categories` LiveView with pagination (`@per_page = 25`), search, status/parent filters
- Added `MapSet`-based multi-select with bulk actions via modal dialogs
- New context functions in `Shop`: `bulk_update_category_status/2`, `bulk_update_category_parent/2`, `bulk_delete_categories/1`, `product_counts_by_category/0`
- New PubSub events in `Events`: `broadcast_categories_bulk_*`
- Bulk delete properly nullifies category references on orphaned products

### Entity Data Navigator
- Added category filter dimension alongside existing status filter
- Added `selected_ids` state and bulk action handlers
- Refactored `apply_filters/1` — extracted `filter_by_entity/2`, `filter_by_status/2`, `filter_by_category/2`, `filter_by_search/2` private functions (Credo complexity 16 -> 4)
- New `EntityData` functions: `bulk_update_status/2`, `bulk_update_category/2`, `bulk_delete/1`, `extract_unique_categories/1`

### Email Route Fix
- Updated 8 files: routes, navigation links, documentation comments, and internal references
- Changed from `/admin/modules/emails/templates` to `/admin/emails/templates`

### SQL/Query Fixes
- Fixed raw SQL `metadata` fragment to use explicit binding (`p.metadata`) instead of implicit table reference
- Fixed UUID parameter passing for category filter — now uses `Ecto.UUID.dump/1` for binary encoding
- Removed `p.status == "active"` filter from `category_product_options_query` to show all products with images

## Commits

1. `ea7a239` — Fix inconsistent email templates route path
2. `5bf5d8f` — Add admin edit buttons in shop catalog pages
3. `53ff8fa` — Merge upstream/dev: Add registry-driven admin navigation system

## Related PRs

- Depends on: [#334](/dev_docs/pull_requests/2026/334-admin-navigation-registry) (registry-driven admin navigation)
