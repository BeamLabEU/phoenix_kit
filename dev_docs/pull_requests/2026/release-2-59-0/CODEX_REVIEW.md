# Codex review — release 2.59.0 (2026-10-09)

Reviewed `v2.58.0..dbfe056831c8feab5e491766f19d8e1fda3c98e3`, including the prior review fixes,
V215, EXIF ingestion and display, map filtering, both language editors, and translations.
No CRITICAL or HIGH finding. Four MEDIUM bugs remained; all are fixed locally with regression coverage.
The version remains 2.59.0. This review does not push, publish, or tag the release.

## Fixed findings

- **BUG - MEDIUM — exposure-time fractions bypassed the number limit.** `Exif.exposure_time/1`
  still converted unbounded numerator and denominator strings to integers and divided them in
  `reduced/2`. `ExposureTime = <400 nines>/2` reproduced an `ArithmeticError` through `summary/1`,
  also reachable through `groups/1`. Both parts are now limited to 15 digits before conversion;
  oversized fractions are dropped from the summary. Tests cover both oversized parts.
- **BUG - MEDIUM — GPS timestamps still accepted impossible dates and second 60.** The prior fix
  checked the date's shape, not its calendar validity. `2026:02:30` became
  `2026-02-30T01:02:03Z`. The date now passes `Date.from_iso8601/1`, and seconds must be below 60.
  Tests cover an impossible day, month 13, second 60, and a valid leap day.
- **BUG - MEDIUM — longitude wrapping failed west of -540 degrees.** Erlang's `fmod` returns a
  negative remainder for negative inputs. Bounds `{-20, -550, -10, -530}` found only western Fiji,
  missing the eastern half of the same box. The remainder is now normalized before subtracting
  180. Real-database tests cover a wrapped antimeridian box and a box around Graz two worlds west.
- **BUG - MEDIUM — stale forms overwrote another editor's untouched language or field.**
  `put_languages` compared posted values with the newly locked row, which makes stale hidden
  inputs look like changes. The existing test posted the *new* Estonian title and therefore did
  not exercise a stale form. It now posts the original title and failed before the fix.
  Saves compare against the initial file/form snapshot and apply only changed fields to the
  locked row. Both editors supply their initial values; the detail page retains a separate
  snapshot across validation failures. Tests cover stale languages, another field in the same
  language, the actual detail form, the viewer's event, and correction after an invalid save.
  Initial form values pass through the same empty-value normalization as submitted text, so an
  untouched blank translation also preserves text another editor added since the form loaded.

**NITPICK:** removed the new component's `input-bordered` / `textarea-bordered` classes, which do
not exist in daisyUI 5, as required by the workspace conventions.

## Checked

- Reproduced all four bugs before fixing them: the first targeted run had five failing tests
  (the stale-language and stale-field cases are separate tests).
- PostgreSQL `EXPLAIN` confirmed the actual point-in-box predicate can use
  `phoenix_kit_files_geo_index` even without explicit `IS NOT NULL` predicates.
- V215 adds nullable columns, uses a schema-safe index name, has an idempotent up/down path,
  and is declared in `ExpectedSchema` with the updated migration-chain hash.
- Existing EXIF writes retain the original-key guard and merge current metadata under the row lock.
- The EXIF event guard blocks hosts without the metadata editor; the viewer write also checks scope.
- All 34 new msgids have translations in de/es/et/fr/it/pl/ru, with zero fuzzy entries.
- The final focused run after fixes passed 78 tests. Full validation results are recorded below.

## Validation

- The original committed release passed `mix prerelease`, including dependency audits, package build,
  all seven release checks, and package cleanup.
- Final `mix precommit`: passed, including compilation of the test tree, format, Credo, Dialyzer,
  and all 345 JavaScript tests.
- Final `PGPOOL=20 mix test --max-cases 8`: passed with 87 doctests, 8997 tests, zero failures,
  and 10 skipped tests (including one excluded because the test account lacks `CREATEROLE`).
  Integration tests were enabled, including V215 and the full migration chain into a named schema.
- Final `mix prerelease`: passed against the clean code commit `6b1011339`, including the production
  compile, quality checks, dependency audits, documentation, package build, and all seven release checks.
  No vulnerabilities or retired/security-advisory packages; the generated tarball was cleaned.
  ExDoc emitted existing documentation-reference warnings, which do not fail the gate.

The subsequent validation-record commit changes only this review document; release code is unchanged.

## Remaining limitations

- Two `identify` reads per uploaded image, no map UI consuming `bounds:`, and no bulk EXIF backfill
  remain as described in the original review.
- Deliberate edits to the same field follow the last save; unrelated untouched text is preserved.
- Tags are still an explicit whole-list metadata save, as before this release.
