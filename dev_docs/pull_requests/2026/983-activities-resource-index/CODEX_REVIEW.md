# PR #983 — Activity resource index and notification translations

**Reviewer:** Codex · **Date:** 2026-10-29 · **Baseline:** `38a116bc4`

Reviewed V224, its manifest entry and integration tests, notification type normalization, backend inheritance and the label consumers. No additional defect found.

The index matches the per-resource feed query, uses a bare CREATE name and a qualified DROP, and resets its lock timeout. Existing tests execute the SQL and compare the catalog with the manifest. The previous post-merge fixes already route the notification settings matrix, cadence labels and digest labels through `Types.translate/2`. No migration was edited or manifest restamp required.

## Validation

See the [batch validation record](../2026-10-29-recent-merges/CODEX_REVIEW.md).
