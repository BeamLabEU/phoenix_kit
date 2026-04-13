# PR #486 Review — Add V96 migration: catalogue_uuid on catalogue items

**Reviewer:** Pincer 🦀
**Date:** 2026-04-11
**Verdict:** Approve

---

## Summary

Adds a nullable `catalogue_uuid` FK to `phoenix_kit_cat_items` so items can belong to a catalogue independently of having a category. This supports the catalogue refactor in phoenix_kit_catalogue #7 where items belong directly to catalogues.

2 files changed: migration docs/version bump in `postgres.ex` + new `v96.ex`.

---

## What Works Well

1. **Clean idempotency** — Column existence check via `information_schema` before ALTER, `create_if_not_exists` on indexes. Safe to re-run.
2. **Thoughtful backfill strategy** — Three-step approach (column add → backfill from category → orphan pin) is well-ordered and handles edge cases.
3. **Orphan safety** — Filters out `status = 'deleted'` catalogues when pinning orphans, preventing items from disappearing via soft-delete cascades. If no valid catalogue exists, items stay NULL — correct behavior.
4. **Composite index justified** — `(catalogue_uuid, status)` index covers all four named per-catalogue query patterns. The single-column index on `catalogue_uuid` is still useful for queries that don't filter by status.
5. **Lossy rollback documented** — `@moduledoc` and `down/1` doc clearly warn that post-V96 uncategorized items lose their catalogue linkage on rollback.
6. **Consistent patterns** — Follows the same prefix handling, version comment, and structure as V94/V95.

---

## Issues and Observations

### Design (non-blocking)

1. **Orphan pinning is non-deterministic in multi-catalogue setups** — The `ORDER BY inserted_at ASC LIMIT 1` picks the oldest catalogue, which is reasonable for single-catalogue installs but arbitrary when multiple exist. This is acceptable as a one-time migration heuristic, but worth documenting as a known behavior. Items that were truly "global" before will now belong to one specific catalogue.

2. **FK uses `ON DELETE SET NULL` (hard delete)** — The moduledoc mentions "in-app cascades handle soft-delete lifecycle," which is correct. The DB-level `SET NULL` only fires on hard deletes. This is the right choice, just noting it's intentional.

3. **Redundant index consideration** — The composite index `(catalogue_uuid, status)` can serve queries that only filter on `catalogue_uuid` (PostgreSQL can use a B-tree prefix). The standalone `catalogue_uuid` index may be redundant. Not a blocker — extra index is just a small write overhead, and having both is explicit and safe.

### Style (trivial)

4. **Step 2 backfill is not wrapped in a transaction guard** — The UPDATE in step 2 could be large on a big table. In future migrations, consider batching (`LIMIT ... OFFSET` in a loop) for very large tables. For this migration it's fine since catalogue item counts are typically manageable.

---

## Post-Review Status

No blockers. Clean, focused migration ready for release pipeline.
