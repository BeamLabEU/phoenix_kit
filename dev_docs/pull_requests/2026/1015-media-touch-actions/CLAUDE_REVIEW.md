# PR #1015 — Fix media tile actions being hover-only on touch screens; add Move to trash to the gallery tile menu

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; nothing to fix

Tile actions in the media browser and `MediaGallery` were revealed by hover, which a touch screen does not have.
They now show on `pointer-coarse` and on keyboard focus. The gallery's remove button becomes a menu with "Remove from
selection" and a new "Move to trash", which goes through the same removal guard and dialog as the media browser.

## Checked and sound

- **A managed library is refused three times.** `Libraries.can?/3` answers false for `:edit`, `removal_plan/2` returns
  the empty plan, and `trash_file/1` starts with `check_managed/2`.
- **The plan matches the operation.** `file_removal_plan(file, nil)` says `trash` and `remove_file_from_folder(file, nil)`
  calls `trash_file/1`, so the dialog shows what happens. An already trashed file gets the empty plan and closes.
- **A forged event does nothing.** `removal_analysis/2` needs the uuid in `selected`, a live file and `can?/3`, with a
  scope built at the moment of acting, not the cached one that only draws the menu. A confirm re-reads all of it and
  compares with what the dialog showed, and a wrong token is ignored.
- **`readonly` covers the new events,** `removal_cancel` aside, which changes nothing.
- **A guard failure removes nothing.** `Removal.places/3` fails closed, and the dialog then has no confirm.
- **It is safe inside a host's `<form>`.** The menu buttons and the three `RemovalModal` buttons are all
  `type="button"`, and the modal has no `<form>` of its own, so nothing submits or nests.
- **It does not start a drag.** The eye and the menu carry `sortable-ignore`, which is the hook's `filter`.
- **`assign_scope/1` is safe without a user.** `phoenix_kit_current_user` has an `assign_new` default just above it, and
  `Scope.for_user(nil)` gives a scope that `can?/3` refuses.
- **No audit gap.** The media browser's trash writes no activity entry either, so the two match.
- **The eye and the badges do not collide in a picker.** They step aside only under `@picker`, and a picker has no select
  mode. The stack tile's `featured_badge` passes no `picker`, and it has no eye to avoid.

## Findings

### NITPICK — a readonly gallery still judges every file (left)

`assign_scope/1` builds a scope and `trashable/2` runs `Libraries.can?/3` per file even for a readonly gallery, which
shows no menu to use the result. On a file outside Media that is two small queries per file (`managed?/1`,
`get_library/1`), for a logged-in viewer. A gallery holds a handful of files and it only runs when the selection
changes, so it is left. If a host ever shows large readonly galleries, skipping both when `readonly` is true is a few
lines, with `readonly` added to `removal_scope_source` so a flip is noticed.

## Validation

No changes were made for this PR. The reveal classes were read, not seen on a touch screen.
