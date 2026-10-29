# PR #987 — Media event and bulk selection library boundaries

**Reviewer:** Codex · **Date:** 2026-10-29 · **Baseline:** `38a116bc4`

Reviewed the recursive UUID event gate, site-library exclusion, shown-selection queries and bulk move/delete/restore handlers. No additional boundary defect found.

A browser naming no library excludes user and hidden/trashed/suspended libraries rather than treating a missing library option as unrestricted. Bulk handlers reload selections and filter against both the shown library and the viewer. Checked the interaction with #991: its new `box_select` event still passes through the event gates and intersects supplied IDs with rendered cards; the old `folder_uuid` move payload is checked before being translated to the current key.

The pre-existing behavior on malformed UUIDs in direct selection events remains outside this change; this review does not claim that every malformed event is tolerated. Valid UUIDs naming foreign libraries are covered by integration tests.

## Validation

See the [batch validation record](../2026-10-29-recent-merges/CODEX_REVIEW.md).
