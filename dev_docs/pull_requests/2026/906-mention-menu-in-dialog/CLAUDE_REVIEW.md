# Claude review — PR #906 (2026-10-05)

**Verdict:** sound; one bug fixed, two risks recorded.

Scope: `RowMenu` / `MentionInput` portal into an open `<dialog>` as a manual popover, the
`charBox` mirror for caret placement, and `data-mention-context` → `Mentions.search/3` `:context`.

## BUG - MEDIUM — `RowMenu` armed the popover once, in `mounted()` — FIXED

`popover="manual"` and the `inset`/`margin` resets were set on the server-rendered `<ul>` once. The
template renders none of them, and the patcher strips attributes the server did not render, so any patch
of the row while the menu was closed removed them. The next `_open()` then called `showPopover()` on an
element with no `popover` attribute, which throws `NotSupportedError` after `hidden` had already been
removed: an unpositioned menu stuck on screen, `isOpen` false, no listeners. It hit every row menu on
every page (a PubSub refresh of a table is enough), not only those in dialogs.

Fix: `_armPopover()` re-applies the attribute and resets on every `_open()`. `row_menu_dialog.test.cjs`
gained a test that strips the attribute and makes `showPopover()` throw like the browser; it fails
without the fix. (`MentionInput` is unaffected — its menu is built in JS, outside the server's markup.)

## BUG - MEDIUM — open row menu inside a patched dialog — FIXED in 2.54.2 (was "unverified")

While open, the menu is now a direct child of the `<dialog>`, which sits inside the LiveView container
(the old `<body>` portal did not). A patch of that dialog may morph the keyed `-content` `<ul>` back into
its wrapper, closing the popover; `updated()` only handles the duplicate case. Needs a real browser to
confirm, which this sandbox does not have — not changed on speculation. Worth a check in the projects
popup: open a row menu while another client edits the dialog's list.

**Update:** confirmed in Chromium by the independent review (`GPT_REVIEW.md`): the patch moves the same
`<ul>` back into its row, hidden and without the popover attribute, while `isOpen` stays true — the next
trigger click closes what is not showing. Fixed: `updated()` now detects a reclaimed open menu
(`_reclaimed()`) and re-runs the portal/arm/show/place step (`_present(this._at)`, split out of `_open`);
`_portal()` also treats a `:modal` dialog as open, since a patch strips `open` until `PkDialog` restores
it. Three tests in `row_menu_dialog.test.cjs`. The unit tests model the reclaim over stubs; the browser
re-check of this fix is still owed (the reviewer's Chromium harness is the way).

## NITPICK — `charBox` mirror ignores the textarea's scrollbar

The mirror is `overflow: hidden` at the field's full width, so a textarea with a vertical scrollbar wraps
earlier than the mirror and the menu can sit a line off on long text. Cosmetic.

## Checked, no finding

- `Mentions.Live.context/1` accepts only a map; the docs say context narrows and never grants. `Users.search/2`
  ignores the extra opt.
- `MentionInput` observer: guards on `active`, the host and `isConnected`; torn down in `destroyed()`.
- No schema, migration or settings change.

## Verification

`node --test test/js/row_menu_dialog.test.cjs` 5/5 (4/5 without the fix). `mix precommit` — see the release commit.
