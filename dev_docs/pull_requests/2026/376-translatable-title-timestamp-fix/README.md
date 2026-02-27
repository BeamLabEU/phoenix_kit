# PR #376 — Add translatable title field and fix timestamp-mode post handling

**Author:** Max Don (mdon)
**Date:** 2026-02-27
**Status:** Merged into `dev`
**Files changed:** 11 (+593 / -154)

## What

Two intertwined features in one PR:

1. **Translatable title field** — Adds an explicit title `<input>` to the editor sidebar for all languages and all modes. Title auto-populates from the first H1 heading in the content, with manual override tracking (same pattern as slug auto-generation). Title is required for the primary language on publish.

2. **Timestamp-mode post fixes** — Fixes nil-slug crashes throughout the publishing pipeline by allowing `slug` to be NULL for timestamp-mode posts. Adds UUID-based and date/time-based fallback resolution everywhere slugs were previously assumed to exist.

## Why

- Title was previously extracted silently from markdown content with no way for users to see or override it per-language, making translation workflows incomplete.
- Timestamp-mode posts don't use slugs by design, but the code assumed `post.slug` was always present, causing crashes in `publish_version`, `create_version`, `set_primary_language`, `validate_url_slug`, and PubSub broadcasts.
- Status propagation to translations was reading from already-updated socket assigns instead of the DB, causing missed propagation.

## How

- New `title` field in `base_form/1`, `normalize_form/1`, `perform_save/1`
- Title auto-generation mirrors slug auto-generation: `maybe_update_title_from_content/2`, `preserve_auto_title/2`, `detect_title_manual_set/3`
- `push_event("update-title")` + JS listener for DOM sync
- `resolve_db_post/2` extended with UUID detection and nil guard
- New `find_db_post_for_update/2` with UUID > date/time > slug fallback chain
- `read_back_post/5` rewritten as `cond` to check db_post.mode before falling back to slug
- V68 migration: NULL slug, partial unique index, datetime unique index
- Schema validation split: `maybe_require_slug/1` + `maybe_require_timestamp_fields/1`
- Status/date controls hidden for non-primary languages (post-level, not per-translation)
