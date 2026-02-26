# Comprehensive UUID Migration Cleanup Analysis

**Date:** 2026-02-26
**Updated:** 2026-02-26
**Analyst:** Mistral Vibe
**Scope:** Complete analysis of remaining `_id` field usage after V62 migration

## Status: Largely Completed

Two major commits addressed the bulk of this analysis:

| Commit | Description |
|--------|-------------|
| `f98159cc` | Removed `field :*_id, :integer` declarations and `_id` from `cast()` in billing, shop, comments, posts, referrals, publishing, storage, legal, and core PhoenixKit schemas |
| `ca43e3f7` | Removed `field :id, :integer, read_after_writes: true` (PK) from ALL 40 schemas, converted all `.id` accesses to `.uuid`, deleted `PhoenixKit.UUID` module, deleted `resolve_user_id`/`resolve_role_id` |

## Remaining `_id` Fields (Not Yet Cleaned)

The following modules still have `field :*_id, :integer` declarations. These were NOT covered by the original plan's scope:

### AI Module
- `request.ex`: `endpoint_id`, `prompt_id`, `account_id`, `user_id`

### Entities Module
- `entity_data.ex`: `entity_id`

### Emails Module
- `log.ex`: `user_id`
- `rate_limiter.ex`: `user_id`
- `event.ex`: `email_log_id`
- `template.ex`: `created_by_user_id`, `updated_by_user_id`

### Tickets Module
- `ticket.ex`: `user_id`, `assigned_to_id`
- `ticket_comment.ex`: `user_id`
- `ticket_status_history.ex`: `changed_by_id`

### Connections Module (6 files)
- `connection.ex`: `requester_id`, `recipient_id`
- `connection_history.ex`: `user_a_id`, `user_b_id`, `actor_id`
- `follow.ex`: `follower_id`, `followed_id`
- `follow_history.ex`: `follower_id`, `followed_id`
- `block.ex`: `blocker_id`, `blocked_id`
- `block_history.ex`: `blocker_id`, `blocked_id`

### Sync Module
- `transfer.ex`: `connection_id`

## Remaining Context Functions with Integer Support

- `billing.ex`: `resolve_plan_uuid/1` — integer plan_id → UUID DB lookup
- `shop.ex`: `filter_by_parent/2` — uses `fragment("parent_id = ?", ^id)`
- `entities/entity_data.ex`: `list_by_entity/1`, `list_by_entity_and_status/2`, `count_by_entity/1` — integer overloads
- `sync/transfers.ex`: `filter_by_connection/2` — integer overload
- `comments/comments.ex`: `resolve_user_uuid` — integer overload with DB lookup
- `publishing/dual_write.ex`: `resolve_user_ids` — handles both integer and UUID

## Completed Recommendations

### ~~Priority 1: High Impact (Active Dual-Write Schemas)~~ DONE

All billing, shop, and referrals schemas cleaned. `_id` fields removed from both field declarations and `cast()` calls.

### ~~Priority 2: Medium Impact (Field Declarations Only)~~ DONE

Comments, posts, billing profile, payment method, transaction schemas all cleaned.

### Priority 3: Context Functions — Partially Done

AI and shop `maybe_filter_by`/`filter_by_category`/`category_product_options_query` cleaned. Remaining items listed above.

### ~~Priority 4: Comprehensive Cleanup~~ Partially Done

Core schemas cleaned. Remaining modules (AI, Connections, Entities, Emails, Tickets, Sync) still have `_id` field declarations.

## Next Steps

1. Remove `_id` field declarations from remaining 17 schema files (AI, Entities, Emails, Tickets, Connections, Sync)
2. Remove remaining integer overloads from context functions
3. Remove `resolve_user_uuid` integer overload from `comments.ex`
4. Remove `resolve_user_ids` dual-mode function from `publishing/dual_write.ex`
5. After all code stops referencing `_id` columns, plan DB migration to drop them
