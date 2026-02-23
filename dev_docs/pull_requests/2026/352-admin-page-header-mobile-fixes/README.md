# PR #352 - Add unified admin_page_header component

**Author:** Tim (timujinne)
**Branch:** dev → dev
**Status:** Merged (2026-02-23)
**Files changed:** 97 | +1,436 / -1,846

## What

A multi-part PR that introduces a unified `admin_page_header` component, fixes mobile responsiveness across the admin panel, and extracts shared publishing components into `lib/modules/shared/`.

## Why

- **7+ different header patterns** existed across 89+ admin templates — inconsistent styling, missing back buttons, and duplicated markup
- **DaisyUI 5** applies `white-space: nowrap` to labels, breaking mobile layouts
- **Badge components** had fixed heights that truncated wrapped text on mobile
- **Publishing components** (Image, Video, CTA, etc.) were locked inside the Publishing module but needed by Pages too

## How

### 1. Unified `admin_page_header` Component
- New component at `lib/phoenix_kit_web/components/core/admin_page_header.ex`
- Supports `back` (navigate), `back_click` (phx-click), `title`, `subtitle` attrs
- Supports `:inner_block` (rich content) and `:actions` (right-side buttons) slots
- Responsive: `flex-col` on mobile → `sm:flex-row` on desktop
- Imported via `core_components()` macro — auto-available in all LiveViews

### 2. Template Migration (89 files)
- External `.heex` templates: fully migrated to `<.admin_page_header>`
- Shop `.ex` embedded templates: back buttons normalized (`btn-ghost` + icon-only) but NOT migrated to the component (pragmatic — deferred)
- Fixed 4 double-icon bugs (pages/settings, pages/view, tickets/edit, tickets/details)
- Added missing back buttons to users/media, settings/seo, connections

### 3. Mobile Responsiveness CSS
- `app.css`: 267 lines of mobile fixes (labels, forms, buttons, grids, alerts, modals)
- `phoenix_kit_daisyui5.css`: 110 lines of foundation fixes
- Badge component: `h-auto` added to all size classes for text wrapping

### 4. Shared Components Extraction
- New `lib/modules/shared/components/` directory with 8 components
- Publishing module components now delegate to shared versions
- PageBuilder renderers (both Pages and Publishing) reference Shared directly
- Backward-compatible delegation wrappers kept in Publishing namespace

### 5. Back Button Standardization
- Old: `btn btn-outline btn-primary btn-sm` with "Back to X" text + icon
- New: `btn btn-ghost btn-sm` with icon only (consistent, less visual noise)

## Commits

1. `dd62994` - Fix badge component height on mobile devices
2. `0329623` - Fix mobile responsiveness across admin panel (CSS)
3. `211394a` - Add unified admin_page_header component, replace all admin headers
4. `a2c4a90` - Fix formatting in admin_page_header templates
5. `438fe27` - Merge upstream/dev (Publishing DB storage, Pages restructuring)

## Post-Merge Fixes

6. `40d012f` - Fix CSS specificity debt and DateTime convention (review follow-up)
   - Removed ~150 lines of duplicate/dangerous CSS overrides across `app.css` and `phoenix_kit_daisyui5.css`
   - Removed global `opacity-50` and `ml-4`/`ml-8` utility redefinitions
   - Consolidated DaisyUI label overrides into single source of truth (`phoenix_kit_daisyui5.css`)
   - Fixed `DateTime.utc_now()` → `UtilsDate.utc_now()` in `shared/components/entity_form.ex`
