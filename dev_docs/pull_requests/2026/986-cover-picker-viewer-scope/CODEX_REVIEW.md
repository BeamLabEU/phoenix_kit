# PR #986 — Folder cover picker viewer scope

**Reviewer:** Codex · **Date:** 2026-10-29 · **Baseline:** `38a116bc4`

Reviewed listing scope and the `media_selected` update path with its tests. No additional defect found.

The picker receives the restricted viewer UUID, and the callback independently rejects another viewer's file, a trashed/system-managed file and a file outside the shown library. A linked image can remain outside the scope folder while belonging to the same library; the callback intentionally allows that case. A browser locked to video can still choose an image for its folder cover. The integration tests cover these distinctions.

## Validation

See the [batch validation record](../2026-10-29-recent-merges/CODEX_REVIEW.md).
