# PR #991 — Media selection and drag and drop

**Reviewer:** Codex · **Date:** 2026-10-29 · **Baseline:** `38a116bc4`

### BUG - MEDIUM — Shift-click reused an anchor after selection was cleared (fixed)

The document-level `rangeAnchor` survived Escape/Clear. Shift-clicking a later card could select the full old range even though nothing was selected. Before resolving an anchor, the listener now checks whether the browser has any selected cards/count; an empty selection starts at the clicked card. An executable regression demonstrates the old three-card result versus the intended single card, and a positive test preserves normal range extension.

### BUG - MEDIUM — another pointer could commit a box gesture (fixed)

Box selection attached window-wide pointer listeners but did not filter pointer IDs. A second pointer's move/up could draw and commit the first pointer's box. Move, up and cancel now act only on the pointer that started the gesture. The regression verifies that the foreign pointer leaves the original gesture active and that its own pointer can still commit it.

### BUG - MEDIUM — unfinished box selection survived browser destruction (fixed)

The active box, window listeners and document-wide `userSelect = "none"` belonged to a closure that the hook could not cancel. Navigating away during a gesture could leave text selection disabled and the overlay active until a later pointer release. The root now holds a cancellation callback; hook destruction cancels without sending a selection, removes the listeners and restores the previous inline text-selection value. Starting a replacement gesture also cancels the old one. A hook-level regression covers navigation cleanup.

### IMPROVEMENT - MEDIUM — the new selection path failed the project gate (fixed)

`mix precommit` reported four unsuppressed `call_without_opaque` warnings where the private set-returning filter fed `MapSet.union/2` and `MapSet.size/1` under Elixir 1.19/OTP 28. The filter now returns a list of allowed binary IDs and the event handler constructs its sets directly. Membership/intersection semantics are unchanged, and no Dialyzer suppression was added.

Also checked server-side rendered-ID filtering, readonly refusal, selection/additive semantics, batch move key compatibility, origin-folder suppression and OS-drop propagation to `FolderDropUpload`. The new regressions execute the shipped listeners/hook in a DOM/event harness; no real browser visual inspection was performed.

## Validation

See the [batch validation record](../2026-10-29-recent-merges/CODEX_REVIEW.md).
