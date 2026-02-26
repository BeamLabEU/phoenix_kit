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
| Phase 2: Context function integer overload cleanup | — | **Partially done** |
| Phase 3: Callers and references | — | **Partially done** |
| Phase 4: Verify | — | **Pending** (blocked by remaining work) |

### Additional completed work (commit `ca43e3f7`):
- Removed `field :id, :integer, read_after_writes: true` from ALL 40 schemas
- Converted ALL `.id` struct accesses to `.uuid` across entire codebase
- Deleted `lib/phoenix_kit/uuid.ex` (temporary dual-lookup module)
- Deleted `resolve_user_id` and `resolve_role_id` from `permissions.ex`
- Rewrote `ScopeNotifier` for UUID-based PubSub topics
- Changed `Scope.user_id/1` to return UUID instead of integer
- Updated all `count(x.id)` → `count(x.uuid)` in Ecto queries
- Changed integer overloads in core `get_*` functions to use `fragment("id = ?", ^id)`

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
- [ ] `lib/modules/ai/request.ex` — `endpoint_id`, `prompt_id`, `account_id`, `user_id`

### Entities Module
- [ ] `lib/modules/entities/entity_data.ex` — `entity_id`

### Emails Module
- [ ] `lib/modules/emails/log.ex` — `user_id`
- [ ] `lib/modules/emails/rate_limiter.ex` — `user_id`
- [ ] `lib/modules/emails/event.ex` — `email_log_id`
- [ ] `lib/modules/emails/template.ex` — `created_by_user_id`, `updated_by_user_id`

### Tickets Module
- [ ] `lib/modules/tickets/ticket.ex` — `user_id`, `assigned_to_id`
- [ ] `lib/modules/tickets/ticket_comment.ex` — `user_id`
- [ ] `lib/modules/tickets/ticket_status_history.ex` — `changed_by_id`

### Connections Module
- [ ] `lib/modules/connections/connection.ex` — `requester_id`, `recipient_id`
- [ ] `lib/modules/connections/connection_history.ex` — `user_a_id`, `user_b_id`, `actor_id`
- [ ] `lib/modules/connections/follow.ex` — `follower_id`, `followed_id`
- [ ] `lib/modules/connections/follow_history.ex` — `follower_id`, `followed_id`
- [ ] `lib/modules/connections/block.ex` — `blocker_id`, `blocked_id`
- [ ] `lib/modules/connections/block_history.ex` — `blocker_id`, `blocked_id`

### Sync Module
- [ ] `lib/modules/sync/transfer.ex` — `connection_id`

---

## Phase 2: Context Function Cleanup — Remove integer ID support

Delete integer overloads and ID-to-UUID resolution functions entirely.

### Billing Context

- [ ] `billing.ex` — `extract_user_uuid` is still used in ~15 call sites (accepts structs/strings/nil, no integer overload remaining)
- [ ] `billing.ex` — `resolve_plan_uuid/1` — still has integer overload (DB lookup)

### Shop Context

- [x] `shop.ex` — `category_product_options_query/1` — integer overload removed (now UUID-only)
- [x] `shop.ex` — `filter_by_category/2` — integer overload removed (now UUID-only)
- [ ] `shop.ex` — `filter_by_parent/2` — still uses `fragment("parent_id = ?", ^id)` for non-nil/non-skip values

### AI Context

- [x] `ai.ex` — `maybe_filter_by/3` `:endpoint_id` — integer overload removed (now UUID-only)
- [x] `ai.ex` — `maybe_filter_by/3` `:user_id` — integer overload removed (now UUID-only)

### Sync Context

- [ ] `transfers.ex` — `filter_by_connection/2` — integer overload still exists

### Entities Context

- [ ] `entity_data.ex` — `list_by_entity/1` — integer overload still exists
- [ ] `entity_data.ex` — `list_by_entity_and_status/2` — integer overload still exists
- [ ] `entity_data.ex` — `count_by_entity/1` — integer overload still exists

### Other Context Functions (not in original plan)

- [ ] `comments/comments.ex` — `resolve_user_uuid` has integer overload (DB lookup)
- [ ] `publishing/dual_write.ex` — `resolve_user_ids` handles both integer and UUID

---

## Phase 3: Callers and References

- [x] Check `@type` specs on schemas — removed `id: integer()` from typespecs
- [ ] Search for remaining `extract_user_uuid` calls in billing and eliminate them
- [ ] Search for `Integer.parse` patterns used for ID fallback and remove them
- [ ] Search for remaining `_id` usage in LiveViews, controllers, templates

---

## Phase 4: Verify

- [ ] `mix compile --warnings-as-errors` — no warnings
- [ ] `mix format`
- [ ] `mix credo --strict`
- [ ] `mix test` — all pass
- [ ] Grep: `grep -r '_id.*:integer' lib/ --include='*.ex' | grep -v '#'` returns nothing relevant

---

## Notes

- ~~`field :id, :integer, read_after_writes: true` on Pattern 1 tables is the **primary key** — leave it alone until the full PK migration~~ **DONE** — removed from all 40 schemas in commit `ca43e3f7`
- `session_id` in `post_view.ex` is a `:string` for deduplication — not an FK, leave it
- `webhook_event.ex` has no legacy `_id` FKs — clean
- `consent_log.ex` custom validator updated — no longer checks `user_id`
