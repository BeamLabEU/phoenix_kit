# PR #995 — Codex review

**Reviewer:** Codex · **Date:** 2026-10-30 · **Baseline:** `716bce14e` on `main`

[PR #995](https://github.com/BeamLabEU/phoenix_kit/pull/995) — Add a viewer to the media browser's picker (`timujinne`). Reviewed the merged diff and current surrounding code, including subsequent merges.

Reviewed eye-button and Select/Deselect events, read-only viewer flags and write guards, navigation, trash/unpick behavior, popover placement, Escape handling and shared JavaScript listeners.

## BUG - MEDIUM: two viewers of the same file collided (fixed)

Opening a file in a normal browser and then in a picker rendered the same MediaCanvasViewer component ID twice. A running-LiveView regression reproduced a duplicate-ID exception; the underlying canvas, burn hook, form and child component IDs also depended only on the file UUID. Production DOM patching could target the wrong viewer and share viewer state/controls.

Picker viewers now namespace their component ID and child DOM/canvas IDs by browser. Refresh notifications, annotation patch events and child comments refreshes use the same identity. Annotation popovers carry their resource UUID separately from the DOM ID. Existing normal-viewer IDs remain compatible.

The new integration regression opens the same file in both browsers, asserts unique IDs and picker-targeted controls, then closes only the picker viewer. Existing tests continue to exercise refusal of file writes in the picker. No real-browser visual inspection was performed.

## Validation

See the [batch validation record](../2026-10-30-recent-merges/CODEX_REVIEW.md). This PR is reviewed individually; validation is shared across the interacting changes.
