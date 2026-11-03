# PR #995 — Add a viewer to the media browser's picker

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve with fixes

Codex's fix (`viewer_component_id/2` + `dom_scope` through the canvas, comments, patch pushes and burn
poke) is in place; Mistral reported nothing.

## Checked and sound

- **The eye reaches only listed files.** `view_file` resolves through `locate_file/2` (the page's lists);
  prev/next stay inside `viewer_siblings`.
- **`viewer_pick`** reuses `pick/2` → `pickable_uuids/2`; deselect only removes.
- **Writes are off in a picker**, in the markup and on the server: annotations, replies,
  `save_media_details`/`read_exif`, `fresco:rotate` are refused by `MediaCanvasViewer`.
- **Viewer trash** goes through `trash_file`, so the removal guard and every gate apply.
- **JS.** No inline script; `ViewerKeydown` keeps Escape from the host `<dialog>` only for a popover viewer.

## Findings

### IMPROVEMENT - MEDIUM — with library access revoked, the picker's viewer could not be closed (fixed)
From the later direct commit 4fe6fddd9, hitting this PR's viewer. The library-access gate refuses every
event once `library_access_allowed` is false — `close_viewer` and Escape (`viewer_keydown`) included — and
the picker viewer is a top-layer popover whose Escape is kept from the host's dialog: only a reload got
the person out. **Fix:** the refusal also closes an open viewer (`open_viewer(nil)` + `notify_viewer_nav`),
so the next event of any kind takes it away; nothing more of the library is shown. No test: it needs a DB
(membership revoked mid-session) and the test database was down for this review.

### NITPICK — "Maximum 1 files" (fixed)
The viewer badge used `gettext("Maximum %{count} files")`; the header already uses the plural pair. Now
`ngettext("Maximum %{count} file", "Maximum %{count} files", n)` (an existing msgid pair, translated), and
the viewer test asserts the singular instead of pinning the wrong text. The same one-liner remains in
`media_selector_modal.html.heex` (not this PR).

### NITPICK — folding the sidebar on a trashed file in a picker saves the preference (not changed)
The "a picker writes no preference" rule is keyed on `is_map(pick)`, and `viewer_pick_state/4` returns nil
for a trashed file, so in the picker's Trash view folding the sidebar writes `media_viewer_info_collapsed`.
Harmless (a UI preference); an explicit `picker` flag to the viewer would close it.
