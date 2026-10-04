# PR #896: Remove the newsletters template FK from core's schema manifest

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged
**Commit**: `530d80892` (merge `edfb84abf`)
**Date**: 2026-10-02 (merged 2026-10-04)

## Goal

V135 creates `fk_newsletters_broadcasts_template` (`template_uuid` → `phoenix_kit_email_templates`).
The newsletters module repoints that FK, under the same name, at a table of its own. While
core's `ExpectedSchema` described it, `mix phoenix_kit.doctor` reported a healthy install as
`:wrong_shape`, and `mix phoenix_kit.repair` re-created it pointing at the email templates.

## What was changed

| File | Change |
|---|---|
| `lib/phoenix_kit/migrations/expected_schema.ex` | The one constraint object removed, with a dated note where it sat and a line in the conventions header |
| `dev_docs/squash/generate_baseline.exs` | `@module_owned_ids` (exact ids) filtered out of `build_objects/1` (manifest only); header line generated from the list; `check_module_owned!/0` self-check wired into `--check` |
| `lib/phoenix_kit/migrations/adoption.ex`, `dev_docs/guides/2026-09-05-module-table-extraction-guide.md` | Phase 1 now says `@module_owned_ids` + drop from the manifest, not `@excluded_exact` |
| `test/integration/module_owned_manifest_test.exs` | Real `Repair.verify/1` / `repair/1` in the sandbox: FK as created, repointed, gone, and a neighbouring FK still repaired |

## Verification

- `@excluded_exact` is a refuse-to-emit guard for objects the chain no longer creates
  (`generate_baseline.exs:1056-1194`), so using it for an object the chain still creates would
  abort the generation — the PR's reason for a second list holds.
- `render_baseline/4` builds its slice from the raw `objects`, not `build_objects/1`
  (`generate_baseline.exs:1797-1816`), so the baseline still creates the FK, as the comment and
  `check_module_owned!/0` claim. `report/8` counts through `build_objects/1`, so the generation
  report matches the file that lands.
- No migration file changed → `chain_hash` stays valid; no `:revisions` tuple is needed because
  nothing was reshaped, an object was removed. The memory rule about restamping does not apply.
- The sibling `phoenix_kit_newsletters/lib/phoenix_kit/newsletters/migrations.ex` declares its
  own shape by hand (`:597`), it does not look the FK up in core's manifest, so a `nil` from
  `Enum.find/2` cannot reach `Object.newest_shape/1` there.
- Other newsletters objects (the `template_uuid` column, the other FKs) remain core's; the
  test's last case proves a neighbouring dropped FK is still reported and repaired.
- Only `test/phoenix_kit/migrations/repair/scope_test.exs` counts manifest objects, and it counts
  relative to `@objects`, so it does not pin the removal.

## Findings

No bugs.

- **NITPICK** — The hand-edited conventions header in `expected_schema.ex` (the "So are objects
  the chain creates but a module owns…" bullet, with an odd line break after "each") is not the
  text the generator emits (`"Left out:"` + list). The next regeneration rewrites the header; the
  in-place `REMOVED POST-GENERATION` comment disappears with it. Harmless (the header names the
  id either way), but a reader diffing a regeneration will see noise. Either reword the hand edit
  to the generator's wording or accept it.
- **NITPICK** — `check_module_owned!/0` runs only under `generate_baseline.exs --check`, which is
  not part of `mix precommit`; nothing in the gate fails if someone empties `@module_owned_ids`
  while the integration test still passes on the hand-edited manifest. The integration test is
  the real guard on `expected_schema.ex`; the generator side is guarded only if someone runs
  `--check`. Worth a line in the extraction guide (it already says to run the generator).
- **NITPICK** — Phase 1 now means dropping *objects* from the manifest. For a reshaped **column**
  that also stops `repair` re-creating the column if it goes missing on an install whose chain
  made it. That is the intended trade (the module owns it), but the guide's Phase 1 paragraph
  does not say so.

## Verdict

Approve as merged. The fix is minimal, the generator and the hand-edited manifest agree, and
the integration test exercises the real verify/repair path for all three FK states.

## Resolution (2.52.0)

No bugs; no code change. The three nitpicks are tooling/documentation notes and are left on record. CHANGELOG entry
added under 2.52.0 Fixed.
