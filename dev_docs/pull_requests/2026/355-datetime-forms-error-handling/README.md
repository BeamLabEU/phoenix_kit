# PR #355 — DateTime Standardization + Form Error Handling + Bug Fixes

**Author:** Alex (@alexdont)
**Merged:** 2026-02-22
**Base:** `dev`
**Files changed:** 64 (+603/-333)

## What

Three independent improvements bundled into one PR:

1. **Fix CommentsComponent crash** — `changed?(assigns, ...)` → `changed?(socket, ...)` in LiveComponent `update/2` callback (1 file)
2. **Complete DateTime standardization** — Replace all remaining bare `DateTime.utc_now()` and manual `DateTime.truncate(DateTime.utc_now(), :second)` with `UtilsDate.utc_now()` across 47 files in all DB write contexts
3. **Add form error handling** — Wrap `handle_event("save", ...)` handlers with try/rescue in 15 form files to prevent silent data loss on unexpected exceptions
4. **Fix media selector upload** — Fix pattern match on `consume_uploaded_entry` return value so drag-and-drop uploads display correctly (1 file)

## Why

- **CommentsComponent:** `Phoenix.Component.changed?/2` requires a socket with `__changed__` metadata, not a plain assigns map — was crashing on post detail pages
- **DateTime:** After PR #347 changed all schemas to `:utc_datetime`, bare `DateTime.utc_now()` (which has microsecond precision) causes `ArgumentError` crashes at all DB write sites. This completes the remaining ~55 sites left after PRs #347, #350, and the Entities fix.
- **Form error handling:** When a `handle_event("save")` encounters an unexpected exception (like the DateTime microsecond bug), the LiveView process crashes and Phoenix replaces it with a fresh one — silently losing all user form data with no error message shown.
- **Media selector:** `consume_uploaded_entry/3` returns the unwrapped callback result (a string), not `[{:ok, string}]`. The old pattern never matched, causing all drag-and-drop uploads to hit the error branch.

## How

- **DateTime:** Each file gets `alias PhoenixKit.Utils.Date, as: UtilsDate`, then all `DateTime.utc_now()` / `DateTime.truncate(DateTime.utc_now(), :second)` calls in changeset/update_all/insert_all contexts are replaced with `UtilsDate.utc_now()`
- **Forms:** Each save handler wraps its DB operation in `try/rescue`, with the rescue logging the error and showing a flash message to the user

## Tracks

- `dev_docs/2026-02-17-datetime-standardization-plan.md` — Step 5 now **100% COMPLETE**
- `dev_docs/2026-02-21-liveview-form-error-handling.md` — All handlers covered and correctly placed

## Review

See `CLAUDE_REVIEW.md` for the deep dive review. Post-review fixes resolved all findings:
- 4 misplaced try/rescue blocks → converted to function-level `rescue`
- 1 missed DateTime site (`event.ex` parse_timestamp) → fixed
- gettext consistency in the 4 fixed files → updated
