# PR #994 — Codex review

**Reviewer:** Codex · **Date:** 2026-10-30 · **Baseline:** `716bce14e` on `main`

[PR #994](https://github.com/BeamLabEU/phoenix_kit/pull/994) — Add a picker mode to the media browser (`timujinne`). Reviewed the merged diff and current surrounding code, including subsequent merges.

Reviewed initial/reset selection, click and quick-confirm paths, mode/count limits, scope/library/viewer/type checks, upload routing and resume state, upload-busy notifications, folder-action gates, and coexistence with a normal browser.

## BUG - MEDIUM: confirmation returned files outside the current picker boundary (fixed)

The picker checked its full boundary when adding a file, but Confirm only checked that stored UUIDs still named live files. A file moved outside the scoped subtree or into a hidden/user library after selection could therefore be returned to the host despite no longer being selectable.

Confirmation now applies the same library, viewer, type, system-file and folder/link checks as initial selection and clicks. The shared implementation loads files and folder/link scope in bulk, keeping query count bounded for a large selection while preserving selection order. Regressions move a selected file outside the scope and into a hidden library without a PubSub refresh, then assert that it is omitted.

The picker-viewer identity fix is recorded separately under #995.

## Validation

See the [batch validation record](../2026-10-30-recent-merges/CODEX_REVIEW.md). This PR is reviewed individually; validation is shared across the interacting changes.
