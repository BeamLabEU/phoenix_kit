# PR #992 — Codex review

**Reviewer:** Codex · **Date:** 2026-10-30 · **Baseline:** `716bce14e` on `main`

[PR #992](https://github.com/BeamLabEU/phoenix_kit/pull/992) — Add personal API keys (`timujinne`). Reviewed the merged diff and current surrounding code, including subsequent merges.

Reviewed creation, scope edits, rotation, limits and advisory locks, live owner checks, permission registration, V226/manifest wiring, Settings → API, the profile page and embedded UserSettings contract.

## BUG - MEDIUM: clearing the embedded session scope retained the old scope (fixed)

`UserSettings.update/2` used `assigns[:scope] || previous_scope`. A host explicitly handing down `scope: nil` therefore kept the previous person's key context alive. The child still listed keys and accepted events, contrary to its fail-closed context contract. It now distinguishes an omitted assign (partial update) from an explicit nil with `Map.get/3`. A running-LiveView regression clears an initially valid scope and verifies that the key list disappears and mutation events are refused.

The key context independently rechecks permissions and account status; personal-key quotas serialize creation and rotations with overlap. No additional change to those rules or V226 was needed.

## Validation

See the [batch validation record](../2026-10-30-recent-merges/CODEX_REVIEW.md). This PR is reviewed individually; validation is shared across the interacting changes.
