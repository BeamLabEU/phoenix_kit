# PR #900 — GPT release recheck

Reviewed the published 2.52.0 tag (`72c9b8127`) against 2.51.0, including the restored no-email state.

No additional defect found. The sent-email copy and relative timestamp render only when `confirmation_sent_at` exists. Otherwise the screen instructs the user to resend, instead of claiming delivery. The existing actions and navigation remain intact. Both states are covered by the auth-flow integration test, and the restored string is present in all eight locale catalogs.

See the [complete release recheck](../../../reviews/2026-10-04-2.52.0-release/GPT_REVIEW.md) for validation and package provenance.
