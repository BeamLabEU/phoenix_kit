# PhoenixKit 2.52.0 — independent release recheck

Date: 2026-10-04. Reviewer: GPT/Codex.

Reviewed the complete core release diff from `v2.51.0` to `v2.52.0`, all seven merged PRs (#895, #896, #898–#902), Claude's release-review commit, the packaged artifact and the relevant callers/tests. Other repositories were outside the published core release and were not changed.

## Verdict

The reported fixes are present and work. Found one additional deploy-affecting defect in #902: post-migration verification reports an incompatible Oban schema but still returns successfully. Fixed locally with regression coverage. The published 2.52.0 package still contains this defect; this recheck does not publish a replacement or move its tag.

The same-repo welcome path, Markdown substitution/escaping, confirmation screen, runtime discovery cache, router fingerprint, module-owned FK exclusion and sidebar ordering otherwise check out. Previously recorded limitations remain below.

## Additional findings and local changes

1. **BUG - MEDIUM, #902:** `verify_oban_schema_migrations/1` called `Mix.shell().error/1` when the staged migration had not taken effect. `update --yes` could report success while the schema remained incompatible. Reproduced with the real verifier after a no-op successful migrate step; the new test failed before the fix. It now raises `Mix.Error`, stops subsequent module migrations, and identifies the target and migration-path remedy. Regression cases cover behind, unversioned, absent-table and failed-query results; a current schema proceeds.
2. **NITPICK:** fixed an Elixir 1.19 type warning in the new welcome-email test by matching the user struct before updating it. Removed a pre-existing unreachable permission-revoke success clause from the email-preview test helper. Re-running `mix test.compile` produced no warnings.
3. **NITPICK:** the first full suite exposed a pre-existing race in `LibrariesSyncTest`: it inspected component state immediately after sending the refresh message, whose handler queues `send_update` to itself. The entire file passed in isolation with the same seed. Added a `:sys.get_state` message-processing barrier before the assertion; the file passed again. The storage implementation is unchanged.
4. **NITPICK:** verified the legacy Oban APIs from released packages and corrected the comment: `Oban.Migrations.Postgres.current_version/0` already exists in 2.20, rather than starting in 2.21.

## Release provenance

- `v2.52.0` resolves to `72c9b8127d7df5157d2375fd982b60037d7e716c`, also the remote release commit when checked.
- Hex published 2.52.0 at `2026-10-04T13:55:24.771643Z`; it was not retired when checked.
- Downloaded `https://repo.hex.pm/tarballs/phoenix_kit-2.52.0.tar`. Its SHA-256 matches the Hex API checksum: `76bde9b9944f0faa84144454c228037caf61316b4fa84565b4edcfbe33ab584d`.
- Compared all 800 regular files in `contents.tar.gz` against the tag: no missing files and no byte differences.
- No versioned core migration changed; the latest core chain version remains V208. Q3 changelog entries were already archived and the shipped changelog contains Q4 entries.

## Validation

- Original full PostgreSQL-backed run: `PGPOOL=20 mix test --max-cases 8`, seed 951409: 87 doctests, 8272 tests, one failure in the older asynchronous storage assertion described above; 6 skipped, 1 excluded. Integration tests ran; the role lacks CREATEROLE, so its privilege-specific test was excluded.
- Fixed updater, Oban upgrade integration, welcome-email integration and email-preview integration together: 69 tests, zero failures.
- Storage refresh file with seed 951409 after the barrier: 7 tests, zero failures.
- Full PostgreSQL rerun after the fixes: `PGPOOL=20 mix test --seed 951409 --max-cases 8` passed: 87 doctests, 8274 tests, zero failures, 6 skipped (1 excluded), in 529.2 seconds. The same lack of CREATEROLE excluded the privilege-specific test.
- `mix precommit`: passed (compile with warnings as errors, unused-lock check, test compilation, format, Credo, Dialyzer, 254 JS tests). The first run emitted the two test warnings subsequently fixed; a second full `mix precommit` run passed after both test warnings were removed.
- `MIX_ENV=prod mix compile --warnings-as-errors`: passed, including a final recompilation after the API comment correction.
- `MIX_ENV=test mix run --no-start dev_docs/squash/generate_baseline.exs --check`: passed, including module-owned exclusion.
- `mix deps.audit`: no vulnerabilities found. `mix hex.audit`: no retired or security-advisory packages found.
- Loaded Oban 2.20.0, 2.21.0 and 2.22.0 migration source from their released tarballs in separate disposable VMs and checked `ObanSchema.check/2` against current and behind catalog answers. All passed; also recompiled `ObanSchema` against 2.20 without warnings. This tests the legacy migration/version APIs, not the complete PhoenixKit suite against each old dependency version.

## Remaining release limitations

- **BUG - MEDIUM, #899:** the welcome button points to the host root, which may have no route. Claude already recorded this; changing the translated default destination was left out of this audit patch.
- **BUG - MEDIUM, #899:** welcome enqueue/savepoint atomicity requires Oban and PhoenixKit to use the same repo. With a separate Oban repo the job is independently committed and can be lost if executed before confirmation commits; a rolled-back confirmation does not remove it. Confirmed against real PostgreSQL with two independent repo pools and a scratch Oban schema: after the confirming repo rolled back, one welcome job remained committed. The scratch schema was removed afterward. Claude listed this as a nitpick, but it is a functional limitation. A cross-repo strategy or enforced same-repo contract needs its own change.
- **BUG - MEDIUM, #902:** status starts only the host repo; a second configured Oban repo can make `status --exit-code` fail even with a healthy schema. Already recorded by Claude and unchanged.
- **IMPROVEMENT - MEDIUM, #902:** `update --no-start` omits Oban staging, with a warning to run the full update afterward. Custom instance names and dynamic repo options are not fully discovered.
- Sidebar custom groups registered after boot cannot receive boot-time overrides; unlisted module ids retain their package priority. These are the existing documented ordering limits.

## Per-PR reviews

- [#895 / #898 — module discovery and router fingerprint](../../pull_requests/2026/895-898-module-discovery-scan-cache/GPT_REVIEW.md)
- [#896 — newsletters manifest FK](../../pull_requests/2026/896-manifest-newsletters-template-fk/GPT_REVIEW.md)
- [#899 — Markdown, welcome and notification emails](../../pull_requests/2026/899-auth-emails-markdown/GPT_REVIEW.md)
- [#900 — confirmation screen](../../pull_requests/2026/900-confirm-page-shorter/GPT_REVIEW.md)
- [#901 — sidebar ordering](../../pull_requests/2026/901-admin-tab-order/GPT_REVIEW.md)
- [#902 — Oban schema upgrades](../../pull_requests/2026/902-oban-schema-upgrade/GPT_REVIEW.md)
