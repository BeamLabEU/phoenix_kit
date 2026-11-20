# Release prep review — v3.6.1 → 3.7.0

Second pass over the release range `v3.6.1..HEAD` (114 commits, PRs #1037–#1050, per-viewer menu
badges, dependency updates, post-merge fixes), after the 2026-11-20 release recheck. The
individual PR records live in `dev_docs/pull_requests/2026/1037-*` … `1050-*`.

## What was verified at HEAD

- `mix compile --warnings-as-errors` clean; `mix format --check-formatted` clean.
- Full suite on a **fresh dedicated database** (`MIX_TEST_PARTITION=_rel1`, migrated through V234),
  seed 759714: **16 190 tests + 99 doctests, 0 failures**, 34 skipped, 1 excluded
  (`:requires_createrole`; the role lacks CREATEROLE).
- `mix precommit` green end to end: compile, `deps.unlock --check-unused`, `test.compile`,
  format, `credo --strict` (no issues), dialyzer (passed; 302 known skips), 937 JS tests.
- `mix phoenix_kit.release_check`: migration chain V135..V234 contiguous, `chain_hash` matches all
  100 on-disk files, expected-schema manifest current, branch `main`, no tag collision for 3.7.0.

## Finding — test-environment only

- **FLAKE - MEDIUM (test harness).** A first full run against the shared `phoenix_kit_test`
  database produced 1 856 failures while a second agent's run was using the same database (global
  settings stomping). On a fresh partition database with the same seed the suite is fully green, and
  the worst-offending files pass against the shared DB when run alone — no code regression. As a
  hardening, `PhoenixKit.Test.ApiKeyTestSupport.write_setting/1` now tolerates all three
  "settings cache absent" log lines (`could not be invalidated: {:noproc…}`, `unavailable: …`,
  `not started`) instead of only the first: stray cache-absence warnings from other processes can
  land in the capture window, and they mean the same thing as the one already allowed. Any other
  warning during a settings write still fails the test.

## Findings fixed

- **NITPICK.** `ScopeBadges.put_badges/2` called the host's `badges/1` even with a `nil` scope,
  against its own doc ("nothing is computed for a visitor who gets no menu"); the callback would
  raise on `Scope.user_uuid(nil)` and log a warning on every anonymous render. A `put_badges(tabs,
  nil)` clause now returns the tabs untouched, with a regression test.

## Release prep done here

- `mix.exs` `@version` bumped to **3.7.0** (new features + migrations V233/V234 → minor bump).
- `CHANGELOG.md`: `## Unreleased` dated as `## 3.7.0 - 2026-11-20`, and the entries missing from it
  added — `<.resizable_modal>` (#1048), the `PkFitHeight` hook (#1049), the sign-in/sign-up redesign,
  touched-field-only form errors and the confirmation scope refresh (#1050), the provider-button
  credential check, the confirmation-token fix, the stale/missing facts notice (#1037), the image-set
  cover-tile and local-storage fixes (#1038 + release recheck). Same quarter (2026 Q4), so no changelog
  archive move.

## Known flakes (not from this range)

- `V220Test` "the stuck-operation sweep index …" asserts an `EXPLAIN` plan uses the partial index
  with `enable_seqscan = off`; the planner may pick another index depending on statistics, so the
  test flakes on some databases (seen on two of four full runs; green when run alone). Untouched
  since before v3.6.1 — left as is for this release; worth hardening separately (assert index
  usability from the catalogs instead of the plan).
- Under full-suite load on the shared test server, two more one-off flakes appeared and pass in
  isolation: `ProfileSettingsTabsTest` (a `57014 query_canceled` inside `grant_permission/3`, i.e.
  lock/statement timeout under contention) and `PasskeysWebTest` "keeps return_to through the
  one-time link" (the async passkey completion missed `assert_redirect`'s wait under load).
- A full run against the **shared** `phoenix_kit_test` database while another agent runs against it
  fails en masse (global settings) — use a `MIX_TEST_PARTITION` database for release runs.

## Status after this pass

- Prepped and committed on `main` (`df50e5ad0`): version 3.7.0, dated changelog, the two fixes above,
  this record. `mix precommit` green; `mix phoenix_kit.release_check` 6/7 (the one WARN is the
  `hex.build` package-content check, which `mix prerelease` runs).
- Full suite with these changes on fresh partition databases: 16 191 tests + 99 doctests; the only
  failures across two runs were the pre-existing flakes listed above (all green in isolation).
- Still open for the release cut: `mix prerelease` (gate), `mix hex.publish`, push, tag `v3.7.0`.
- The opt-in offline annotation feature still keeps local copies after sign-out (see the #1047
  review) — called out in the 3.7.0 changelog entry itself.
