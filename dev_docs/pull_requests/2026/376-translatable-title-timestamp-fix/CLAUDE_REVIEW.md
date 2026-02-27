# PR #376 Review — Add translatable title field and fix timestamp-mode post handling

**Reviewer:** Claude
**Date:** 2026-02-27
**Verdict:** Approved — all issues fixed in follow-up commit

---

## Issues Found & Fixed

### Critical

#### 1. `trash_post`, `delete_language`, `delete_version` used slug-only lookup

**Severity: BUG — would crash for timestamp-mode posts**

These three public functions called `DBStorage.get_post(group_slug, post_identifier)` instead of `resolve_db_post/2`. Timestamp-mode posts with `slug: nil` would hit `:not_found` on trash, delete language, or delete version.

**Fix applied:** Switched all three to `resolve_db_post/2`. Updated `trash_post` broadcast to use `db_post.slug || db_post.uuid` (matching `publish_version` and `create_version_in_db` pattern).

#### 2. Migration V68 `down/1` created index before backfilling NULLs

**Severity: BUG — rollback would fail if any NULL slugs existed**

The `down/1` function created the unconditional unique index on `(group_uuid, slug)` before backfilling NULL slugs with placeholder values — the index creation would fail on NULL rows.

**Fix applied:** Reordered to backfill NULLs first, then create the index.

### Important

#### 3. Status dropdown completely hidden for non-primary language editors

Previously, non-primary language editors could see the status (disabled dropdown with "follows primary language"). The PR hid status and publication date entirely for translations, leaving editors with no visibility into current post status.

**Fix applied:** Status now shown as a read-only disabled input with "(follows primary language)" label. Publication date remains primary-language only.

#### 4. `uuid_format?/1` had redundant guards

`byte_size(str) >= 32` and `String.contains?(str, "-")` are redundant since `UUIDv7.cast/1` already rejects non-UUID strings.

**Fix applied:** Simplified to `match?({:ok, _}, UUIDv7.cast(str))`.

#### 5. `parse_timestamp_path` called twice in `read_back_post/5`

Called once in a `cond` guard via `match?` and again in the body. Also triggered a credo `--strict` warning (cond with only one condition besides `true`).

**Fix applied:** Refactored to `if/else` with a single `case` call, eliminating both the double call and the credo warning.

### Minor / Style

#### 6. Abbreviated variable names in `reload_post_on_lock_acquired/1`

`ext_title` and `a_title` were inconsistent with the same pattern in `editor.ex:511-512` which uses `extracted_title` and `auto_title`.

**Fix applied:** Renamed to `extracted_title` and `auto_title`.

#### 7. `detect_title_manual_set/3` lived in `editor.ex` while slug equivalent is in `forms.ex`

The title manual-set detection logic was defined as private functions in `editor.ex`, while the equivalent slug tracking logic is in `forms.ex`.

**Fix applied:** Moved `detect_title_manual_set/3` and `revert_title_to_auto/2` to `forms.ex` as public functions.

#### 8. Docstring said `Returns {socket, form}` but returned `{socket, form, events}`

`maybe_update_title_from_content/2` doc was missing the events element.

**Fix applied:** Updated to `Returns {socket, form, events}`.

---

## What's Good

- **Title auto-generation pattern** is well-designed — mirrors the established slug auto-generation, reusing the same `push_event` + JS listener + `preserve_auto_*` pattern. Easy to understand if you know the slug code.
- **`find_db_post_for_update/2`** with the UUID > date/time > slug fallback chain is robust and correctly prioritizes the most stable identifier.
- **Schema validation split** (`maybe_require_slug` + `maybe_require_timestamp_fields`) is clean — enforces the right constraints per mode.
- **V68 migration** is well-structured: idempotent operations, partial indexes are the right approach, and the timestamp unique index properly guards against duplicate posts.
- **Status propagation fix** (reading `old_db_status` from DB instead of socket assigns) fixes a real race condition.
- **Test coverage** for the conditional schema validation is appropriate.

---

## Pre-Go-Live Checklist

- [x] **Fix #1**: Update `trash_post`, `delete_language`, `delete_version` to use `resolve_db_post`
- [x] **Fix #2**: Swap migration `down/1` steps — backfill NULLs before creating unconditional unique index
- [x] **Fix #3**: Show read-only status indicator for non-primary language editors
- [x] **Fix #4**: Simplify `uuid_format?/1`
- [x] **Fix #5**: Eliminate double `parse_timestamp_path` call, fix credo warning
- [x] **Fix #6**: Rename abbreviated variables
- [x] **Fix #7**: Move title detection functions to `forms.ex`
- [x] **Fix #8**: Fix docstring return type
- [ ] Run migration V68 on staging and verify both `up` and `down` paths
- [ ] Test timestamp-mode: create, edit, publish, trash, delete language, delete version
- [ ] Test slug-mode: verify no regression in title auto-population and manual override
