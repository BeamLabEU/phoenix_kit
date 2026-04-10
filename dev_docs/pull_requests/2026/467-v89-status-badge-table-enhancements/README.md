# PR #467: Add V89 migration, status_badge component, and table_row_menu inline mode

**Author**: @mdon (Max Don)
**Status**: Merged
**Branch**: `mdon/dev` -> `dev`
**Date**: 2026-03-31

## Goal

Core additions to support the `phoenix_kit_catalogue` module release. Includes a pricing migration, new generic badge component, table component enhancements, and JS view-sync improvements.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit/migrations/postgres.ex` | Bump `@current_version` to 89, add V88/V89 changelog entries |
| `lib/phoenix_kit/migrations/postgres/v89.ex` | New migration: rename `price` -> `base_price`, add `markup_percentage` |
| `lib/phoenix_kit_web/components/core/badge.ex` | New `status_badge/1` component |
| `lib/phoenix_kit_web/components/core/table_default.ex` | Add `wrapper_class` and `show_toggle` attrs |
| `lib/phoenix_kit_web/components/core/table_row_menu.ex` | Add `mode` attr with `"dropdown"`, `"inline"`, `"auto"` values |
| `priv/static/assets/phoenix_kit.js` | TableCardView cross-instance sync via custom events, `destroyed()` cleanup |

### Schema Changes

```sql
-- V89: phoenix_kit_cat_items
ALTER TABLE phoenix_kit_cat_items RENAME COLUMN price TO base_price;

-- V89: phoenix_kit_cat_catalogues
ADD COLUMN markup_percentage DECIMAL(7, 2) NOT NULL DEFAULT 0;
```

### Component API Changes

| Component | Change |
|-----------|--------|
| `status_badge/1` | New — generic status-to-color badge |
| `table_default/1` | New attrs: `wrapper_class` (override wrapper div classes), `show_toggle` (hide toggle button) |
| `table_row_menu/1` | New attr: `mode` (`"dropdown"` / `"inline"` / `"auto"`) |

## Implementation Details

- **V89 migration** follows existing idempotent pattern with `IF EXISTS` guards and schema-aware prefix handling
- **status_badge** maps 9 common status strings to daisyUI badge colors via pattern-matched private functions
- **table_row_menu auto mode** renders both inline (md+) and dropdown (mobile) markup simultaneously, using Tailwind responsive classes for visibility
- **TableCardView sync** uses `CustomEvent` dispatch/listen pattern with `storage_key` matching, includes proper `destroyed()` cleanup

## Related

- Migration: `lib/phoenix_kit/migrations/postgres/v89.ex`
- Depends on: V87 catalogue tables (created the tables being modified)
- Consumer: `phoenix_kit_catalogue` module
