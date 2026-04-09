# PR #479 Review — Add V94 migration for Document Creator sync, fix Google token refresh

**Reviewer:** Pincer 🦀
**Date:** 2026-04-07
**Verdict:** Approve

---

## Summary

Two targeted fixes:
1. **Google token refresh for named connections** — `refresh_access_token/1` now correctly resolves provider key when using named connections (e.g. `google:work`). Previously failed because it passed the full storage key to provider lookup.
2. **V94 migration** — Adds `google_doc_id`, `status`, `path`, `folder_id` columns to document creator tables with idempotent checks and partial unique indexes.

3 files, 290 lines.

---

## What Works Well

1. **Focused fix** — `resolve_provider_lookup_key/2` and `resolve_storage_key/2` helpers cleanly separate storage keys from provider keys.
2. **Idempotent migration** — V94 checks for existing columns before adding, safe to re-run.
3. **Partial unique indexes** — `WHERE google_doc_id IS NOT NULL` avoids index bloat from NULL values.
4. **Proper up/down** — down migration reverses all changes.

---

## Issues and Observations

No issues found. Small, focused, well-tested fix.

---

## Post-Review Status

No blockers. Ready for release.
