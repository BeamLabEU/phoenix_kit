# Claude Review — PR #1051

**Reviewer:** Claude Opus 5.5
**PR:** Add a remove-only mode to the people picker and keep a person listed under two groups (mdon)
**Reviewed:** 2026-11-20

Two narrow changes, from the boss's post-merge review of Projects #63. No panel review.

- `can_remove` opens only the `remove` event and the chip's ×, through one predicate (`removable?/1`). The `toggle`, `recent`, `me`, `query`, `open` and `browse` events still ask `can_edit`, so a crafted add is refused. The new test sends a forged `toggle`.
- `option_dom_id/1` uses the row's `:id` when it is a non-empty string, Base64-encoded behind a `row-` prefix. The key-based ids use `opt-`, so the two can never collide. A source without ids keeps the old keys.

Verification: `mix precommit`; 15 picker tests, the two new behaviours failing without the change.
