# PR #999 — Codex review

**Reviewer:** Codex · **Date:** 2026-10-30 · **Baseline:** `716bce14e` on `main`

[PR #999](https://github.com/BeamLabEU/phoenix_kit/pull/999) — Add a removal guard and server-side confirmation to the media browser (`timujinne`). Reviewed the merged diff and current surrounding code, including subsequent merges.

Reviewed host callback contracts, timeout/crash handling, place sanitization, library/viewer/own-file gates and replay, removal-plan agreement with trash/unlink/rehome/delete behavior, skip-held-file handling and the modal's client hooks.

## BUG - MEDIUM: a changed folder selection reused an earlier confirmation (fixed)

The dialog stored file UUIDs but only a folder count. For a bulk removal, changing the selection from one empty folder to another left the file sets and count identical, so confirming the first dialog removed the newly selected folder.

The removal analysis and pending dialog now store folder UUIDs, and confirmation compares those identities along with the disappearing file sets. A regression switches the selected empty folder after opening the dialog, verifies neither is removed on the stale confirmation, then confirms the refreshed dialog.

The documented attach-between-check-and-delete window remains: the host needs a database reference constraint where that race matters. Background pruning and deletion outside the browser remain outside this callback contract.

## Validation

See the [batch validation record](../2026-10-30-recent-merges/CODEX_REVIEW.md). This PR is reviewed individually; validation is shared across the interacting changes.
