# PR #1027 — Fix MediaDragDrop with two hooks on a page, and on rows LiveView reuses

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve; one improvement fixed, one nitpick left on record

Two fixes in the `MediaDragDrop` hook (`priv/static/assets/phoenix_kit.js`):

1. **Per-instance drop handlers.** Drop targets (`data-drop-folder`, `data-drop-trash`) are found across the whole
   document, so two hooks on one page wired the same elements under one shared `target._drop`; the last hook set up
   won and a drag started in any other hook was dropped (its `_internalDrag` was false in the hook that answered).
   Each instance now keys its handlers under its own `slot` (`_pkDrop<N>_`), every handler answers only to drags of
   its own instance, and `destroyed()` takes them off again.
2. **Rows patched in place.** LiveView reuses a `<tr>` that showed a folder to show a file after a navigation; the
   folder `dragstart` stayed wired and sent the file's drag as a folder move. Each setup now records what it wired
   (`_wiredDrag`) and unwires what is no longer wired the same way.

Checked and fine: several listeners on one element all run whatever `stopPropagation()` does, so the owning hook's
drop handler runs whichever was added first, and the others return early on `!self._internalDrag`. The trash
`dragover` now declines drags of other hooks (and from the computer); LiveView's own window-level `dragover`/`drop`
`preventDefault` keeps a file dropped there from opening in the tab. A drag of hook A dropped on hook B's folder
still pushes to A (as before) — that is the intended cross-panel move. The test (`test/js/media_drag_drop_instances.test.cjs`)
drives the real hook source in a VM.

## Findings

### IMPROVEMENT - MEDIUM — a drop target patched into something else kept this hook's handlers (fixed)

The in-place reuse the PR fixes for draggables applies to drop targets too: a folder row carries `data-drop-folder`,
and after a navigation the same `<tr>` can show a file without it. Its `slot + "dragover"` handler stayed, so the
file row lit up with the folder outline (nothing in `declines/1` refers to the attribute being gone) and its drop
handler called `preventDefault()` + `stopPropagation()` before finding no `dropFolder` — the drop was swallowed and
the zone around it never saw it. `destroyed()` also only reached targets that still carried the attribute.

Fixed: setup records the targets it wired (`_wiredFolderTargets`, `_wiredTrashTargets`) and unwires, per kind, the
ones not found this time; `destroyed()` unwires those sets as well as the current targets. Shared helper
`unwireDropTarget/3`. Test added: "a drop target that is no longer one keeps no handler".

### NITPICK — `setupLongPress` has the same in-place reuse shape (not fixed)

The long-press closure captures `type`/`uuid` at setup and is rewired only for elements that are still draggable. A
row that stops being a file/folder card entirely keeps a long-press that selects its old uuid. In practice listing
rows are always file or folder cards (both rewired every update), so this stays on record rather than adding
another tracking set.
