# PR #1000 — 3.0 guide: say exactly which lower databases are refused

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve, no code changes

Docs only (`guides/upgrading-to-3.0.md`, step 1). Checked each sentence against the code:

- `mix phoenix_kit.update` refuses every database below the floor at generation time with a notice
  naming `MigrationsPostgres.bridge_version/0` (`"2.65.0"`) — `add_below_floor_notice/3` in
  `lib/mix/tasks/phoenix_kit.update.ex`.
- `PhoenixKit.Migrations.up/1` raises `BelowFloorError` (with `bridge_version: "2.65.0"`) below V135,
  and for V135..V224 only when `module_tables_present?/1` is true; a fresh install of this release
  that stopped part-way resumes instead (`lib/phoenix_kit/migrations/postgres.ex`, `up/1`).

The new wording is accurate. No findings.
