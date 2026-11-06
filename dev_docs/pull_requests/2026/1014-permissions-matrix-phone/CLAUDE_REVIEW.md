# PR #1014 — Fix the permissions matrix being uneditable on a phone

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; nothing to fix

On a phone the pinned first column could fill the screen and cover the toggles, and the toggles were too small to
press. Below `md` the column is now capped at `40vw` with wrapping labels and an opaque background, and each toggle
is a 44px target. From `md` up the column is what it was.

## Checked and sound

- **All three first-column cells move together.** `first_col_class/2` is used by the header, the permission rows and
  the summary row, so they cannot drift apart. The header passes `max-md:bg-primary`, as it sits on the primary bar.
- **The section rows did not need it.** The five other `sticky left-0` cells (`Full Access` and the group headings)
  have `colspan={length(@roles) + 1}`, so they span the table and have nothing to cover.
- **A list is a safe `class`.** `table_default_header_cell` renders `class={@class}`, which flattens the nested list.
- **A wrapped or clipped label stays readable.** `title={@label}` carries the full text.
- **Nothing changes behind the toggle.** `phx-click`, `phx-value-*` and the permission check are untouched.

## Findings

### NITPICK — the pinned cell does not stripe on a phone (left)

The table is `variant="zebra"`, while the pinned cell is `max-md:bg-base-100` on every row, so on an even row the first
column stays a shade lighter than the rest. It has to be opaque, and matching the stripe would need a per-row
background. Cosmetic, so it is left.

## Validation

No changes were made for this PR. The test pins the classes, not the layout, and this review did not open the page
on a phone or in a browser, so the 40vw column and the 44px targets are read from the code, not seen.
