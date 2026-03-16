# PR #420 — Fix mobile overflow issues in email module UI

**Author:** Tim (timujinne)
**Branch:** dev -> dev
**Status:** Merged (2026-03-16)
**Changes:** +73 / -31 across 9 files

## What

Fixes horizontal overflow / clipping issues on mobile screens across 6 email module pages,
plus adds custom_fields support to user registration, entity DataView extension docs, and
a missing version comment in V83 migration.

## Why

On narrow viewports, flex rows without `flex-wrap` caused buttons and filter inputs to
overflow or get clipped. Stat cards in the email queue lacked `min-w-0`/`overflow-hidden`,
and the Send Test Email modal was oversized (`max-w-4xl`). Template editor also showed
validation errors before user interaction (missing `changeset.action` guard).

Separately: `registration_changeset/3` didn't cast `:custom_fields`, requiring a second
query to set them post-insert. Entity DataView lacked docs on how parent apps can override it.

## How

1. **CSS fixes** — Add `flex-wrap` to button/filter rows, `min-w-0`/`overflow-hidden`/`break-all`
   to stat cards, `w-full` to provider performance table, reduce modal max-width
2. **Validation fix** — Guard error display with `@changeset.action &&` so errors only appear
   after form submission
3. **custom_fields in registration** — Add `:custom_fields` to cast list in `registration_changeset/3`
4. **Entity DataView docs** — README section + code comment on route override pattern
5. **V83 version comment** — Add missing `COMMENT ON TABLE` to track migration version

## Commits (3 authored, 2 merges)

| SHA | Summary |
|-----|---------|
| 1288ff3 | Add custom_fields support to register_user and entity data view docs |
| c736911 | Fix dialyzer guard_fail warnings from upstream publishing changes |
| c37d89c | Fix mobile overflow issues in email module UI |
