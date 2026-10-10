# Claude review — PR #922 (2026-10-10): Fit the media viewer's controls to a small screen, swipe between files, and a per-user "Invert two-finger pan" switch

- **Author:** @alexdont · merged as `48f449ba9` · `feat/invert-two-finger-pan` → `main`
- **Files:** 19 — `media_canvas_viewer.{ex,html.heex}`, `user_settings.ex`, `mix.exs`/`mix.lock`
  (fresco → 0.13.3, etcher → 0.21.0), `priv/static/assets/phoenix_kit.js` (`ViewerSwipe` hook, eye/pencil slots),
  nine gettext catalogues, three test files.
- **Verdict:** **APPROVE with one fix** (a missing `uk` translation, fixed in 2.60.2).

## Scope

Per-user `media_viewer_invert_two_finger_pan` flag (profile settings toggle → `Auth.merge_user_custom_fields/3`,
read at viewer-open and handed to every Fresco canvas); a short Fresco nav row (`nav_layout: :row`,
`nav_overflow`, `nav_reverse`) with the Etcher style-panel switch in the row (`panel_toggle: :nav`); prev/next
become edge tabs; `ViewerSwipe` steps files on a one-finger swipe of a fitted picture.

## Verified

- **Settings write** merges one key (`merge_user_custom_fields/3`, not a whole-map replace), matching the
  open-annotating switch; the reset-annotation-tools handler leaves it alone (tested).
- **Every canvas carries the flag** — plain, burned and live layer, and the board canvas — so the direction cannot
  change under the user when the eye or pencil remounts a canvas (tested for three render states).
- **`ViewerSwipe`** reads `data-has-prev`/`data-has-next` at event time, so LiveView patches keep it current; the
  listener is on the pane (survives canvas remounts) and is removed in `destroyed/0`. The skip-while-annotating guard
  uses `.etcher-pencil-active`, which Etcher 0.21 does set (`etcher.js:9094`); `fresco:swipe` is dispatched
  bubbling by Fresco 0.13.3 (`fresco.js:1481`).
- **`pane_style/2`** — `@viewer_only` is always assigned (`media_canvas_viewer.ex:197,302`); a `nil` aspect yields
  only the reserve property.
- **Dependency floors** match the code that needs them (`panel_toggle`, `nav_*`, `fresco:swipe`) and the lock agrees.
- **Gettext:** 0 fuzzy introduced; the new strings are filled in every locale except `uk`.

## Findings

1. **BUG - MEDIUM (fixed):** the two new msgids — "Invert two-finger pan" and its description — were empty in
   `priv/gettext/uk`, so Ukrainian users saw English on a settings page whose siblings are translated. Filled in.
2. **NITPICK (left):** `{:fresco, "~> 0.13.3"}` drops the older Fresco lines the previous pin admitted. Deliberate
   and documented in the `mix.exs` comment (older Fresco only warns on undeclared attrs and keeps the old column),
   and core, not a module package, so the "never narrow" rule does not apply.
3. **NITPICK (left):** the swipe guard queries the DOM for a class owned by Etcher. It is a stable public class;
   a pencil state event would be tidier but is not worth a cross-package change.
