# PR #904: Fix the doctor's duplicate-route warning for a repeat that leads to the same controller and action

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged
**Commit**: `9d205b7f8`, `65d72af47` (merge `129a57e4e`)
**Date**: 2026-10-04

## Goal

The doctor's "Sitemap Discoverability" check warned about every kit root path declared twice and told the
host to delete one. When both declarations reach the same controller and action, nothing differs between
the one that answers and the one that never runs, and the earlier copy can be doing a real job: a host that
declares `/sitemap.xml` ahead of its `scope "/:locale"` stops `:locale` capturing `"sitemap.xml"`. Following
the advice would break the route.

## What was changed

| File | Change |
|---|---|
| `lib/mix/tasks/phoenix_kit.doctor.ex` | `duplicate_root_route_findings/1` skips a repeat whose `plug` + `plug_opts` equal the winner's; new `same_handler?/2`, `duplicate_finding/4`, `route_label/2` (names the action when a dead declaration shares the winner's controller) |
| `test/mix/tasks/phoenix_kit_doctor_pooler_sitemap_test.exs` | Same handler reports nothing; same controller, other action is reported with the actions named; three declarations name only the differing one; a real `Phoenix.Router` with the host's early copy reports nothing |

## Verification

- `Phoenix.Router.__routes__/0` maps always carry `plug_opts` (the action atom for a controller route), and
  `router_routes/0` passes them through untouched, so the real input has the key the comparison reads.
- The comparison is against the winner only, which is the right reference: a later copy is dead exactly when
  an earlier one answers, whatever the copies between them are. `[A, A, B]` names `B` only and still counts 3;
  `[A, B, B']` names `B`/`B'` once (`Enum.uniq/1`).
- Pipelines are deliberately not compared. A dead declaration's pipeline never runs, and the winner's is the
  one that applies, so a difference there is not something to delete either.
- Ran the file on the merged tree: 19 tests, 0 failures; `mix format --check-formatted` and `credo --strict`
  on both files are clean.

## Findings

No bugs.

**NITPICK** — `route_label/2` with `with_action?` true falls back to the controller alone when `plug_opts` is
not an atom (a route to a plug with keyword options). A same-controller pair then reads "X answers it … the
declaration by X never runs", which is the confusing wording the action label exists to avoid. Not reachable
for the kit's own controller routes, which all use action atoms; worth a `inspect(plug_opts)` fallback only if
a plug route ever lands here.

**NITPICK** — the real-router test defines `DuplicateSitemapRouter` inside the test body. That works (one
run per VM) but a second run in the same VM would redefine the module; a module at the top of the file is the
safer shape.

**NOTE** — no CHANGELOG entry came with the PR. The top section is `2.52.1`, so there is no `## Unreleased`
heading to add to; the entry belongs with the next version bump (a *Fixed* bullet: the doctor no longer tells
a host to delete a duplicate sitemap route that leads to the same controller and action).

## Verdict

Approve. A narrow, well-tested fix to a finding whose advice was wrong for its commonest real cause.
