# PR #997 — Codex review

**Reviewer:** Codex · **Date:** 2026-10-30 · **Baseline:** `716bce14e` on `main`

[PR #997](https://github.com/BeamLabEU/phoenix_kit/pull/997) — Upgrading to 3.0: old host migration history on an empty database (`timujinne`). Reviewed the merged diff and current surrounding code, including subsequent merges.

Reviewed the fresh-database migration instructions against core's floor planner and module migration generation, including the distinction between schema_migrations tracking and the core table comment, hand-written migration guards, dependency ordering, and the warning about rolling new module install files back.

## NITPICK: the upgrade example claimed core migrations change no table (fixed)

That assertion is already stale: V226 adds the personal-key column and V227 adds managed-organization schema. Reworded the command comment to describe applying core updates followed by installed module chains. The guide still correctly explains that core no longer owns optional modules' tables.

No executable change was needed for this PR. The documented production migration rehearsal remains necessary; this review does not claim to have replayed a particular host application's history.

## Validation

See the [batch validation record](../2026-10-30-recent-merges/CODEX_REVIEW.md). This PR is reviewed individually; validation is shared across the interacting changes.
