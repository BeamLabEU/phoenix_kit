# UUID Migration Cleanup — Remaining `_id` Fields Audit

**Date:** 2026-02-25
**Updated:** 2026-02-26
**Auditor:** Kimi
**Verified:** 2026-02-25 by Claude (see corrections below)
**Scope:** All PhoenixKit schemas with legacy `_id` integer fields

---

## Status: Largely Completed

### Cleanup Commits

| Commit | Scope | Description |
|--------|-------|-------------|
| `f98159cc` | `_id` FK fields | Removed `field :*_id, :integer` declarations and `_id` from `cast()` in 30+ schemas across billing, shop, comments, posts, referrals, publishing, storage, legal, and core PhoenixKit |
| `ca43e3f7` | PK `id` field + `.id` accesses | Removed `field :id, :integer, read_after_writes: true` from ALL 40 schemas, converted all `.id` struct accesses to `.uuid`, deleted `PhoenixKit.UUID` module, deleted `resolve_user_id`/`resolve_role_id` from permissions |

### What's Done

- **All schemas listed in the original plan** (billing, shop, comments, posts, referrals, publishing, storage, legal, core PhoenixKit) — `_id` FK fields removed from both declarations and `cast()` ✅
- **All 40 schemas** — `field :id, :integer, read_after_writes: true` (PK) removed ✅
- **All `.id` struct accesses** — converted to `.uuid` across entire codebase ✅
- **`PhoenixKit.UUID` module** — deleted, call sites inlined ✅
- **`resolve_user_id`/`resolve_role_id`** in `permissions.ex` — deleted ✅
- **`ScopeNotifier`** — rewritten for UUID-based PubSub topics ✅
- **`Scope.user_id/1`** — now returns UUID instead of integer ✅
- **`scheduled_job.ex`** — `created_by_id` removed, `created_by_uuid` added ✅
- **`consent_log.ex`** — custom validator updated to not check `user_id` ✅
- **AI `maybe_filter_by`** — integer overloads removed ✅
- **Shop `filter_by_category` and `category_product_options_query`** — integer overloads removed ✅

### What Remains

**17 schema files** still have `field :*_id, :integer` declarations (not covered by original plan scope):

| Module | Schema | Remaining `_id` Fields |
|--------|--------|----------------------|
| AI | `request.ex` | `endpoint_id`, `prompt_id`, `account_id`, `user_id` |
| Entities | `entity_data.ex` | `entity_id` |
| Emails | `log.ex` | `user_id` |
| Emails | `rate_limiter.ex` | `user_id` |
| Emails | `event.ex` | `email_log_id` |
| Emails | `template.ex` | `created_by_user_id`, `updated_by_user_id` |
| Tickets | `ticket.ex` | `user_id`, `assigned_to_id` |
| Tickets | `ticket_comment.ex` | `user_id` |
| Tickets | `ticket_status_history.ex` | `changed_by_id` |
| Connections | `connection.ex` | `requester_id`, `recipient_id` |
| Connections | `connection_history.ex` | `user_a_id`, `user_b_id`, `actor_id` |
| Connections | `follow.ex` | `follower_id`, `followed_id` |
| Connections | `follow_history.ex` | `follower_id`, `followed_id` |
| Connections | `block.ex` | `blocker_id`, `blocked_id` |
| Connections | `block_history.ex` | `blocker_id`, `blocked_id` |
| Sync | `transfer.ex` | `connection_id` |

**Context functions** with remaining integer support:

| Module | Function | Issue |
|--------|----------|-------|
| `billing.ex` | `resolve_plan_uuid/1` | Integer plan_id → UUID DB lookup |
| `shop.ex` | `filter_by_parent/2` | Uses `fragment("parent_id = ?", ^id)` |
| `entities/entity_data.ex` | `list_by_entity/1` | Integer overload |
| `entities/entity_data.ex` | `list_by_entity_and_status/2` | Integer overload |
| `entities/entity_data.ex` | `count_by_entity/1` | Integer overload |
| `sync/transfers.ex` | `filter_by_connection/2` | Integer overload |
| `comments/comments.ex` | `resolve_user_uuid` | Integer overload with DB lookup |
| `publishing/dual_write.ex` | `resolve_user_ids` | Handles both integer and UUID |

---

## Original Audit Corrections (2026-02-25)

These corrections were noted during verification and remain historically accurate:

| # | Original Claim | Correction |
|---|---------------|------------|
| 1 | `cart_item.ex` — "No _id in changeset (GOOD)" | **Wrong.** Both `cart_id` and `product_id` were still cast. **Now fixed** in `f98159cc`. |
| 2 | `cart.ex` — "shipping_method_id has no _uuid counterpart" | **Wrong.** `shipping_method_uuid` exists as `belongs_to`. **Now cleaned** in `f98159cc`. |
| 3 | `create_subscription/2` — "Removed in latest commit" | **Wrong at time of audit.** Still existed. |
| 4 | `resolve_*_uuid` helpers — "Removed in latest commit" | **Wrong at time of audit.** `resolve_plan_uuid/1` still exists. |
| 5 | `shop.ex` line ~1315 — "filter_by_category" | **Wrong function name.** Actual function is `category_product_options_query/1`. **Now cleaned** in `ca43e3f7`. |
| 6 | `ai.ex` `maybe_filter_by/3` — only `endpoint_id` mentioned | **Incomplete.** Also had `:user_id` overload. **Both now cleaned** in `ca43e3f7`. |
| 7 | `scheduled_job.ex` — "`created_by_uuid` (V61 added)" | **Wrong.** No `created_by_uuid` existed. **Now added** in `f98159cc`. |
| 8 | Category 2 title — "No `_uuid` Field Declaration" | **Misleading.** Nearly all had `_uuid` equivalents. |
| 9 | `post_view.ex` `session_id` listed as legacy FK | **Not a FK.** It's `field :session_id, :string` for view deduplication. |
| 10 | `post.ex`, `post_group.ex` — "(check)" | **Verified.** Both had `user_id` in cast. **Now cleaned** in `f98159cc`. |

---

## Next Steps

1. Remove `_id` field declarations from the 17 remaining schema files
2. Remove remaining integer overloads from context functions
3. After all code stops referencing `_id` columns, plan DB migration to drop them
