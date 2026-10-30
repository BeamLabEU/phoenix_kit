# PR #1001 — Codex review

**Reviewer:** Codex · **Date:** 2026-10-30 · **Baseline:** `716bce14e` on `main`

[PR #1001](https://github.com/BeamLabEU/phoenix_kit/pull/1001) — Add editable library access, safe backup storage and live progress (`ddon`). Reviewed the merged diff and current surrounding code, including subsequent merges.

Reviewed shared library preferences, audience and private-token transitions, file/tile serving and cache controls, own-storage creation and backup attachment, profile copy counts, credential probes and shared integration row locks, dependency-protected removal/disconnection, async form saves, and progress aggregation. Existing dependency and attachment concurrency tests are included in the full suite.

## BUG - HIGH: preference writes trusted stale account authority (fixed)

`Preferences.update/3` and the new rendition event authorized using the scope captured when the component opened. An owner whose publication permission was revoked could still publish; an administrator demoted while the page remained open could rename another person's library or change its rendition profile; a blocked owner could still save.

Added a fresh account/permission check before writes. The check reloads permissions only for still-held roles that were effective in the caller's scope, then intersects those rights with the original permission ceiling. Another held role cannot restore a permission revoked from the active role. Preferences, rendition changes and own-storage writes share this check; none reconstructs or copies an active-role field from a by-uuid user. Regressions cover revoked publication, demotion, blocked owners, legitimate publication, a restricted active role alongside a more privileged held role, and a permission revoked from the active role while another held role retains it.

Network probes remain outside the integration row lock, and prepared credentials/dependencies are rechecked under that lock. No additional change was needed to storage placement or credential rotation. Real object-storage services were not contacted by these tests; their probe callbacks are controlled fixtures.

## Validation

See the [batch validation record](../2026-10-30-recent-merges/CODEX_REVIEW.md). This PR is reviewed individually; validation is shared across the interacting changes.
