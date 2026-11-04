# PR #1010 — Add allow_move, subtree_toggle and per_page to the media browser's picker

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; no bugs, two nitpicks left open

Drag the pick to a folder (`allow_move`, `move_picked_to_folder`), an "Include subfolders" switch
(`subtree_toggle`, `list_files_in_scope/2 :subtree`), a page size (`per_page`), events mode on
`pagination_controls`, and bulk `appearances/2` and `folder_name_chains/1` for every browser.

## Checked and sound

The new event sits behind the browser's event gates, so each gate was read:

- **A restricted viewer.** `viewer_refused?/3` walks every value in `params` with `param_uuids/2`, so
  the `"folder-uuid"` of `move_picked_to_folder` is covered with no list to update. An invisible target
  is refused before the handler runs.
- **`own_files_only`.** `move_file_to_folder` and `move_picked_to_folder` are both in `@write_events`.
  The single move is refused by the gate. The batch names no file, so `picked_files_to_move/1` filters
  it, which is where it has to happen.
- **A managed library.** `force_managed_readonly/1` covers the page, and `move_file_between_folders/5`
  starts with `Libraries.check_managed/2`.
- **Another library.** `foreign_reference?/2` refuses what the event names, and `pick_move_target/3`
  checks again.
- **`folder_actions: false`.** The exception is exactly `@picker_move_events` and only with `allow_move`
  true, and `allow_move` is normalised to false outside a picker.

Then the claims about the rest of the browser:

- **`appearances/2` gives the old answer.** Candidates are tried in the same order, each one by home or
  link as before, and a file homed in the first candidate costs no query.
- **A nil `from` does not crash.** On a search at the root `appearance_folder/2` is nil for a card that
  has a home, and `folder_link(nil, _)` has a fallback clause, so `move_linked_file/5` falls through to
  `move_file_to_folder/4`.
- **`folder_name_chains/1` matches `folder_breadcrumbs/2`.** Same 50-level cut, same stop at a missing
  ancestor, and a parent loop ends because a known folder is not walked again.
- **`:subtree` with no folder needs no trash walk.** `do_trash_folder/1` trashes the files too, so
  `status != "trashed"` already hides them.
- **The CTE is safe on a named schema.** It uses `TreeQuery`'s pattern: schema-prefixed `Folder` sources
  and a bare CTE name.
- **Stack previews ignore the switch.** `assign_stacks/1` passes `subtree: true` through `list_extra/1`,
  but only in stacks view, which a picker never shows.
- **`card_origin/3` cannot miss `folder_uuid`.** Every map in `@uploaded_files` comes from
  `enrich_files/1`, which now carries it.

## Findings

### NITPICK — the switch does not tell a controlled host about the page (not fixed)

`set_subtree_view` resets `current_page` to 1 locally and sends no `{:navigate, _}`, so a host's URL keeps
`page=N` until the next navigation. It heals itself: `set_page` and `notify_viewer_nav/1` both send the
socket's own page. The only visible effect is a refresh landing on page N with the switch off, which is
what the switch's documented "starts off on every mount" gives anyway.

### NITPICK — a card in a picker's Trash view is draggable but refused (not fixed)

With `allow_move` and `folder_actions` on, the Trash view's cards carry `data-draggable-file`, and a drop
ends in `pickable_file/2`'s refusal and "Failed to move file". The refusal is correct, and Restore is on
the card. Not worth another attr on the grid.
