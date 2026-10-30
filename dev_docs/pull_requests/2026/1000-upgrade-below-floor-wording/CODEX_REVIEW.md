# PR #1000 — Codex review

**Reviewer:** Codex · **Date:** 2026-10-30 · **Baseline:** `716bce14e` on `main`

[PR #1000](https://github.com/BeamLabEU/phoenix_kit/pull/1000) — 3.0 guide: say exactly which lower databases are refused (`timujinne`). Reviewed the merged diff and current surrounding code, including subsequent merges.

Checked the clarified V225 upgrade advice against `Postgres.up/1`, `plan_up/4`, the V135 initial baseline, the module-table presence test, and the update task's preflight. The distinction is intentional: the update task refuses a lower stamp; the migration entry point can resume a partial core-only fresh installation at V135 or later, while legacy module tables identify an upgrade that needs the bridge.

No additional findings. The guide names the bridge and the earlier pre-V135 bridge, and keeps prefix-specific checks explicit.

## Validation

See the [batch validation record](../2026-10-30-recent-merges/CODEX_REVIEW.md). This PR is reviewed individually; validation is shared across the interacting changes.
