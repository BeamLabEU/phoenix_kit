# PR #997 — Upgrading to 3.0: old host migration history on an empty database

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve, no code changes

Docs only (`guides/upgrading-to-3.0.md`, new section "Fresh databases and old host migrations").

## Checked against the code

- The quoted error text matches `BelowFloorError.message/1`
  (`"PhoenixKit database is at version N, below this release's floor (V225)"`,
  `lib/phoenix_kit/migrations/below_floor_error.ex`).
- "`up(version: 69)` on a database at V225 does nothing": `Postgres.up/1` plans from the stored version
  (`plan_up/4`); a target below the current version is not a raise and runs nothing.
- The floor is `@minimum_upgrade_version 225` and `module_tables_present?/1` is the sign of a
  2.x-built install (`lib/phoenix_kit/migrations/postgres.ex`), consistent with the two causes the
  section lists.
- The fix steps keep the Oban step files (`..._phoenix_kit_update_oban_vNN_to_vMM.exs`), which matches
  the Oban landmine in AGENTS.md (Oban's schema is not part of the core chain).

## Findings

- **NITPICK — not this PR.** `Postgres.up/1`'s comment says an install a 2.x chain built "has to reach
  V224 first"; the floor it enforces is V225. Comment only, left for whoever next edits that file
  (every edit to a `v*.ex` restamps the chain hash, but `postgres.ex` is not a `v*.ex`, so it is cheap).
