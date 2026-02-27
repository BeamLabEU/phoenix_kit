# Plan: Make Legacy NOT NULL Integer FK Columns Nullable (V67)

**Created:** 2026-02-27
**Status:** Complete
**Migration:** V67

## Problem

After the UUID cleanup (V56+), all Ecto schemas write only `_uuid` foreign keys.
But many tables still have legacy integer FK columns with `NOT NULL` constraints.
Any insert into these tables crashes with `not_null_violation`.

V66 fixed 5 posts tables. This plan covers the remaining 28 tables / 37 columns.

## Migration: V67 — Relax all remaining NOT NULL integer FK columns

Single idempotent migration. Each ALTER is guarded by table/column existence checks.

### Posts Module (3 columns)

| # | Table | Column | Created In | Status |
|---|-------|--------|-----------|--------|
| 1 | `phoenix_kit_posts` | `user_id` | V29 | [x] V67 |
| 2 | `phoenix_kit_comment_likes` | `user_id` | V48 | [x] V67 |
| 3 | `phoenix_kit_comment_dislikes` | `user_id` | V48 | [x] V67 |

### Tickets Module (2 columns)

| # | Table | Column | Created In | Status |
|---|-------|--------|-----------|--------|
| 4 | `phoenix_kit_ticket_comments` | `user_id` | V35 | [x] V67 |
| 5 | `phoenix_kit_ticket_status_history` | `changed_by_id` | V35 | [x] V67 |

### Storage Module (1 column)

| # | Table | Column | Created In | Status |
|---|-------|--------|-----------|--------|
| 6 | `phoenix_kit_files` | `user_id` | V20 | [x] V67 |

### Admin / Auth / Audit (5 columns)

| # | Table | Column | Created In | Status |
|---|-------|--------|-----------|--------|
| 7 | `phoenix_kit_admin_notes` | `user_id` | V39 | [x] V67 |
| 8 | `phoenix_kit_admin_notes` | `author_id` | V39 | [x] V67 |
| 9 | `phoenix_kit_user_oauth_providers` | `user_id` | V16 | [x] V67 |
| 10 | `phoenix_kit_audit_logs` | `target_user_id` | V22 | [x] V67 |
| 11 | `phoenix_kit_audit_logs` | `admin_user_id` | V22 | [x] V67 |

### Connections Module (13 columns)

| # | Table | Column | Created In | Status |
|---|-------|--------|-----------|--------|
| 12 | `phoenix_kit_user_follows` | `follower_id` | V36 | [x] V67 |
| 13 | `phoenix_kit_user_follows` | `followed_id` | V36 | [x] V67 |
| 14 | `phoenix_kit_user_connections` | `requester_id` | V36 | [x] V67 |
| 15 | `phoenix_kit_user_connections` | `recipient_id` | V36 | [x] V67 |
| 16 | `phoenix_kit_user_blocks` | `blocker_id` | V36 | [x] V67 |
| 17 | `phoenix_kit_user_blocks` | `blocked_id` | V36 | [x] V67 |
| 18 | `phoenix_kit_user_follows_history` | `follower_id` | V36 | [x] V67 |
| 19 | `phoenix_kit_user_follows_history` | `followed_id` | V36 | [x] V67 |
| 20 | `phoenix_kit_user_connections_history` | `user_a_id` | V36 | [x] V67 |
| 21 | `phoenix_kit_user_connections_history` | `user_b_id` | V36 | [x] V67 |
| 22 | `phoenix_kit_user_connections_history` | `actor_id` | V36 | [x] V67 |
| 23 | `phoenix_kit_user_blocks_history` | `blocker_id` | V36 | [x] V67 |
| 24 | `phoenix_kit_user_blocks_history` | `blocked_id` | V36 | [x] V67 |

### Billing Module (6 columns)

| # | Table | Column | Created In | Status |
|---|-------|--------|-----------|--------|
| 25 | `phoenix_kit_invoices` | `user_id` | V31 | [x] V67 |
| 26 | `phoenix_kit_transactions` | `user_id` | V31 | [x] V67 |
| 27 | `phoenix_kit_transactions` | `invoice_id` | V31 | [x] V67 |
| 28 | `phoenix_kit_subscriptions` | `user_id` | V33 | [x] V67 |
| 29 | `phoenix_kit_subscriptions` | `subscription_type_id` | V33/V65 | [x] V67 |
| 30 | `phoenix_kit_payment_methods` | `user_id` | V33 | [x] V67 |

> Note: V65 renamed `plan_id` → `subscription_type_id`. The column name in DB is now `subscription_type_id`.

### Entities Module (3 columns)

| # | Table | Column | Created In | Status |
|---|-------|--------|-----------|--------|
| 31 | `phoenix_kit_entities` | `created_by` | V17 | [x] V67 |
| 32 | `phoenix_kit_entity_data` | `entity_id` | V17 | [x] V67 |
| 33 | `phoenix_kit_entity_data` | `created_by` | V17 | [x] V67 |

### Referrals Module (3 columns)

| # | Table | Column | Created In | Status |
|---|-------|--------|-----------|--------|
| 34 | `phoenix_kit_referral_codes` | `created_by` | V04 | [x] V67 |
| 35 | `phoenix_kit_referral_code_usage` | `code_id` | V04 | [x] V67 |
| 36 | `phoenix_kit_referral_code_usage` | `used_by` | V04 | [x] V67 |

### Standalone Comments Module (2 columns)

| # | Table | Column | Created In | Status |
|---|-------|--------|-----------|--------|
| 37 | `phoenix_kit_comments_likes` | `user_id` | V55 | [x] V67 |
| 38 | `phoenix_kit_comments_dislikes` | `user_id` | V55 | [x] V67 |

### Shop Module (1 column)

| # | Table | Column | Created In | Status |
|---|-------|--------|-----------|--------|
| 39 | `phoenix_kit_shop_cart_items` | `cart_id` | V45 | [x] V67 |

## Tables Already Fixed (prior migrations)

| Table | Column | Fixed By |
|-------|--------|----------|
| `phoenix_kit_users_tokens` | `user_id` | V16 (nullable) + V64 (constraint) |
| `phoenix_kit_orders` | `user_id` | V51 |
| `phoenix_kit_billing_profiles` | `user_id` | V51 |
| `phoenix_kit_tickets` | `user_id` | V51 |
| `phoenix_kit_post_groups` | `user_id` | V66 |
| `phoenix_kit_post_comments` | `user_id` | V66 |
| `phoenix_kit_post_likes` | `user_id` | V66 |
| `phoenix_kit_post_dislikes` | `user_id` | V66 |
| `phoenix_kit_post_mentions` | `user_id` | V66 |
| `phoenix_kit_user_role_assignments` | `user_id`, `role_id`, `assigned_by` | V56 |
| `phoenix_kit_role_permissions` | `role_id` | V56 |

## Tables Confirmed Not Affected

These tables already have nullable integer FK columns:

- `phoenix_kit_comments` (user_id nullable, ON DELETE SET NULL)
- `phoenix_kit_shop_carts` (user_id nullable)
- `phoenix_kit_shop_products` (created_by nullable)
- `phoenix_kit_shop_import_logs` (user_id nullable)
- `phoenix_kit_ai_requests` (user_id nullable)
- `phoenix_kit_sync_connections` (all user FKs nullable)
- `phoenix_kit_post_views` (user_id nullable)
- Publishing tables (UUID-native, no integer user FKs)

## Implementation Notes

- Single V67 migration file: `lib/phoenix_kit/migrations/postgres/v67.ex`
- All operations idempotent (table/column existence + NOT NULL guards)
- `DROP NOT NULL` only — no column renames, no data changes
- Extra safety: `column_not_null?/3` check skips columns already nullable
- Handles V65 plan_id → subscription_type_id rename (checks both names)
- Down migration restores `SET NOT NULL` (reverse order)
- `@current_version` bumped to 67 in `postgres.ex`
- Compiles clean, credo clean, formatted

## Future: Drop integer columns entirely

Once all parent apps have migrated and backfilled UUID FKs, a future migration
can `DROP COLUMN` all these legacy integer columns. That will eliminate the
need for nullable workarounds entirely.
