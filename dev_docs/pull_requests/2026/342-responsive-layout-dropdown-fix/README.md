# PR #342 - Fix responsive layout and replace dropdown menus

**Author:** @timujinne
**Branch:** `dev` -> `dev` (merged 2026-02-16)
**Changed:** 70 files | +734 / -668

## What

Comprehensive responsive layout overhaul across all 50+ admin pages, replacement of dropdown action menus with inline icon buttons, and several targeted bug fixes.

## Why

Admin pages used absolute positioning for back buttons and action buttons, which caused overlapping and broken layouts on mobile screens. Dropdown action menus in table rows added unnecessary interaction cost for common CRUD operations. Several small bugs (broken sidebar link, navbar overflow, missing cart product links) were also addressed.

## How

### 5 commits:

1. **MapSet refactor** - Convert `DataNavigator.selected_ids` from List to MapSet for O(1) lookups; fix Dialyzer opaque type warning in category cycle detection; remove noop event handlers
2. **Admin edit button + cart links** - Add `:admin_edit_url` / `:admin_edit_label` to dashboard layout keys; make cart product images/titles clickable
3. **Responsive headers** - Remove `absolute left-0 top-0 -mb-12` positioning from 62 templates; replace with flex layout; add responsive text sizing (`text-2xl sm:text-4xl`)
4. **Inline buttons** - Replace dropdown menus with `flex gap-1` inline icon buttons across billing, AI, and posts modules; fix email templates sidebar path; add CLAUDE.md code style rule
5. **Merge commit** - Resolve 7 conflicts merging upstream UUID migration + gettext i18n changes
