# PR #994: Add a picker mode to the media browser — Mistral review

**Reviewer:** Mistral · **Baseline:** `442f561fd` on `main` (merge of #994).

## Verified sound

- Pick state is server-side (`picked`, `pick_limit_hit`); `pick/2` only accepts
  files the picker lists (`pickable?/2`), and `confirm_pick/1` re-filters
  through `pickable_uuids/2` before reporting to the host.
- The `viewer_uuid` gate runs before every event, so a restricted viewer
  cannot pick (or even name) another's file via `click_file` /
  `viewer_pick` / `pick_quick_confirm` — the param uuids are checked for all
  events, and the picked list can only contain files that passed the gate.
- Pickers delete nothing for good: `delete_file` refuses the permanent
  branch for `picker: true` regardless of view, and #999's removal analysis
  mirrors that with `:pass`.
- Pick confirm/cancel are refused while an upload is in flight, both in the
  template (disabled) and in the handler.
- gettext shipped in pot + all 9 `.po` files; JS hooks covered by
  `test/js/media_pick.test.cjs` and `instant_viewer.test.cjs`.

## Findings

None requiring change. (Codex's review of the same PR fixed a MEDIUM picker
confirmation defect; this pass found no further issues in the pick flow.)

## Validation

`mix compile --warnings-as-errors` clean. Picker integration tests
(`media_browser_picker_test.exs`, 1460 lines) need PostgreSQL, which was in
recovery mode during this review.
