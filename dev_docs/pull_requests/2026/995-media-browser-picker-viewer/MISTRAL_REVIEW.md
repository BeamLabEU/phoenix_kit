# PR #995: Add a viewer to the media browser's picker — Mistral review

**Reviewer:** Mistral · **Baseline:** `973f41b2f` on `main` (merge of #995).

## Verified sound

- The picker's `view_file` / `viewer_pick` / `pick_quick_confirm` handlers all
  take a `file-uuid` param, which the `viewer_uuid` gate checks on every
  event — a restricted viewer cannot open or pick another's file through the
  viewer. `view_file` resolves through `locate_file/2` (the page's own list),
  so a stale uuid opens nothing.
- The removal dialog renders in the top layer (`popover="manual"`) and its
  `RemovalModal` hook takes Escape/arrows in the capture phase so an open
  viewer underneath does not step or close; the viewer's own hook also
  suppresses arrow stepping while `[data-removal-state]` exists. Covered by
  `test/js/viewer_escape_layer.test.cjs`.
- `server_confirm={@removal_guarded}` is threaded into the viewer so its
  trash action goes through the #999 guard dialog instead of a client-side
  `data-confirm`.
- gettext shipped in pot + all 9 `.po` files.

## Findings

None requiring change. (Codex's review of the same PR fixed a MEDIUM
concurrent-viewers defect — duplicate viewer IDs; this pass found no further
issues.)

## Validation

`mix compile --warnings-as-errors` clean. `media_browser_picker_viewer_test.exs`
(634 lines) needs PostgreSQL, which was in recovery mode during this review.
