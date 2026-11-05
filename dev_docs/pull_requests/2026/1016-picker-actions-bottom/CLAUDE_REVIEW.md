# PR #1016 — Fix the media picker's Cancel and Confirm sitting in the header: move them to a footer under the grid

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; no findings

The picker's Cancel and Confirm, and the "Wait for the uploads to finish" notice, move from the header to a footer under
the grid, where a dialog's buttons normally are.

## Checked and sound

- **The footer stays in view.** It is a `shrink-0` sibling of the `flex-1 overflow-auto` scroll area, inside a
  `min-h-0 flex-1 flex flex-col` column, so a long folder scrolls behind it, as the comment says.
- **The strict assigns are safe.** The header read `assigns[:picker_uploading]`, the footer reads `@picker_uploading`,
  which would raise on a missing key. `media_browser.ex` gives both `picker` and `picker_uploading` an `assign_new`
  default, so neither can be absent.
- **Nothing still passes the old attribute.** `picker_uploading` is gone from the header call and the header template, and
  no asset or test names the old position.
- **The uploading rule is kept.** Both buttons stay `disabled={@picker_uploading}`, with the same events and target.
- **The string is unchanged,** so its translations carry over.
- **The test checks the move,** not only the buttons: it requires them in `#pick-picker-actions` and refuses them in
  `#pick-picker-bar`.

## Validation

No changes were made for this PR. The footer's position is read from the markup, not seen in a browser.
