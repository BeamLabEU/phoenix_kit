# PR #982 — Avatar crop gestures

**Reviewer:** Codex · **Date:** 2026-10-29 · **Baseline:** `38a116bc4`

Reviewed the merged JavaScript and the current hook-level tests. No additional defect found.

Checked that repeated pointer moves retain the frame dimensions; pinch-to-pan transitions restart from the remaining pointer; cursor zoom preserves the image point under the cursor; `pointercancel` ends the gesture; and wheel/slider changes use the existing save path. The post-merge tests already cover the original freeze, zoom geometry and the pinch transition.

## Validation

See the [batch validation record](../2026-10-29-recent-merges/CODEX_REVIEW.md).
