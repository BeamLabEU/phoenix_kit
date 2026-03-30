# PR #462: Update module refs to extracted package namespaces

**Author**: @timujinne
**Branch**: `legal-cookie-consent-fix` -> `dev`
**Status**: Merged
**Date**: 2026-03-30

## Goal

Update PhoenixKit core references to use the new top-level namespaces of extracted packages:
- `PhoenixKit.Modules.Shop.*` -> `PhoenixKitEcommerce.*`
- `PhoenixKit.Modules.Billing.*` -> `PhoenixKitBilling.*`

Additionally, restore `LayoutWrapper.app_layout` wrapping in core module templates that had it removed during the extraction wave.

## What Was Changed

### Namespace Migration

| File | Change |
|------|--------|
| `lib/phoenix_kit_web/integration.ex` | 28 Shop refs -> PhoenixKitEcommerce (routes, plugs, LiveViews) |
| `lib/phoenix_kit/users/auth.ex` | Shop.Cart -> PhoenixKitEcommerce.Cart, Billing -> PhoenixKitBilling |
| `lib/phoenix_kit_web/users/auth.ex` | Shop -> PhoenixKitEcommerce (guest cart merge) |
| `lib/phoenix_kit/utils/country_data.ex` | Billing.IbanData -> PhoenixKitBilling.IbanData |
| `lib/modules/sitemap/sources/shop.ex` | `alias PhoenixKitEcommerce, as: Shop` (preserves local usage) |
| `lib/modules/sitemap/sources/router_discovery.ex` | Module prefix check -> PhoenixKitEcommerce |
| `lib/modules/sitemap/web/settings.ex` | Module enabled check -> PhoenixKitEcommerce |

### LayoutWrapper Restoration (16 templates)

Core modules (customer_service, db, maintenance, referrals, sitemap, storage) had `LayoutWrapper.app_layout` restored. These are bundled in `:phoenix_kit` and don't benefit from auto-layout, which only applies to extracted external packages.

**Affected templates:**
- `lib/modules/customer_service/web/` — details, edit, list, settings
- `lib/modules/db/web/` — activity, index, show
- `lib/modules/maintenance/` — settings.ex, settings.html.heex
- `lib/modules/referrals/web/` — form, list, settings
- `lib/modules/sitemap/web/` — settings
- `lib/modules/storage/web/` — bucket_form, dimension_form, dimensions, settings

### Upstream Sync

Merge commits from `upstream/dev` included in branch (Pages removal, auto-recompile, deps upgrade).

## Implementation Details

- All `@compile {:no_warn_undefined, ...}` directives updated to match new namespaces
- `Code.ensure_loaded?/1` guards updated consistently across integration.ex and auth modules
- Sitemap shop source uses `alias PhoenixKitEcommerce, as: Shop` to minimize internal churn
- LayoutWrapper templates pass `current_path` attribute (matching component attr definition)
