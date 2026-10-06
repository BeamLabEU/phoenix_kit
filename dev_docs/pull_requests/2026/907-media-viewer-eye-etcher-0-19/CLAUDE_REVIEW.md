# Claude review — PR #907 (2026-10-06)

**Verdict:** sound; no bugs found, one type nitpick fixed, two nitpicks recorded.

Scope: the media viewer's eye (hide the etchings → clean original, from the burned view or the editor),
the per-user "Open media ready to annotate" switch and the Annotation-tools section moving to the Media
tab, the retired-pastel palette fallback, `.etcher-text-editor` joining `BURN_CHROME`, and the Etcher
0.19.0 pin (`:textbox` tool).

## Traced, no finding

- **Eye state machine.** `data-burn-mode` is `burn_mode and burn_canvas != nil`, so a file with no burn on
  file (live layer, `burn_mode` true) is not mistaken for the burned picture: the hook adds the eye but
  not a second pencil next to Etcher's own. `toggle_etchings` from the editor sets `burn_mode: true`,
  `etchings_hidden: true`, so the pencil from the clean picture (`toggle_burn_mode`, `to_live? = burn_mode`)
  goes back to the editor armed, and un-hiding lands on the burned copy. `toggle_burn_mode` resets
  `etchings_hidden`, so a mode switch never leaves the clean picture stuck on.
- **Burn before swap.** The editor's eye press runs `burnIfChanged()` before `pushEventTo`, the same
  capture discipline as `_onMode` / `_onClosing`; the teardown-time `etcher:mode-changed` is a no-op
  (`burnMode` is "true" by then, and `hasBurn` guards the no-burn case).
- **Open-annotating preference.** Read from `viewer_user_prefs/1` (a fresh `Auth.get_user`), not the
  parent's possibly stale `current_user`; applied only with `can_annotate` and an image. Written through
  `merge_user_custom_fields` (never a whole-map replace), which broadcasts `phoenix_kit_user_updated`, so
  `ProfileSettings` refreshes `phoenix_kit_current_user` and a later tab mount does not show a stale switch.
- **Media tab move.** `visible?("media")` = section not hidden OR libraries card will render;
  `rendered_here?/1` no longer special-cases "media"; the libraries card keeps its own
  `Libraries.may_use_libraries?/1` gate. The tab-sections invariant test was updated with it.
- **Palette.** `nil` reaches `<Etcher.layer colors={nil}>`, which seeds its own presets; no other reader of
  the removed `@default_etcher_colors` remains.
- **Pins.** `mix.exs`, `mix.lock` and the CDN URL in `phoenix_kit.js` all say 0.19.0; no `0.18` Etcher
  reference is left outside changelogs and old reviews.
- **i18n.** The switch label and description are translated in all seven non-English catalogs; 0 fuzzy.

## NITPICK — `board_canvas` still declared `etcher_colors` as a required list — FIXED

The default is now `nil` (Etcher seeds its own palette), but `attr :etcher_colors, :list, required: true`
on the board component said otherwise. Runtime was unaffected (attr types are not enforced); changed to
`default: nil` so the declaration matches the data.

## NITPICK — eye/pencil tooltips are hardcoded English

"Hide annotations" / "Show annotations" are literals in the hook, like the existing "Annotate". The JS
bundle has no gettext path today, so this is the established limitation, not a regression. Not changed.

## NITPICK — a mid-edit burn is only as safe as the chrome list

`.etcher-text-editor` fixes the reported input-box-in-the-copy bug, and the test pins it against the real
list. A future Etcher overlay class will leak the same way until it is added to `BURN_CHROME`; the 0.19
text-box tool's editor reuses `.etcher-text-editor`, so nothing is owed for it today.

## Verification

`mix deps.get` first (the merge moved the lock to Etcher 0.19.0; `mix test` refuses on a lock mismatch).
Eye, palette, Etcher-reset and annotation-kind tests: 37 tests, 0 failures. `node --test
test/js/annotation_burn.test.cjs`: 25/25. `mix precommit` — see the release commit.
