# PR #1051: Add a remove-only mode to the people picker and keep a person listed under two groups — Mistral review

**Reviewer:** Mistral · **Baseline:** `1fb32a56d` on `main` (merge of #1051) · **Date:** 2026-11-20

## What the PR does

- `can_remove`: with `can_edit` false, a chip's × still removes it; no one can
  be added. All other events (`toggle`, `recent`, `me`, `query`, `open`,
  `browse`, `confirm`) still require `can_edit`, so a crafted add is refused —
  the PR's own test sends a forged `toggle`.
- `option_dom_id/1` keys a stream row on the source row's own `:id` when it is
  a non-empty string (`row-` + Base64), else on the encoded key (`opt-` + …),
  so a person matching a search under two teams renders in both rows instead
  of the second replacing the first. `PeoplePicker.Source` documents the
  `:id` row field.

## Verified sound

- The guard split is complete: every write path except `remove` checks
  `can_edit`; `remove` checks `removable?/1` (`can_edit or can_remove`) AND
  that the key is actually selected. Verified by reading each `handle_event`
  clause.
- The two `opt-`/`row-` namespaces cannot collide with each other; the
  key-based encoding still prevents the `("team-a","b")` / `("team","a-b")`
  dash collision.
- Ran the suite on the PR head: 15 tests, 0 failures. Swapped main's lib files
  back in under the PR's tests: exactly the two new behaviour tests fail
  (the `can_remove` removal, and "Twice in Kitchen" vanishing from the
  stream), so the tests genuinely lock the fixes.
- No other core callers of `PeoplePicker`; the change is additive
  (`can_remove` defaults to false, `removable?` ORs with `can_edit`, so
  existing `can_edit`-only callers behave identically).

## Findings and fixes applied on main (follow-up commit)

### NITPICK — the chip's `can_edit` attr now meant "removable" — fixed

`render/1` passed `can_edit={removable?(assigns)}` into the private `chip`,
whose `can_edit` only gates the × button. Worked, but the name lied. Renamed
the chip attr to `removable` (one private component, one call site).

### IMPROVEMENT — the home list could still give two rows one DOM id — fixed

The PR fixed the options stream, but the home view keyed its `<li>`s on
`kind-uuid` only, so a source listing the same key under two groups on the
home page (exactly the "person under two teams" case the PR title names)
still produced duplicate DOM ids — invalid HTML, and ambiguous for any
`element("#…-home-…")` selector. Added `home_dom_id/1`: a row with its own
`:id` gets the `row-` id, rows without one keep the old `kind-uuid` form, so
existing ids are unchanged for sources that do not opt in. Locked by a new
test (a member row with an `id` under the Teams group plus p1 in People —
both `<li>`s asserted by their distinct ids; it fails without the fix).

### NITPICK — doc wording — fixed

"Defaults to `can_edit`" described the effective predicate, not the assign
(default `false`); reworded to "Default false; with `can_edit` true a chip is
always removable", and the `can_edit` bullet now points at `can_remove`.

## Deliberately not changed

- `listed` (and `rows`) stay keyed on `{kind, uuid}`, so with two rows of one
  key, `refresh_rows/2` re-inserts only the last-listed copy when the pick's
  tick moves — the other row's `aria-selected` can lag until the list
  reloads. Cosmetic, edge-case; changing the keying ripples through
  `load_page`/`refresh_rows` for no user-visible gain.
- Home-list `<li>`s for key-only rows keep the unencoded `kind-uuid` id
  (dash-collision-proofing there would change existing ids for every caller).

## Gate

`mix format` clean; `people_picker_test.exs` 16 tests, 0 failures; full
`mix precommit` + `mix test` results recorded in the sweep report.
