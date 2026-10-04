# PR #893: Add Layout.render_parts/2 — the email header and footer on their own

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged
**Commit**: `9a5c5c94b`, `dbda7b993` (merge `51c4a6527`)
**Date**: 2026-10-03

## Goal

A module that builds its own document (a newsletter wrapper) could not show the site's
header and footer: the pieces were private to `Layout.render/3`. `render_parts/2` exposes
them, chosen by the same code.

## What was changed

| File | Change |
|---|---|
| `lib/phoenix_kit/email/layout.ex` | `render/3` split into `options/1` + `parts/3` (shared) + the layout step; new public `render_parts/2` and `t:parts/0` |
| `guides/email-templates.md` | "Using the header and footer in your own document" |
| `test/phoenix_kit/email/layout_test.exs`, `layout_render_parts_paths_test.exs` | group / locale / blank-file / branding / escaping cases; the `:paths` default |

The second commit fixes the first: without `:paths`, `render_parts/2` read **no** override
roots, so a module copying the documented call got core's parts instead of the host's.
It now defaults to `Content.override_paths/0`, as `Content.resolve/5` does; `paths: []`
still means core only.

## Verification

- Compared `render/3` before and after: the refactor moves the resolution into `parts/3`
  unchanged; `render/3` still defaults `:paths` to `[]`, and its `sources` (header/footer
  reported only when the layout places them) are computed from the same values. The
  existing `render/3` tests pass untouched, and `layout_render_parts_paths_test` pins the
  deliberate asymmetry (`render/3` no roots, `render_parts/2` the host's).
- `Keyword.get(opts, :paths) || override_paths()`: `[]` is truthy in Elixir, so
  `paths: []` is honoured and only `nil`/absent falls through. Correct.
- `Layout` now calls `Content.override_paths/0` while `Content` calls `Layout.render/3`:
  a runtime reference both ways, no compile-time cycle (the tree compiles with
  warnings-as-errors).
- The guide's claims were checked against the code: the choice order (group file, shared,
  core), blank file = missing, the raw-text status of `parts.variables`, and `escape: true`.

## Findings

No bugs. No code changes needed.

- **NITPICK** — `render_parts/2` and `render/3` default `:paths` differently. Deliberate and
  documented in both docs and tested; a reader of only `render/3`'s doc could still be
  surprised, hence the guide's explicit sentence.

## Verdict

Approve as merged. The follow-up commit closed the one real gap (the host's templates were
ignored by default), and the shared-code design means a wrapped email and a custom document
cannot choose different parts.
