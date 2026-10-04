# PR #902 — GPT release recheck

Reviewed the published 2.52.0 tag (`72c9b8127`) against 2.51.0, including Claude's post-merge fixes.

## BUG - MEDIUM — post-migration verification still exits successfully on failure

`verify_oban_schema_migrations/1` rechecks each staged target after `ecto.migrate`, but its failure branch only calls `Mix.shell().error/1`. The function returns normally, module migrations continue, and `mix phoenix_kit.update --yes` exits successfully although Oban is still behind or unreadable. This can happen when a generated migration has already been marked applied, or the migrator did not scan the generated file. Unique inserts can remain broken behind a green deploy result.

Reproduced through `run_schema_steps/2` with a successful no-op migrate step and the real default verifier. Before the fix, the regression expected `Mix.Error`, but nothing was raised. **Fixed locally:** the verifier now raises `Mix.Error` with the target and remediation details. Tests cover behind, unversioned, missing-table and failed-read results, assert module migrations do not run, and verify a current schema continues normally. This change is not in the published 2.52.0 artifact.

## Compatibility and migration checks

The old-version fallback works. Loaded the released Oban 2.20.0, 2.21.0 and 2.22.0 migration modules into separate disposable VMs, recompiled `ObanSchema`, and checked current and behind catalog results. The first two lack public `Oban.Migration.current_version/1`; the fallback reads schema v13 and v14 respectively. Oban 2.20 already exposes `Oban.Migrations.Postgres.current_version/0`, contrary to the released comment saying it begins in 2.21; corrected that comment locally.

Tuple repo config resolves the intended repo. Generated upgrade/downgrade bounds, schema qualification, `create_schema: false`, distinct prefix module names and duplicate-file reuse were checked. The real database suite reproduces the missing `suspended` enum state, applies the generated migration and checks unique inserts afterward.

## Known limitations retained

- **BUG - MEDIUM:** status only starts the host repo; a configured second Oban repo can be reported unreadable and make `--exit-code` fail even with a healthy database. Already recorded by Claude; left unchanged in this recheck.
- **IMPROVEMENT - MEDIUM:** the recovery `--no-start` path does not stage Oban's migration. Its warning documents the need to run the full update afterward.
- Custom-named Oban instances and dynamic repo options are outside the current target discovery/boot checks.

See the [complete release recheck](../../../reviews/2026-10-04-2.52.0-release/GPT_REVIEW.md) for validation and package provenance.
