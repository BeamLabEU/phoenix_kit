# PR #902: Fix the Oban schema falling behind the Oban library — `phoenix_kit.update` steps it up

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged
**Commit**: `7686938b9`, `8eda59652`, `8ede87c89`, `16233aa50` (merge `58cb36327`)
**Date**: 2026-10-04

## Goal

Core installs Oban's tables once (V135 → `Oban.Migration.up/1`) and a host may later move to a
newer Oban (`~> 2.20` pin) whose schema version is higher; nothing migrated the schema. The PR adds
`PhoenixKit.ObanSchema`: read the version comment on `oban_jobs`, compare with the library, and have
`mix phoenix_kit.update` write a host migration that runs `Oban.Migration.up/1` to the library's
version. Doctor and status report it; the supervisor logs one boot warning.

## What was changed

| File | Change |
|---|---|
| `lib/phoenix_kit/oban_schema.ex` | New: `check/2`, `classify/2`, `targets/3`, `stage/4`, `write_migration/5`, `migration_source/4`, `warn_if_behind/1` |
| `lib/mix/tasks/phoenix_kit.update.ex` | New `run_schema_steps/2` (stage → migrate → verify → modules); reporting + "other repo" hint |
| `lib/mix/tasks/phoenix_kit.doctor.ex`, `phoenix_kit.status.ex`, `install/status_report.ex` | Oban schema check / row / `Next` action |
| `lib/phoenix_kit/supervisor.ex` | `oban_boot_checks/1` (queues + schema) replaces the anonymous Task fn |
| tests | pure (`oban_schema_test`, `status_report_test`, update task), and a real-DB `oban_schema_upgrade_test` |

## Verification

Checked against Oban's source (`deps/oban` 2.24.1 and the 2.21.1 / 2.22.0 / 2.23.x / 2.24.0 tarballs
in the Hex cache), not the PR description:

- **Version read** — `read_comment/2` is the same catalog query as `Oban.Migrations.Postgres.migrated_version/1`,
  parameterised (`$1`), with the missing-table / no-comment cases kept apart. `∞` handling matches Oban
  (`:infinity < n` is false in term order, so `up/1` is a no-op there).
- **`down(version: from + 1)`** — correct: `Postgres.down/1` runs `initial..version//-1` and records
  `version - 1`, so the generated `down` reverts exactly the stepped range and restamps `from`.
- **`create_schema: false`** — correct for a schema that already holds `oban_jobs`; `up/1` only runs
  `initial+1..version` and is idempotent when re-applied.
- **Oban boot verification does not preempt the fix** — `Oban.start_link/1` calls
  `Oban.Migration.verify_migrated!/1` only when `testing != :disabled`, so a production host on an
  outdated schema still boots (and the boot warning is reachable). `Oban.config/1` normalises the
  `repo: {Repo, opts}` tuple to the atom, so `warn_if_behind/1` is fine with it.
- **Supervisor child** — `%{id: :oban_queue_check, start: {Task, :start_link, [mod, :oban_boot_checks, []]}, restart: :temporary}`
  is equivalent to the old `Supervisor.child_spec({Task, fn}, id:)` (Task children are `:temporary`).
  `ObanQueues.warn_about_missing_queues/1` accepts the `:oban` opt. `warn_if_behind/1` has both `rescue`
  and `catch _, _`, and `check/2` itself `rescue`s and `catch :exit` — an unreachable DB or dead pool
  cannot take boot down.
- **Injection** — the repo/prefix reach SQL only as a bound parameter; the prefix reaches the generated
  file only after `generatable_prefix?/1` (`\A[a-z_][a-z0-9_]*\z`), and the non-generatable fallbacks
  use `inspect/1`. See the nitpick on the one hint that does not.
- **Timestamps** — `unique_timestamp/2` is `max(now + i, highest + 1 + i)` over the directory, so the
  Oban file sorts after the core file Igniter wrote and several files in one run stay unique and increasing.
- **Re-run idempotency** — the `*_<suffix>` wildcard (suffix carries prefix, from and to) reuses an unapplied file
  and cannot collide with another prefix's file because the prefix sits between fixed segments.

## Findings

### BUG - MEDIUM — `Oban.Migration.current_version/1` does not exist on Oban 2.21 — `check/2` can never answer there

`lib/phoenix_kit/oban_schema.ex:81`. Core's pin is `{:oban, "~> 2.20"}`. `Oban.Migration.current_version/1`
is public only from 2.22.0 (absent in 2.21.1; `Oban.Migrations.Postgres.current_version/0` is present from
2.21.1, and 2.21.1 already ships schema V14). On such a host the call raises `UndefinedFunctionError`, which
`check/2`'s `rescue` turns into `{:error, "..."}` — so every run reports "could not read": `doctor` warns,
`status --exit-code` exits non-zero (`{:check_oban_schema, _}`), and `update` never writes the migration — the
feature is silently disabled exactly where the schema can be behind. The tests all run against the locked 2.24.1,
so none can see it.

**Fix**: read the expected version through a helper that works on every Oban the pin admits:

```elixir
defp expected_version(repo) do
  if function_exported?(Oban.Migration, :current_version, 1),
    do: Oban.Migration.current_version(repo: repo),
    else: Oban.Migrations.Postgres.current_version()
end
```

(`check/2` already returned early for non-Postgres adapters, so the Postgres module is the right fallback.)
`Code.ensure_loaded?(Oban.Migration)` first, since `function_exported?/3` does not load. Add a unit test for the
fallback branch via the pure `classify/2` seam, or inject the version.

### IMPROVEMENT - MEDIUM — `repo: {Repo, opts}` in the host's Oban config is read as "no repo named"

`lib/phoenix_kit/oban_schema.ex:162-166`. Oban 2.24 accepts `repo: {MyApp.Repo, log: false, dynamic_repo: ...}`
(`Oban.Config.normalize_repo/1`). `oban_target/2` only matches an atom, so a tuple silently falls back to
`host_repo`: a host whose Oban runs on another repo via the tuple form has the *wrong repo* checked with the Oban
prefix (a false `:current`/`:no_table` for the real schema, or a migration written for the wrong database).

**Fix**: add a clause `{repo, opts} when is_atom(repo) and is_list(opts) -> repo`. Add a `targets/3` doctest.

### IMPROVEMENT - MEDIUM — `mix phoenix_kit.status --exit-code` can fail for a host whose Oban uses a second repo

`lib/mix/tasks/phoenix_kit.status.ex` (`oban_schema_entries/2`). Status starts only the host repo
(`ensure_repo_started/1`); `ObanSchema.check_all/2` on `{OtherRepo, prefix}` hits an unstarted repo, which
`check/2` converts to `{:error, ...}` → `{:check_oban_schema, labels}` → exit 1 on every deploy-gate run, with a
message ("run mix phoenix_kit.doctor") that cannot fix it. (Doctor and the full update boot the app, so they are fine.)

**Fix**: in status, call `ensure_repo_started/1` for each target repo, or report a target repo that is not running
as "not queried" rather than unreadable.

### IMPROVEMENT - MEDIUM — the `--no-start` update never stages the Oban migration

`update.ex` `schema_only_update/1` (see the "Not checked either" note). `--no-start` is the documented recovery path
when the app will not boot, and it already starts the host repo; `ObanSchema.stage/4` needs nothing else for the
host-repo targets. A host that needs both a column-adding release and an Oban step-up must run `--no-start`, then
the full update again. Acceptable (documented), but cheap to close: call `stage_oban_schema_migrations/1` before the
`ecto.migrate` there, keeping the `:other_repo` hint for non-host targets.

### NITPICK — moduledoc dates schema version 14 to Oban 2.24

`oban_schema.ex:13`. `V14` (the `suspended` enum value) ships in 2.21.1 already; what 2.24 changed is the unique
check's default states. Say "Oban 2.21+ has schema version 14; since 2.24 the default unique check looks in
`suspended`" — or drop the version attribution. Same sentence appears in `AGENTS.md`/the update task docs
("under Oban 2.24 (schema v14)" is fine as an observation, not as an introduction).

### NITPICK — custom Oban instance names are not covered

`supervisor.ex` `oban_boot_checks/1` is called with `[]`, `targets/3` reads `Application.get_env(app, Oban)`, so a host
running `name: MyApp.Oban` (config under `MyApp.Oban`) gets no boot warning and no update/doctor/status target.
Pre-existing for the queue check; document it or pass the host's name through a `config :phoenix_kit, oban_name:` key.

### NITPICK — the "unversioned" hint interpolates the prefix unquoted

`update.ex` `report_oban_schema/2` (`{:unversioned, _}` clause): `COMMENT ON TABLE "#{entry.prefix}".oban_jobs ...`.
A prefix containing `"` would print a broken statement to copy-paste. Use `inspect(entry.prefix)` as Oban's own
`record_version/2` does.

### NITPICK — "Reusing it" for a file that was already applied

`{:exists, path}` is also returned when the file was applied and the schema later regressed (restored backup, a
second environment). The message says "Reusing it", but `ecto.migrate` will not run an applied version, and the verify
step then blames the migration path. The message already says to delete the file first; consider saying that the file
may already have been applied.

## Tests

- The real-DB test is the right oracle (unique insert fails on v13 with the exact enum error; generated file
  applied through `Ecto.Migrator`, then the insert goes through). `async: false`, sandbox flipped to `:auto` and
  restored in `on_exit`, scratch schemas dropped in `on_exit` — hygiene is fine.
- Gap: nothing exercises Oban < 2.22 (finding 1), a tuple `repo:` (finding 2), or status with a second repo (finding 3).

## Verdict

Approve as merged — the design is sound, the generated migration (up/down/`create_schema: false`/idempotent reuse)
checks out against Oban's own code, and boot/doctor/status paths do not crash on an unreachable DB. The one real
defect is the `current_version/1` call, which disables the feature on part of the version range the pin allows.

## Resolution (2.52.0)

- **BUG - MEDIUM (`current_version/1` before Oban 2.22)** — fixed: `ObanSchema.library_version/1` uses
  `Oban.Migration.current_version/1` when exported, else the Postgres engine's `current_version/0`, else reports an error.
- **IMPROVEMENT - MEDIUM (`{repo, opts}`)** — fixed, with a doctest.
- **IMPROVEMENT - MEDIUM (status with a second repo)** and **(`--no-start` path)** — not changed: the `--no-start`
  path is the emergency route and documents that it checks nothing but the core chain; the status case is a
  limitation noted for hosts with Oban on another repo.
- Moduledoc version claim, unquoted prefix in the hint, "Reusing it" wording — fixed.
- Custom Oban instance names — left as noted.
