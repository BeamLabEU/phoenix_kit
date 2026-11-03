# PR #991 — Media browser: box select, Shift-click ranges, and drag and drop that works

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve with fixes (one HIGH it made easy to reach)

Read: the `box_select` handler and `selectable_on_screen/1`/`box_uuids/2`, the gates ahead of every
handler (readonly, picker, `folder_actions`, viewer, own-files, library), the drop paths
(`move_file_to_folder`, `move_selected_to_folder`), and `startBoxSelect`/`setupBoxSelect`/`setupDragDrop` in
`priv/static/assets/phoenix_kit.js` (hand-maintained, not a build output). Codex's fixes are all present.

## Checked and sound

- **The client's box is never trusted.** `box_select` intersects what it names with what is on screen;
  it sits in `@write_events` and `@picker_off_events`; folders are dropped without `folder_actions`.
- **Every uuid in a drop is gated.** `param_uuids/2` walks nested params, so `files`/`folders` lists and the
  legacy `folder_uuid` key all reach `viewer_refused?` and `foreign_reference?`.
- **Moves go through core.** Batch drops use `move_selected_to_folder` → `Storage.move_file_between_folders`
  / `update_folder` (`check_managed`, cycle, trashed-parent and other-library refusals); nothing writes
  `folder_uuid` by hand. A folder dropped into its own descendant gets `{:error, :cycle}`.
- **JS lifecycle.** Document listeners are installed once; gesture listeners on `window` are removed in
  `finish()`; `destroyed()` cancels a box in progress and restores `userSelect`; pointer ids are filtered.

## Findings

### BUG - HIGH — the Trash view could permanently delete ACTIVE folders (fixed)
Older than #991, but #991 made it easy to reach: box select and Select all treat `@folders` as "what is
on screen". Four handlers reloaded `@folders` with `Storage.list_folders/3` (active folders) whatever view
was open — `rename_folder`, `save_folder_description`, `change_folder_color`, `save_folder_header` — while
`reload_folder_lists/1` already knew the trash and all-files views. And the trash branches of
`delete_folder` and `delete_selected_folders` called `delete_folder_completely/2` without checking that
the folder was in the trash (the file branch checks `status == "trashed"`).
Scenario: Trash → recolour a trashed folder → the grid now lists the current folder's active subfolders
with the trash's menu → "Delete" (or Select all + Delete) destroys them and every file confined to them.
**Fix:** the four handlers use `reload_folder_lists/1`; both trash branches answer `{:error, :not_trashed}`
for a folder with `trashed_at: nil` (the generic "Could not delete the folder" flash);
`selectable_on_screen/1` offers no folders in the all-files view, which renders none.
Test: `media_browser_test.exs` "the Trash view deletes for good only a folder that is in the trash".

### BUG - MEDIUM — a root search hit could no longer be dragged to Home (fixed)
`originOf()` takes a card's home from the drop zone around it. A search at the root (or a scope root)
lists the whole subtree inside the `data-drop-folder="root"` zone, so a hit from a subfolder got origin
"root" and a drop on Home or on the main area was silently suppressed (before #991 it moved the file).
**Fix:** the zone carries `data-drop-origin-unknown` while a search is active at the root, and
`originOf()` answers `null` for it.

### BUG - MEDIUM (plausible) — a box gesture survived a button release it never saw (fixed)
`onMove` never looked at `ev.buttons`, and a press on the column's own scrollbar (`overflow-auto`) started
a box; Chrome sends no `pointerup` for a scrollbar press, so moving the mouse afterwards drew a box and the
next click committed a non-additive `box_select`, replacing the selection. Not reproduced in a browser
here. **Fix:** a move with `buttons === 0` ends the gesture without selecting; a press on the area's
scrollbar region (`offsetX >= clientWidth` / `offsetY >= clientHeight`) does not start one. Two tests in
`test/js/media_selection.test.cjs`.

### IMPROVEMENT - MEDIUM — the "not on screen" test asserted nothing about it (fixed)
"A uuid that is not on screen is ignored" passed even if filtering stopped, because `elsewhere` is never
rendered. Now also asserts `#media-browser[data-selection-count='2']`.

### IMPROVEMENT - MEDIUM — a contributor's box over a mixed grid is refused whole (not changed)
`box_select` is a write event, so the own-files gate refuses the whole box if it touches one teammate's
file ("You can only change files you uploaded"), while Select all (no params) selects them. Left as is:
`toggle_select` on a teammate's file is refused the same way, so the box is consistent with the click, and
the bulk actions re-check the selection anyway. If wanted: filter `box_select` to the contributor's own
files instead of refusing.

### NITPICK — comment split from its function (fixed)
"Leave select mode and drop any selection…" sat above the new `selectable_on_screen/1`; removed there
(`exit_select_mode/1` is self-explanatory).
