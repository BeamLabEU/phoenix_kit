# Codex review — PhoenixKit 2.55.0 (2026-10-06)

Scope: the entire `v2.54.2..2d409f762` release diff (72 files), including PR #907,
Claude's release preparation, and the unreleased bucket, library-page and rendition
work. Version 2.55.0 includes all of main since 2.54.2; no migration is added or changed.

## BUG - MEDIUM — creation choices stayed stale across tabs — FIXED

`LibrariesComponent` stayed mounted while hidden and loaded profiles and rendition
sets once. Creating one in the neighboring tab then opening New library could not
select it without a page reload. The library tab now reloads when reopened, and New
library refreshes its choices even if another administrator changed them while the
tab remained open. A regression test creates both choices through their actual UI,
then creates a library using both without reloading.

## BUG - MEDIUM — stale rendition actions crashed the page — FIXED

The rendition delete/toggle events passed an unchecked client id to the context. A
row deleted elsewhere produced nil and a function-clause or field-access error;
malformed UUIDs raised in Ecto. A valid id could also mutate a different set from
the one displayed. Actions now cast the id, require an existing rendition in the
selected set, and refuse stale/invalid/other-set ids without terminating the view.
Reloading also handles a set deleted elsewhere. Saving a deleted set now handles
`:not_found` separately from validation changesets rather than passing it to
`to_form/1`; the context's return spec now documents that existing error as well.
Regression coverage exercises all three id cases for both row events,
reopening a deleted selected set, and saving a set deleted while its form was open.

## BUG - MEDIUM — rendition tabs retained outdated sets — FIXED

Moving the rendition list from its own LiveView to an always-mounted component
meant reopening it no longer refreshed the list or selected set unless the URL's
set parameter changed. The component now reloads on inactive-to-active transitions,
while ordinary parent updates preserve form edits. Regression coverage adds a set
while the tab is hidden and checks that reopening exposes it.

## IMPROVEMENT - MEDIUM — library rendering queried each profile/set — FIXED

Every library row called `Profiles.profile_name/1` and `VariantSets.set_name/1`,
performing two database reads during rendering. The component already loads these
lists; it now builds name maps once and renders against them, removing per-row reads.

## IMPROVEMENT - MEDIUM — new library forms used obsolete styling — FIXED

The new library creation controls and library-page controls carried daisyUI 4's
`form-control`, `label-text`, `input-bordered` or `select-bordered` classes and
hand-built label associations. They now use the shared Input/Select components with
explicit ids, keeping the existing events, field names and defaults.

## BUG - MEDIUM — release's PostgreSQL tab tests failed — FIXED

The initial full PostgreSQL run found four tab failures. The new "Renditions" test
matched both the main tab and the nested Default set tab; three existing URL-tab
assertions counted the hidden rendition set's active tab as a second page tab.
Selectors now distinguish the page tab strip from the nested set strip.

## BUG - MEDIUM — audit defaults lost their meaning — FIXED

The release changed the existing annotated-thumbnail audit default from "site default"
to "default", breaking its integration assertion and making the source of the
inherited value unclear. Audit labels now keep "site default" for annotated
thumbnails and use "rendition set" for deep zoom. A regression test records both
setting and removing a deep-zoom override.

## BUG - HIGH — Health exposed personal-library filenames — FIXED

The moved Health report inherited a privacy bug from the old page: its detailed
stale-file query returned personal-library filenames and library names to every
holder of `media.manage`. Personal contents are opened through a separate,
audited route, not exposed as part of storage configuration. The Health list now
queries site-library files only, before applying its limit. Aggregate counts and
reconciliation work still include personal libraries. The empty-report condition
uses the stale count, so a report waiting only on personal files does not announce
"All Healthy". A translated note explains the counts, and a PostgreSQL regression
checks that a personal file is counted, never named or linked, and remains waiting.

## Traced without a finding

- The release keeps migration files and schema versions unchanged. New deep-zoom
  values use the existing library settings JSON map, with the legacy set flag as
  the fallback for libraries that have not chosen.
- System-library creation rejects unknown or user-owned storage profiles and
  unknown rendition sets. The UI no longer repoints an existing system library;
  the code APIs remain available. User-library APIs retain their ownership rules.
- Library pages resolve only live system libraries and are mapped to `media.manage`.
  Personal libraries do not open through the new page; personal bucket listings
  remain separate from site enumeration. Library sync controls keep Jobs' context
  permission checks and active-role scope.
- Bucket totals count distinct file ids and distinct physical keys, including shared
  keys, using batched aggregate queries. Profile upload order remains independent
  of legacy bucket priority, and new buckets join the shuffled profile pool.
- PR #907's eye/pencil states, plain-canvas payload, copy behavior, palette fallback,
  per-user annotation preference, merged custom-fields writes, text-box persistence
  kind, and the 0.19.0 Elixir/CDN dependency pins match their producers and consumers.
- The health report loads when its tab is opened, and old list/health addresses
  redirect to the corresponding new tabs. Navigation uses the prefix helpers.
- Changelog version/date and quarterly archive are consistent; the 2.55.0 entry
  describes the full release, including the review fixes.

## Validation

- Full PostgreSQL rerun after the initial fixes: 87 doctests, 8,612 tests,
  zero failures, six skipped. One CREATEROLE-only test was excluded because
  the disposable test role lacks that permission; integration tests ran.
- Final affected-suite run after the Health privacy and deleted-set fixes:
  165 tests, zero failures, covering storage tabs, library pages/creation,
  rendition editing, audit history, Health and reconciliation.
- Final `mix precommit`: passed warnings-as-errors compilation, unused-dependency
  check, test-tree compilation, formatting, strict Credo, Dialyzer and all
  291 JavaScript tests.
- Translation catalogs: zero fuzzy entries; the Health privacy note is translated
  in every shipped locale. Migration files and V209 remain unchanged.

The release workflow runs `mix prerelease` on the committed, clean main checkout
before Hex publication, and creates the version tag only after publication succeeds.
