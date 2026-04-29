## PR #507 — V105 CRM tables migration + MediaBrowser PDF fix
**Author:** Tymofii Shapovalov (timujinne)
**Reviewer:** Claude
**Date:** 2026-04-29
**Verdict:** ✅ APPROVE — already merged; one low-risk in-tree fix landed alongside this review, two follow-ups suggested.

---

## Summary

Bundles two unrelated changes:

1. **V105 migration** introduces two tables for the upcoming `phoenix_kit_crm` plugin: `phoenix_kit_crm_role_settings` (per-role opt-in flag) and `phoenix_kit_crm_user_role_view` (per-user, per-scope view preferences). `@current_version` bumps `104 → 105` and the moduledoc is reordered so V105 carries the ⚡ LATEST marker.
2. **MediaBrowser PDF fix** — `determine_file_type/1` in `media_browser.ex` was returning `"pdf"` for `application/pdf`, which was rejected by the `File` changeset's `validate_inclusion(:file_type, …)` allowlist, silently breaking every PDF upload. Now returns `"document"`.

## Files Changed (3)

| File | Change |
|------|--------|
| `lib/phoenix_kit/migrations/postgres.ex` | +13 / −3 — moduledoc + `@current_version` bump |
| `lib/phoenix_kit/migrations/postgres/v105.ex` | +87 — new migration |
| `lib/phoenix_kit_web/components/media_browser.ex` | +4 / −1 — `application/pdf` → `"document"` |

## Green flags

- **Migration is idempotent and reversible.** `CREATE TABLE/INDEX IF NOT EXISTS`, FK cascades, `down/1` cleanly resets the version comment to `'104'` so rollback lands on V104 notifications. Matches the V100–V104 style.
- **UUIDv7 PK on the user-scoped table.** `uuid_generate_v7()` per project convention. Role-settings table uses `role_uuid` itself as PK — a defensible choice since it's a 1:1 extension of the role row, but see the finding below.
- **Right scope for the FK cascades.** Deleting a role takes its CRM opt-in row with it; deleting a user takes their view preferences. No orphan-cleanup code needed downstream.
- **Tight unique constraint on `(user_uuid, scope)`.** Prevents duplicate view rows per user/scope pair, which is what the upsert path will rely on.
- **PDF fix has the right shape.** It's the same mapping `Storage.determine_file_type/1` (in `storage.ex:2984`) already applies, so MediaBrowser uploads now classify PDFs the same as form-based uploads. Bonus: the change includes a WHY comment pointing at the allowlist — that's exactly the kind of comment the project guidelines ask for.

## Findings

### IMPROVEMENT - HIGH — Index name deviates from project convention

File: `lib/phoenix_kit/migrations/postgres/v105.ex:65`

```elixir
CREATE INDEX IF NOT EXISTS idx_crm_user_role_view_user
ON #{p}phoenix_kit_crm_user_role_view (user_uuid)
```

Every other index in V100–V104 follows `phoenix_kit_<table>_<columns>_index`:

```
phoenix_kit_notifications_recipient_inbox_index
phoenix_kit_notifications_activity_recipient_index
phoenix_kit_staff_teams_department_index
phoenix_kit_cat_categories_parent_index
…
```

V105 introduces a new `idx_*` prefix that doesn't appear anywhere else in the migration history. This makes index discovery (`\di` in psql, log lines, EXPLAIN output) inconsistent and forces grep'ers to know two conventions.

**Suggestion:** rename to `phoenix_kit_crm_user_role_view_user_index`. Also worth giving the unique constraint the same shape — it's currently `phoenix_kit_crm_user_role_view_user_scope_uniq`, which is fine, but `…_user_scope_index` would line up better with the rest of the codebase.

This is already merged, so the rename has to ship as a follow-up V106 (or be amended into V105 before any external consumer applies V105 — that depends on whether V105 has been published in a Hex release yet).

### IMPROVEMENT - MEDIUM — Two `determine_file_type/1` implementations are still drifting

The PR fixes the symptom (PDFs land as `"document"` now), but the root cause — that `media_browser.ex` carries its own MIME-classification cond next to the canonical one in `storage.ex:2970` — is unfixed. The two now agree on `application/pdf`, but they still disagree on:

| MIME | `Storage.determine_file_type/1` | `MediaBrowser.determine_file_type/1` |
|---|---|---|
| `audio/*` | `"audio"` | `"document"` (fallback) |
| `text/*` | `"document"` | `"document"` (fallback — happens to agree) |
| `application/msword`, `…wordprocessingml.document` | `"document"` | `"document"` (fallback — agrees) |
| `application/zip`, `…/x-tar`, etc. | `"archive"` | `"document"` (fallback — disagrees) |
| anything else | `"other"` | `"document"` |

So MediaBrowser audio uploads still classify as `"document"`, and archives still classify as `"document"`. The `File` changeset accepts both, so nothing crashes, but the UI badges and the `audio?/1` / `archive?/1` predicates in `lib/modules/storage/schemas/file.ex` will be wrong for these.

**Suggestion:** delete the local `determine_file_type/1` in `media_browser.ex` and call `PhoenixKit.Storage.determine_file_type/1` (promote it from `defp` to `def`, or expose a thin wrapper). One canonical classifier; one place to update when a new MIME class shows up.

### NITPICK — In-code comment understates the allowlist

File: `lib/phoenix_kit_web/components/media_browser.ex:1721`

```elixir
# PDFs fall under "document" because the File schema's allowlist is
# ["image", "video", "document", "archive"] — returning "pdf" here made
# every PDF upload fail the changeset validation silently.
```

The actual allowlist (`file.ex:209`) is `["image", "video", "audio", "document", "archive", "other"]`. The comment is load-bearing — it's the WHY for this branch — so getting it right matters. **Fixed in-tree during this review** at `media_browser.ex:1721-1723`; not yet committed.

### NITPICK — `down/1` style differs from V104

V104's `down/1` explicitly drops indexes before the table. V105's `down/1` relies on `DROP TABLE … CASCADE` to take the index along. Both work — `DROP TABLE` always drops dependent indexes, `CASCADE` only matters for FK dependents — but the inconsistency forces a reader to verify the equivalence. Cheap to align: drop the index explicitly, then drop tables without `CASCADE`. Not blocking.

### NITPICK — PR description has the same allowlist typo as the comment

The PR body says: `"the File changeset validates file_type against ["image", "video", "document", "archive", "other"]"`. Same omission of `"audio"`. Worth noting because the description is what future archaeologists read first.

## Suggested follow-ups

1. **Open a small follow-up PR** that (a) calls `Storage.determine_file_type/1` from `media_browser.ex` instead of duplicating the cond, and (b) optionally renames the V105 index to match convention (V106 migration that drops + recreates if V105 has already been released, or amend V105 if not).
2. **Manual audio upload smoke-test** through MediaBrowser to confirm the "audio classified as document" case is real — if it is, the unification in (1) ships the fix for free.

## Files in this review folder

- `CLAUDE_REVIEW.md` — this review
