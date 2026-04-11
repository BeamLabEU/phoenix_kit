# Aggregated Review — PR #486: Add V96 migration: catalogue_uuid on catalogue items

**Date:** 2026-04-11
**Reviewers:** Pincer 🦀, Claude (Anthropic)
**Mistral:** Crashed (context detach error)
**Kimi:** Blocked (file write rejected)

---

## Verdict: ✅ Approve — No blockers

---

## High Confidence (all reviewers agree)

1. **Migration is correct, idempotent, and follows established patterns** — Column guard, `create_if_not_exists`, NULL-guarded backfills. No issues.
2. **FK semantics align with existing cascade chain** — `ON DELETE SET NULL` for hard deletes, soft-delete handled in-app.
3. **Lossy rollback clearly documented** — Honest warning about data loss on rollback.
4. **Version bump in `postgres.ex` is clean** — `@current_version 96` dispatches correctly.

---

## Medium Confidence (single reviewer)

| # | Severity | Finding | Source |
|---|----------|---------|--------|
| 1 | IMPROVEMENT | No dedicated test for backfill/orphan-pinning SQL logic — the riskiest part of the migration has no assertions | Claude |
| 2 | NITPICK | Single-column `(catalogue_uuid)` index likely redundant — composite `(catalogue_uuid, status)` covers it via B-tree prefix | Pincer, Claude |
| 3 | NITPICK | `schema` variable always equals `prefix` — dead conditional copied from V94 | Claude |
| 4 | NITPICK | `prefix_str("public")` returns `"public."` vs V95's `""` — inconsistent but harmless | Claude |
| 5 | DESIGN | Orphan pinning picks oldest catalogue — arbitrary in multi-catalogue setups, acceptable as one-time heuristic | Pincer |

---

## Recommendation

Merge-ready. The missing backfill test (#1) is worth adding before the next minor release but doesn't block this PR. The redundant index (#2) is minor — can be cleaned up later. Everything else is cosmetic.
