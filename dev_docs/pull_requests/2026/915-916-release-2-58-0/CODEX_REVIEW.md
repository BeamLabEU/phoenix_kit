# Codex review — release 2.58.0 (2026-10-08)

Reviewed `v2.57.1..c1e779015`, including PRs #915/#916, V212–V214, dependency updates,
the cross-library donor restriction, and the first review's fixes. Version 2.58.0
is still unpublished; the fixes below belong to its existing CHANGELOG entry.

**Verdict:** no CRITICAL or HIGH bug identified. Three MEDIUM bugs and one MEDIUM
audit improvement fixed. Release validation results are recorded below once the
final checks finish. This review does not authorize publishing or tagging.

## Fixed

- **BUG - MEDIUM — Stacks ignored the toolbar options.**
  `MediaBrowser.assign_stacks/1` and `stack_folder_files/3` passed only
  `lib_opts/1`, while the main listing used `list_extra/1`. Choosing Panoramas
  still counted and displayed ordinary pictures and videos inside a folder's
  stack; the chosen sort was ignored too. Both queries now use `list_extra/1`,
  preserving the library and restricted-viewer options it includes. A LiveView
  regression covers collapsed counts, expanded files, alphabetical ordering,
  and reopening a stack after clearing the shape filter. It failed against the
  release commit at the expected two-picture count.

- **BUG - MEDIUM — A null rendition shape reached the NOT NULL constraint.**
  `Dimension.changeset/2` validated inclusion but did not require `shape`; Ecto
  skips inclusion validation for nil. Creating or updating a nonstandard size
  with `shape: nil` raised `Postgrex.Error` rather than returning a changeset
  error. `shape` is now required. The database-backed regression reproduced
  ERROR 23502 before the fix and checks both create and update. An empty form
  string retains Ecto's existing behavior of restoring the default `"any"`.

- **BUG - MEDIUM — A relative library base meant different URLs to different loaders.**
  `pkLibUrls/1` returned the host's relative `PHOENIX_KIT_LIB_BASE` verbatim.
  A script's `src` resolves against the document; dynamic `import()` resolves
  against the executing bundle and rejects bare module paths such as
  `assets/lib/wavesurfer-….js`. Wavesurfer could fail while the script libraries
  worked. The local URL is now normalized against `window.location.href` before
  either loader receives it. Two regressions cover root-relative and
  page-relative overrides; both failed before the fix. Absolute bases and the
  bundle-derived default keep their existing URL behavior.

- **IMPROVEMENT - MEDIUM — Shape-only edits were missing from storage history.**
  `Storage.@audited_size_fields` omitted the new `shape` field, so changing just
  that field recorded no update. It now includes `shape`. A database-backed
  regression checks the actor, `any → wide`, and `wide → tall` using a stale
  struct to exercise the context's locked reload. No entry existed before the
  fix.

## Additional coverage and verified behavior

- A shape-filter query still respects both the restricted viewer and the
  requested library. Added a real-database test with another owner's wide/tall
  pictures and the viewer's own panorama in a second library; neither may enter
  the result or its count.
- Added a formatter test at Tallinn's spring gap and autumn repeated hour.
  Conversion starts from UTC instants, so neither ambiguous local times nor
  nonexistent local times need resolving.
- The prior review's concern that `vendor_all/1` lacks `run/1`'s application-load
  loop is **not a confirmed defect**. `ModuleDiscovery.scan_beam_files/0` reads
  `.app`/BEAM files from dependency code paths independently of loaded
  applications; `collect_specs/0` loads each discovered module before calling
  `js_sources/0`. No loading-loop change is needed on that evidence.
- V212 guards null/zero dimensions; V213/V214 use schema-qualified statements
  and preserve same-named sizes on upgrade through `ON CONFLICT DO NOTHING`.
  The expected-schema inventory includes both new columns and the partial
  aspect-ratio index. No migration SQL changed in this review.

## Remaining follow-ups

- **IMPROVEMENT - MEDIUM, sibling package:** Publishing's date preview now
  shows site time beneath an input correctly labelled UTC. The existing
  "Displays as:" prefix distinguishes the preview, but does not identify its
  time zone. Add that indication in `phoenix_kit_publishing`; this is a display
  clarity issue, not evidence of changed scheduling input semantics.
- **IMPROVEMENT - MEDIUM:** viewer metadata rotation by 90°/270° does not alter
  the stored width/height ratio. Shape follows physical image edits and EXIF
  dimensions, but not this display-only rotation. The Shape moduledoc's claim
  that every rotation changes shape is broader than its implementation.
- **IMPROVEMENT - MEDIUM:** the reconciler retains generated instances when a
  size's shape stops matching. Shape is intentionally absent from the pixel
  spec hash. Changing the size bumps its set's revision, but cleanup still
  recognizes every configured name. This retention is already disclosed in
  the release CHANGELOG; changing deletion policy needs dedicated coverage.
- **IMPROVEMENT - MEDIUM:** the legacy standalone
  `phoenix_kit_sortable.js` still fetches jsDelivr. It can be imported without
  the main bundle/install facts, so replacing that path needs a supported
  standalone initialization contract. The CHANGELOG discloses it.
- Sessions, Activity and Media detail use site time while the Users pages use
  viewer time. Consolidating those callers is a separate UX consistency task.
- V212 adds a stored generated column under an ACCESS EXCLUSIVE lock and
  requires PostgreSQL 12+. Table-rewrite duration depends on the host's data
  and workload; this review does not establish an upgrade-duration bound.
- V213/V214 rollback deletes names in the Default set even when an operator
  created them before the migration. Upgrade preserves them; rollback does
  not track seed ownership. Consider ownership-aware seeds before a future
  rollback-policy change.

## Validation

- `mix precommit`: passed (including warnings-as-errors compilation, test
  compilation, format check, strict Credo, Dialyzer, and 345 JavaScript tests).
- `node --test test/js/library_loader.test.cjs`: 28 passed, zero failures.
- Before the fixes, the null-shape regression raised ERROR 23502, the audit
  regression found no entry, the stack regression counted unfiltered files,
  and both relative-base assertions failed. After the fixes all four new
  Elixir/JS regressions passed. An unrelated audit setup test hit a database
  deadlock while the full suite's schema tests ran concurrently; final tests
  will run without overlapping suites.
- Final full database suite and `mix prerelease`: pending.

Hex publication and tagging were not run.
