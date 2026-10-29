# PR #988 — Linked copies and managed libraries

**Reviewer:** Codex · **Date:** 2026-10-29 · **Baseline:** `38a116bc4`

Reviewed library listing/access rules, managed checks, copy/relink conditions, variant sharing and cleanup, and the browser/viewer/controller write boundaries. No additional change applied.

Checked original-byte stability under donor row/directory locks; matching storage profile and variant specifications; exclusion of burned/annotated variants; fresh keys for prepared variants; reference-aware object cleanup; refusal values that preserve the caller's transaction; and relink's post-commit deletion requirement. Managed libraries force the media UI read-only and refuse user edits before owner/admin branches. The owning module's explicit `managed: :owner` path remains available where documented.

### Existing API limitation retained

As the earlier review records, `link_copy/3` checks a managed donor leaving its library but permits creation into a managed destination without `managed: :owner`, including a copy inside the same managed library. This is an ingestion API whose caller owns access checks, like storing a new upload; it is not exposed as a Media write event. The Inbox consumer uses that allowance and falls back to a full upload on refusal. Tightening only core would disable its linked-copy optimization without closing a demonstrated browser bypass, so this review preserves the existing contract and records the distinction explicitly. A future contract change must update the module consumer and its tests together.

## Validation

See the [batch validation record](../2026-10-29-recent-merges/CODEX_REVIEW.md).
