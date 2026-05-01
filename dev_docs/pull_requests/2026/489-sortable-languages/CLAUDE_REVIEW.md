# PR #489 — Sortable languages in admin

**Author:** @alexdont · **Branch:** `dev` → `dev` · **Files:** 6 (+175 / −51)

## Summary

Adds a "Reorder" toggle on the languages admin page that swaps the static badge list for a draggable `DraggableList`, with an iOS-style wiggle animation while in reorder mode. Persists the new order via a new `PhoenixKit.Modules.Languages.reorder_languages/1` that reshuffles the `languages` array inside the existing JSON setting. Extends `DraggableList` + both `phoenix_kit.js` / `phoenix_kit_sortable.js` with a `hide_source` flag that suppresses the SortableJS fallback clone on the body during drag.

## Overall verdict

**Approve with minor suggestions.** Small, focused, reuses existing infrastructure (`DraggableList`, `SortableGrid` hook, `Settings.update_json_setting_with_module/3`). No schema/migration changes. Inverse of #488 — this is what a good feature PR looks like.

## Findings

### IMPROVEMENT — MEDIUM

- **Inline `<style>` block in `languages.html.heex`** defines the `wiggle` keyframes and runs `animation: wiggle ... infinite` on every item in reorder mode. Two concerns:
  1. An infinite animation is needlessly CPU/battery hungry on mobile, even though the visual effect is subtle.
  2. Inline `<style>` in a template bypasses the project's Tailwind/daisyUI CSS pipeline. Prefer declaring the keyframes once in `assets/css/` (or as a Tailwind custom animation) and referencing via utility class, so it's scanned like the rest of the app.

  A `prefers-reduced-motion: reduce` media query around the animation would also be appropriate here.

- **`Enum.reject(&(&1["code"] in ordered_codes))`** is O(n²) against the input list. Fine for <20 languages, but converting `ordered_codes` to a `MapSet` once would be clearer and future-proof:
  ```elixir
  ordered_set = MapSet.new(ordered_codes)
  remaining = Enum.reject(current_languages, &MapSet.member?(ordered_set, &1["code"]))
  ```

- **No test for `reorder_languages/1`.** It's pure data manipulation over a settings map — a straightforward unit test would cover: reorder subset, unknown codes ignored, empty list leaves order unchanged, duplicate codes handled.

### IMPROVEMENT — LOW

- **Reorder mode hides the per-language actions** (Set Default / Disable) because it swaps the badge dropdowns for drag items. That's a reasonable modal UX with the Done button, but worth confirming it's intentional — users must exit reorder mode to change defaults.

- **`setTimeout(fn, 0)` + `document.querySelector("body > .sortable-fallback")`** in `onStart` is a brittle workaround for a SortableJS quirk. It's correctly scoped (body direct children only) and the comment explains the why, which is good. Consider adding a short inline note linking to the SortableJS issue or behavior being worked around, so future maintainers don't "clean it up."

- **Flash strings `"Language order updated"` / `"Failed to reorder languages"`** are not `gettext`-wrapped, but consistent with the rest of this file (existing flashes are also not i18n'd), so not a blocker for this PR. A follow-up to sweep all language-page flashes through `gettext` would be nice.

- **`hide_source` attr on `DraggableList`** is boolean with default `false`, forwarded as `to_string(@hide_source)` into a data attribute. The component reads it as `=== "true"` in JS. Straightforward — no issue, just noting the stringly-typed round-trip is a common place for bugs; test coverage would be welcome.

### NITPICK

- `data-sortable-hide-source={to_string(@hide_source)}` is only emitted on the container; consider not emitting it at all when `false` to keep the DOM clean. Minor.

- The "Reorder / Done" button label and the `icon-x`/`icon-check` icon swap should probably also change the button's `aria-pressed` state for screen readers in reorder mode.

- Commit history on the branch wasn't inspected; if it's a single tidy commit, no action needed.

## Recommendation

Approve. Ideal next tweaks before merge: move the `wiggle` keyframes out of the inline `<style>` tag (and respect `prefers-reduced-motion`), and add a small unit test for `reorder_languages/1`. Everything else is fine as follow-ups.
