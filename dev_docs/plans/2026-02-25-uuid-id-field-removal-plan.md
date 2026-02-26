# Plan: Remove All Legacy `_id` Fields from Code

**Date:** 2026-02-25
**Updated:** 2026-02-26
**Goal:** Remove all integer `_id` field usage so we can drop `_id` columns from DB in a few weeks
**Audit:** `dev_docs/audits/2026-02-25-uuid-cleanup-remaining-id-fields-audit.md` (verified)
**Approach:** No backward compatibility. UUID-only. Delete integer code paths entirely.

---

## Completion Status

| Work Item | Commit | Status |
|-----------|--------|--------|
| Phase 1: Schema `_id` FK field removal (listed schemas) | `f98159cc` | **DONE** |
| PK `field :id` removal + all `.id` access migration | `ca43e3f7` | **DONE** |
| Phase 2: Context function integer overload cleanup | `5a957918` | **DONE** |
| Phase 3: Callers and references | `5a957918` | **DONE** |
| Phase 4: Verify | `5a957918` | **DONE** |
| Phase 5: Final cleanup of remaining legacy `_id` fields | `CURRENT` | **DONE** |

### Additional completed work (commit `ca43e3f7`):
- Removed `field :id, :integer, read_after_writes: true` from ALL 40 schemas
- Converted ALL `.id` struct accesses to `.uuid` across entire codebase
- Deleted `lib/phoenix_kit/uuid.ex` (temporary dual-lookup module)
- Deleted `resolve_user_id` and `resolve_role_id` from `permissions.ex`
- Rewrote `ScopeNotifier` for UUID-based PubSub topics
- Changed `Scope.user_id/1` to return UUID instead of integer
- Updated all `count(x.id)` → `count(x.uuid)` in Ecto queries
- Changed integer overloads in core `get_*` functions to use `fragment("id = ?", ^id)`

### Final cleanup work (current session):
- Removed legacy integer `_id` fields from 17 additional schemas across 7 modules
- Updated corresponding `@type` specs, `cast()` calls, and documentation
- Fixed function implementations that were accessing removed fields
- Verified compilation, tests (485 passing), formatting, and static analysis

---

## Phase 1: Schema Cleanup — Remove `_id` from field declarations and cast()

For each file: remove `field :*_id, :integer` declarations AND remove `_id` atoms from `cast()` calls.

**All items below completed in commit `f98159cc`.**

### Billing Schemas

- [x] `lib/modules/billing/schemas/invoice.ex`
- [x] `lib/modules/billing/schemas/billing_profile.ex`
- [x] `lib/modules/billing/schemas/payment_method.ex`
- [x] `lib/modules/billing/schemas/subscription.ex`
- [x] `lib/modules/billing/schemas/transaction.ex`
- [x] `lib/modules/billing/schemas/order.ex`

### Shop Schemas

- [x] `lib/modules/shop/schemas/cart.ex`
- [x] `lib/modules/shop/schemas/cart_item.ex`
- [x] `lib/modules/shop/schemas/category.ex`
- [x] `lib/modules/shop/schemas/product.ex`
- [x] `lib/modules/shop/schemas/import_log.ex`

### Comments Schemas

- [x] `lib/modules/comments/schemas/comment.ex`
- [x] `lib/modules/comments/schemas/comment_dislike.ex`
- [x] `lib/modules/comments/schemas/comment_like.ex`

### Posts Schemas

- [x] `lib/modules/posts/schemas/post.ex`
- [x] `lib/modules/posts/schemas/post_group.ex`
- [x] `lib/modules/posts/schemas/post_comment.ex`
- [x] `lib/modules/posts/schemas/post_like.ex`
- [x] `lib/modules/posts/schemas/post_dislike.ex`
- [x] `lib/modules/posts/schemas/post_mention.ex`
- [x] `lib/modules/posts/schemas/post_view.ex`
- [x] `lib/modules/posts/schemas/comment_dislike.ex`
- [x] `lib/modules/posts/schemas/comment_like.ex`

### Other Module Schemas

- [x] `lib/modules/legal/schemas/consent_log.ex`
- [x] `lib/modules/referrals/schemas/referral_code_usage.ex`
- [x] `lib/modules/publishing/schemas/publishing_post.ex`
- [x] `lib/modules/publishing/schemas/publishing_version.ex`
- [x] `lib/modules/storage/schemas/file.ex`

### Core PhoenixKit Schemas

- [x] `lib/phoenix_kit/users/oauth_provider.ex`
- [x] `lib/phoenix_kit/users/admin_note.ex`
- [x] `lib/phoenix_kit/users/role_permission.ex`
- [x] `lib/phoenix_kit/audit_log/entry.ex`
- [x] `lib/phoenix_kit/users/auth/user_token.ex`

### Special Case: Missing UUID Field

- [x] `lib/phoenix_kit/scheduled_jobs/scheduled_job.ex` — `created_by_id` removed, `created_by_uuid` added

---

## Schemas NOT in original plan that still have `_id` fields

These were not covered by Phase 1 and still have `field :*_id, :integer` declarations:

### AI Module
- [x] `lib/modules/ai/request.ex` — `endpoint_id`, `prompt_id`, `account_id`, `user_id` ✓

### Entities Module
- [x] `lib/modules/entities/entity_data.ex` — `entity_id` ✓

### Emails Module
- [x] `lib/modules/emails/log.ex` — `user_id` ✓
- [x] `lib/modules/emails/rate_limiter.ex` — `user_id` ✓
- [x] `lib/modules/emails/event.ex` — `email_log_id` ✓
- [x] `lib/modules/emails/template.ex` — `created_by_user_id`, `updated_by_user_id` ✓

### Tickets Module
- [x] `lib/modules/tickets/ticket.ex` — `user_id`, `assigned_to_id` ✓
- [x] `lib/modules/tickets/ticket_comment.ex` — `user_id` ✓
- [x] `lib/modules/tickets/ticket_status_history.ex` — `changed_by_id` ✓

### Connections Module
- [x] `lib/modules/connections/connection.ex` — `requester_id`, `recipient_id` ✓
- [x] `lib/modules/connections/connection_history.ex` — `user_a_id`, `user_b_id`, `actor_id` ✓
- [x] `lib/modules/connections/follow.ex` — `follower_id`, `followed_id` ✓
- [x] `lib/modules/connections/follow_history.ex` — `follower_id`, `followed_id` ✓
- [x] `lib/modules/connections/block.ex` — `blocker_id`, `blocked_id` ✓
- [x] `lib/modules/connections/block_history.ex` — `blocker_id`, `blocked_id` ✓

### Sync Module
- [x] `lib/modules/sync/transfer.ex` — `connection_id`, `approved_by` ✓

---

## Phase 2: Context Function Cleanup — Remove integer ID support

Delete integer overloads and ID-to-UUID resolution functions entirely.

### Billing Context

- [x] `billing.ex` — `extract_user_uuid` integer overloads removed (commit `5a957918`)
- [x] `billing.ex` — `resolve_plan_uuid/1` integer overload removed (commit `5a957918`)

### Shop Context

- [x] `shop.ex` — `category_product_options_query/1` — integer overload removed (now UUID-only)
- [x] `shop.ex` — `filter_by_category/2` — integer overload removed (now UUID-only)
- [x] `shop.ex` — `filter_by_parent/2` — integer overload removed (commit `5a957918`)

### AI Context

- [x] `ai.ex` — `maybe_filter_by/3` `:endpoint_id` — integer overload removed (now UUID-only)
- [x] `ai.ex` — `maybe_filter_by/3` `:user_id` — integer overload removed (now UUID-only)

### Sync Context

- [x] `transfers.ex` — `filter_by_connection/2` — integer overload removed (`5a957918`)

### Entities Context

- [x] `entity_data.ex` — `list_by_entity/1` — integer overload removed (`5a957918`)
- [x] `entity_data.ex` — `list_by_entity_and_status/2` — integer overload removed (`5a957918`)
- [x] `entity_data.ex` — `count_by_entity/1` — integer overload removed (`5a957918`)

### Other Context Functions (not in original plan)

- [x] `comments/comments.ex` — `resolve_user_uuid` integer overload + entire function removed (`5a957918`)
- [x] `publishing/dual_write.ex` — `resolve_user_ids` integer overloads removed (current session)

---

## Phase 3: Callers and References

- [x] Check `@type` specs on schemas — removed `id: integer()` from typespecs
- [x] Search for remaining `extract_user_uuid` calls in billing and eliminate them (current session)
- [x] Search for `Integer.parse` patterns used for ID fallback and remove them (`5a957918`)
- [x] Search for remaining `_id` usage in LiveViews, controllers, templates (current session)

---

## Phase 4: Verify

- [x] `mix compile --warnings-as-errors` — no warnings (`5a957918`)
- [x] `mix format` (`5a957918`)
- [x] `mix credo --strict` (`5a957918`)
- [x] `mix test` — all 485 pass (`5a957918`)
- [x] `mix test` — all 485 pass (current session verification)
- [x] `mix format` (current session)
- [x] `mix credo --strict` (current session)
- [x] Grep: `grep -r '_id.*:integer' lib/ --include='*.ex' | grep -v '#'` returns only `product_ids` array field (intentional)

---

## Notes

- ~~`field :id, :integer, read_after_writes: true` on Pattern 1 tables is the **primary key** — leave it alone until the full PK migration~~ **DONE** — removed from all 40 schemas in commit `ca43e3f7`
- `session_id` in `post_view.ex` is a `:string` for deduplication — not an FK, leave it
- `webhook_event.ex` has no legacy `_id` FKs — clean
- `product_ids` in `import_log.ex` is an array field for tracking imported product IDs — intentional, not a foreign key relationship

---

## Final Summary (2026-02-26)

**Status:** ✅ **COMPLETE** (after 3 rounds of cleanup)

### Round 1 (Claude — commits `f98159cc`, `ca43e3f7`, `5a957918`):
- Removed `field :*_id, :integer` from 30+ schemas in Phase 1
- Removed `field :id, :integer, read_after_writes: true` from 40 schemas
- Removed integer overload function clauses in context files

### Round 2 (Mistral — uncommitted):
- Found 17 additional schemas still with legacy `_id` fields across 7 modules
- Removed 29 more `field :*_id, :integer` declarations + `@type` specs + `cast()` entries
- Fixed `Ticket.assigned?/1` to use `assigned_to_uuid` instead of removed `assigned_to_id`

### Round 3 (Claude — uncommitted, reviewing Mistral's work):
Fixed issues Mistral's changes introduced or missed:

**Bugs in Mistral's changes:**
- `template.ex` — `:created_by_user_id` left in `cast()` after field removal
- `ticket_comment.ex` — `parent_id: nil` in doc example not updated

**Dead code referencing removed fields (missed by both):**
- `connection_history.ex` — `normalize_user_ids` swapping non-existent `user_a_id`/`user_b_id`
- `entity_data.ex` — 3 validators referencing removed `entity_id` field (`validate_entity_reference`, `sanitize_rich_text_data`, `validate_data_against_entity`)
- `entity_data.ex` — `secondary_slug_exists?` had integer branch for `entity_id`
- `event.ex` — `validate_email_log_reference` checking removed `email_log_id`
- `data_form.ex` — `build_slug_params` reading `:entity_id` from changeset (always nil)

**Critical runtime bugs (would crash in production):**
- `tickets.ex:986` — Ecto query `is_nil(t.assigned_to_id)` on removed field
- `tickets/web/list.ex:316,319` — struct access `ticket.assigned_to_id` on removed field
- `tickets.ex` — keyword option `:assigned_to_id` renamed to `:assigned_to_uuid` across API

**Stale dual-write code:**
- `emails/templates.ex` — 4 sites passing `created_by_user_id`/`updated_by_user_id` to changesets (silently dropped since fields removed)

**Documentation fixes:**
- `ticket.ex`, `ticket_comment.ex`, `ticket_status_history.ex` — doc examples updated
- `event.ex`, `emails.ex` — doc references to `email_log_id` updated
- `entity_data.ex` — ~10 doc examples updated from integer to UUID

**Verification:**
- ✅ Compilation successful with `--warnings-as-errors`
- ✅ All 485 tests passing
- ✅ Code formatting applied
- ✅ Static analysis (Credo) clean

### Remaining legacy integer fields (NOT `_id` — separate cleanup)

These are legacy integer fields without `_id` suffix, still declared in schemas with active dual-write code. They are outside the scope of this `_id` removal plan:

- `sync/connection.ex` — `approved_by`, `suspended_by`, `revoked_by`, `created_by` (4 integer fields, actively set alongside `*_uuid` companions)
- `sync/transfer.ex` — `denied_by`, `initiated_by` (2 integer fields, actively set)
- `entities/entity_data.ex` — `created_by` (1 integer field)
- `entities/entities.ex` — `created_by` (1 integer field)

### Next Steps
1. Database migration to drop the `_id` columns (separate migration script)
2. Clean up remaining non-`_id` legacy integer fields listed above
3. Update `.md` documentation files (`OVERVIEW.md`, `DEEP_DIVE.md`) with UUID references
4. Monitor for any edge cases in production usage
