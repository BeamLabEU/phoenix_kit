# PR #425 — Publishing Module Improvements and Bug Fixes

**Author:** Max Don (@mdon)
**Branch:** `dev` → `dev` (merged)
**Date:** 2026-03-17
**Files changed:** 27 (+1335 / -621)

## Summary

Comprehensive batch of publishing module improvements spanning SEO, language handling, editor UX, and several bug fixes. The PR touches the full stack: controller (OG meta tags), LiveView editor (title-driven slug generation), public templates (live navigation), PubSub (broadcast ID consistency), email templates (i18n wrapping), and flash component (warning kind).

## Key Changes

### SEO & Meta Tags
- Open Graph and Twitter Card meta tags for all public publishing pages (posts, versioned posts, date-only URLs, group listings)
- Canonical URL via `<link rel="canonical">` derived from `@og` assign
- Uses `conn.scheme/host/port` for base URL to avoid compile-time endpoint dependency

### Language Handling
- `resolve_language_key/2` helper for base code → dialect code matching (e.g., `"en"` → `"en-US"`)
- Language switcher selection opacity increased from 10% to 30% for dark theme visibility
- Translation reload now passes `current_language` to `re_read_post/2` to avoid falling back to primary language

### Editor UX Overhaul
- **Title-driven slug generation** replaces content-based auto-extraction from H1 headings
- Removed: `maybe_update_title_from_content`, `preserve_auto_title`, `detect_title_manual_set`, `revert_title_to_auto`, and all `title_manually_set`/`last_auto_title` assigns
- Added: `maybe_update_slug_from_title/3`, real-time slug generation as user types title
- Slug manual-set detection now uses `_target` to avoid stale browser values overwriting server state
- Title and slug required to save; autosave silently skips if empty
- Preview button hidden on new post page (UUID is nil)
- Save indicator moved above title, Content heading removed
- Warning flash kind for language switch hint on unsaved new posts

### PubSub Fix
- `PubSub.broadcast_id/1` as single source of truth for post identifier (slug || uuid)
- Fixes timestamp-mode posts never receiving translation/version events

### Preview Overhaul
- Full public interface in preview: breadcrumbs, publication date, language switcher, version dropdown
- Language links navigate within preview instead of going to public site

### Other Fixes
- Email template seeding: wrap string fields in `%{"en" => value}` maps for multilingual schema
- Whitespace fix in slug format examples
- Startup warning when PhoenixKit is not installed
- Live navigation (`<.link navigate>`) on all public templates

## New Tests
- `editor_forms_test.exs` — 250 lines, unit tests for slug generation from title
- `slug_update_test.exs` — Integration tests for slug creation/update flows
- `translation_reload_test.exs` — Integration tests for language-specific content retrieval
- `pubsub_broadcast_id_test.exs` — Unit tests for broadcast_id and topic consistency
