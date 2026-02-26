# DateTime Standardization Plan

**Date:** 2026-02-17
**Updated:** 2026-02-22 (post-review fixes applied)
**Status:** Steps 1-5 **COMPLETE** — all DB write sites use `UtilsDate.utc_now()`
**Related:** `dev_docs/audits/2026-02-15-datetime-inconsistency-report.md`

---

## Context

A production bug (Entities crash from `NaiveDateTime` in a `:utc_datetime_usec` field) revealed that PhoenixKit uses 3 different datetime conventions. The audit at `dev_docs/audits/2026-02-15-datetime-inconsistency-report.md` documents the full scope.

**Goal:** Standardize **everything** on `:utc_datetime` and `DateTime.utc_now()`. Microsecond precision is not needed. Existing `:utc_datetime_usec` schemas will be downgraded to `:utc_datetime` — Ecto automatically truncates microseconds on read, so existing DB data is preserved (just trimmed to seconds).

---

## CRITICAL: The Truncation Problem

**The original plan had an incorrect assumption:**

> ~~`DateTime.utc_now()` returns second precision by default, so no `truncate/2` calls needed~~

**This is wrong.** `DateTime.utc_now()` returns **microsecond precision**. When a `:utc_datetime` schema field receives a DateTime with non-zero microseconds, Ecto raises:

```
ArgumentError: :utc_datetime expects microseconds to be empty
```

**Every** `DateTime.utc_now()` call that writes to a `:utc_datetime` field MUST use:

```elixir
DateTime.truncate(DateTime.utc_now(), :second)
```

PR #347 changed all schemas to `:utc_datetime` without adding truncation. PR #350 partially fixed this (19 files), but **~50 additional crash sites remain**.

### Centralized Helper — ✅ IMPLEMENTED

Added `utc_now/0` to the existing `PhoenixKit.Utils.Date` module (`lib/phoenix_kit/utils/date.ex`):

```elixir
alias PhoenixKit.Utils.Date, as: UtilsDate

# Returns DateTime.utc_now() truncated to second precision
UtilsDate.utc_now()
```

Replace all remaining `DateTime.truncate(DateTime.utc_now(), :second)` and bare `DateTime.utc_now()` (in DB write contexts) with `UtilsDate.utc_now()`. Future code uses the helper — impossible to get wrong.

---

## What Needs Fixing: Summary

| Problem | Count | Status |
|---------|-------|--------|
| Schemas using `:naive_datetime` (default or explicit) | **38 files** | ✅ DONE (PR #347) |
| Schemas using `:utc_datetime_usec` (timestamps) | **~17 files** | ✅ DONE (PR #347) |
| Individual fields typed `:naive_datetime` | **11 fields in 9 files** | ✅ DONE (PR #347) |
| Individual fields typed `:utc_datetime_usec` | **~30+ fields in ~17 files** | ✅ DONE (PR #347) |
| Application code using `NaiveDateTime.utc_now()` | **19 calls in 14 files** | ✅ DONE (PR #347) |
| **`DateTime.utc_now()` needing truncation** | **50+ calls in 28+ files** | ⚠️ **25 fixed (PR #350 + Entities), 25+ REMAINING** |

---

## Step 1: Update Schema Timestamp Declarations (~55 files) — DONE

### Group A — Default `timestamps()` → `timestamps(type: :utc_datetime)` (8 files)

| File | Module |
|------|--------|
| `lib/phoenix_kit/users/auth/user.ex` | `PhoenixKit.Users.Auth.User` |
| `lib/phoenix_kit/users/admin_note.ex` | `PhoenixKit.Users.AdminNote` |
| `lib/phoenix_kit/users/role.ex` | `PhoenixKit.Users.Role` |
| `lib/modules/shop/schemas/product.ex` | `PhoenixKit.Modules.Shop.Product` |
| `lib/modules/shop/schemas/category.ex` | `PhoenixKit.Modules.Shop.Category` |
| `lib/modules/shop/schemas/import_config.ex` | `PhoenixKit.Modules.Shop.ImportConfig` |
| `lib/modules/shop/schemas/import_log.ex` | `PhoenixKit.Modules.Shop.ImportLog` |
| `lib/modules/shop/schemas/shipping_method.ex` | `PhoenixKit.Modules.Shop.ShippingMethod` |

Note: `shop_config.ex` has `@timestamps_opts [type: :utc_datetime]` — already correct.

### Group B — `timestamps(updated_at: false)` → add `type: :utc_datetime` (3 files)

| File | Module |
|------|--------|
| `lib/phoenix_kit/users/role_assignment.ex` | `PhoenixKit.Users.RoleAssignment` |
| `lib/phoenix_kit/users/role_permission.ex` | `PhoenixKit.Users.RolePermission` |
| `lib/phoenix_kit/users/auth/user_token.ex` | `PhoenixKit.Users.Auth.UserToken` |

### Group C — Explicit `timestamps(type: :naive_datetime)` → `:utc_datetime` (26 files)

**Tickets (4):** `ticket.ex`, `ticket_comment.ex`, `ticket_attachment.ex`, `ticket_status_history.ex`
**Posts (13):** `post.ex`, `post_like.ex`, `post_dislike.ex`, `post_comment.ex`, `post_mention.ex`, `post_group.ex`, `post_group_assignment.ex`, `post_tag.ex`, `post_tag_assignment.ex`, `post_media.ex`, `post_view.ex`, `comment_like.ex`, `comment_dislike.ex`
**Comments (3):** `comment.ex`, `comment_like.ex`, `comment_dislike.ex`
**Storage (5):** `file.ex`, `dimension.ex`, `file_instance.ex`, `bucket.ex`, `file_location.ex`
**Connections (1):** `connection.ex`

### Group D — `timestamps(type: :utc_datetime_usec)` → `:utc_datetime` (~17 files)

| File | Module |
|------|--------|
| `lib/modules/ai/endpoint.ex` | `PhoenixKit.Modules.AI.Endpoint` |
| `lib/modules/ai/prompt.ex` | `PhoenixKit.Modules.AI.Prompt` |
| `lib/modules/ai/request.ex` | `PhoenixKit.Modules.AI.Request` |
| `lib/modules/emails/template.ex` | `PhoenixKit.Modules.Emails.Template` |
| `lib/modules/emails/log.ex` | `PhoenixKit.Modules.Emails.Log` |
| `lib/modules/emails/event.ex` | `PhoenixKit.Modules.Emails.Event` |
| `lib/modules/billing/schemas/billing_profile.ex` | `PhoenixKit.Modules.Billing.BillingProfile` |
| `lib/modules/billing/schemas/invoice.ex` | `PhoenixKit.Modules.Billing.Invoice` |
| `lib/modules/billing/schemas/currency.ex` | `PhoenixKit.Modules.Billing.Currency` |
| `lib/modules/billing/schemas/order.ex` | `PhoenixKit.Modules.Billing.Order` |
| `lib/modules/billing/schemas/transaction.ex` | `PhoenixKit.Modules.Billing.Transaction` |
| `lib/modules/sync/connection.ex` | `PhoenixKit.Modules.Sync.Connection` |
| `lib/modules/sync/transfer.ex` | `PhoenixKit.Modules.Sync.Transfer` |
| `lib/modules/legal/schemas/consent_log.ex` | `PhoenixKit.Modules.Legal.ConsentLog` |
| `lib/phoenix_kit/users/oauth_provider.ex` | `PhoenixKit.Users.OAuthProvider` |
| `lib/phoenix_kit/audit_log/entry.ex` | `PhoenixKit.AuditLog.Entry` |
| `lib/phoenix_kit/scheduled_jobs/scheduled_job.ex` | `PhoenixKit.ScheduledJobs.ScheduledJob` |

---

## Step 2: Update Individual Field Type Declarations — DONE

### `:naive_datetime` → `:utc_datetime` (9 files, 11 fields)

| File | Field(s) |
|------|----------|
| `lib/phoenix_kit/users/auth/user.ex` | `field :confirmed_at` |
| `lib/phoenix_kit/users/role_assignment.ex` | `field :assigned_at` |
| `lib/modules/connections/connection.ex` | `field :requested_at`, `field :responded_at` |
| `lib/modules/connections/connection_history.ex` | `field :inserted_at` |
| `lib/modules/connections/follow.ex` | `field :inserted_at` |
| `lib/modules/connections/follow_history.ex` | `field :inserted_at` |
| `lib/modules/connections/block.ex` | `field :inserted_at` |
| `lib/modules/connections/block_history.ex` | `field :inserted_at` |
| `lib/modules/storage/schemas/file_location.ex` | `field :last_verified_at` |

### `:utc_datetime_usec` → `:utc_datetime` (~17 files, ~30+ fields)

| File | Field(s) |
|------|----------|
| `lib/modules/entities/entities.ex` | `date_created`, `date_updated` |
| `lib/modules/entities/entity_data.ex` | `date_created`, `date_updated` |
| `lib/modules/sync/transfer.ex` | `approved_at`, `denied_at`, `approval_expires_at`, `started_at`, `completed_at` |
| `lib/modules/sync/connection.ex` | `expires_at`, `approved_at`, `suspended_at`, `revoked_at`, `last_connected_at`, `last_transfer_at` |
| `lib/modules/referrals/schemas/referral_code_usage.ex` | `date_used` |
| `lib/modules/referrals/referrals.ex` | `date_created`, `expiration_date` |
| `lib/modules/billing/schemas/invoice.ex` | `receipt_generated_at`, `sent_at`, `paid_at`, `voided_at` |
| `lib/modules/billing/schemas/order.ex` | `confirmed_at`, `paid_at`, `cancelled_at` |
| `lib/modules/tickets/ticket.ex` | `resolved_at`, `closed_at` |
| `lib/modules/posts/schemas/post.ex` | `scheduled_at`, `published_at` |
| `lib/modules/posts/schemas/post_view.ex` | `viewed_at` |
| `lib/modules/ai/endpoint.ex` | `last_validated_at` |
| `lib/modules/ai/prompt.ex` | `last_used_at` |
| `lib/modules/emails/template.ex` | `last_used_at` |
| `lib/modules/emails/log.ex` | `queued_at`, `sent_at`, `delivered_at`, `bounced_at`, `complained_at`, `opened_at`, `clicked_at`, `rejected_at`, `failed_at`, `delayed_at` |
| `lib/modules/emails/event.ex` | `occurred_at` |
| `lib/modules/emails/rate_limiter.ex` | `expires_at`, `inserted_at`, `updated_at` (embedded schema) |
| `lib/phoenix_kit/settings/setting.ex` | `date_added`, `date_updated` |
| `lib/phoenix_kit/scheduled_jobs/scheduled_job.ex` | `scheduled_at`, `executed_at` |
| `lib/phoenix_kit/users/oauth_provider.ex` | `token_expires_at` |

---

## Step 3: Update NaiveDateTime Application Code (14 files, 19 calls) — DONE

Replace `NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)` → `DateTime.utc_now()`
Replace bare `NaiveDateTime.utc_now()` → `DateTime.utc_now()`

| File | Line(s) | Context |
|------|---------|---------|
| `lib/phoenix_kit/users/auth/user.ex` | ~322 | `confirm_changeset` |
| `lib/phoenix_kit/users/permissions.ex` | ~738 | `set_permissions` bulk insert timestamps |
| `lib/phoenix_kit/users/role_assignment.ex` | ~102 | `put_assigned_at` changeset |
| `lib/phoenix_kit/users/magic_link_registration.ex` | ~166 | `do_complete_registration` confirmed_at |
| `lib/phoenix_kit/users/roles.ex` | ~802 | `maybe_add_confirmed_at` |
| `lib/phoenix_kit/users/sessions.ex` | ~234, ~290, ~294 | Query boundaries + age calculations |
| `lib/modules/storage/storage.ex` | ~238 | `reset_dimensions_to_defaults` bulk insert |
| `lib/modules/comments/comments.ex` | ~307 | `bulk_update_status` update_all |
| `lib/modules/connections/connection.ex` | ~170, ~182 | `put_requested_at`, `put_responded_at` |
| `lib/modules/connections/connection_history.ex` | ~98 | `put_timestamp` |
| `lib/modules/connections/follow.ex` | ~116 | `put_inserted_at` |
| `lib/modules/connections/follow_history.ex` | ~58 | `put_timestamp` |
| `lib/modules/connections/block.ex` | ~124 | `put_inserted_at` |
| `lib/modules/connections/block_history.ex` | ~59 | `put_timestamp` |

---

## Step 4: Update Documentation — DONE

- CLAUDE.md updated with DateTime convention
- Inconsistency report updated with Phase 1 completion status

---

## Step 5: Add DateTime.truncate(:second) to All DB Write Sites — ~98% COMPLETE

PR #350 fixed 19 files, PR #355 fixed the remaining ~35 files using `UtilsDate.utc_now()`. **1 site remains:** `emails/event.ex` `parse_timestamp/1` (lines 921-922).

All sites now use `UtilsDate.utc_now()` (the centralized helper) instead of bare `DateTime.utc_now()` or manual `DateTime.truncate(DateTime.utc_now(), :second)`.

### How to Fix Each Site

1. Add the alias to the module:
```elixir
alias PhoenixKit.Utils.Date, as: UtilsDate
```

2. Replace bare `DateTime.utc_now()` calls that write to DB:
```elixir
# Before
now = DateTime.utc_now()

# After
now = UtilsDate.utc_now()
```

### 5a. Emails Module (22 crash sites)

| File | Line(s) | Field(s) | Status |
|------|---------|----------|--------|
| `lib/modules/emails/log.ex` | 562 | `delivered_at` | FIXED (PR #355) |
| `lib/modules/emails/log.ex` | 592 | `bounced_at` | FIXED (PR #355) |
| `lib/modules/emails/log.ex` | 632 | `occurred_at` (Event) | FIXED (PR #355) |
| `lib/modules/emails/log.ex` | 657 | `occurred_at` (Event) | FIXED (PR #355) |
| `lib/modules/emails/log.ex` | 674 | `queued_at` | FIXED (PR #355) |
| `lib/modules/emails/log.ex` | 691 | `sent_at` | FIXED (PR #355) |
| `lib/modules/emails/log.ex` | 708 | `rejected_at` | FIXED (PR #355) |
| `lib/modules/emails/log.ex` | 726 | `failed_at` | FIXED (PR #355) |
| `lib/modules/emails/log.ex` | 761 | `delayed_at` | FIXED (PR #355) |
| `lib/modules/emails/log.ex` | 1148 | `sent_at` (build_log_attributes) | FIXED (PR #355) |
| `lib/modules/emails/event.ex` | 762 | `occurred_at` | FIXED (PR #350) |
| `lib/modules/emails/event.ex` | 917, 921 | `occurred_at` (parse_timestamp fallback) | FIXED (post-PR #355 review) |
| `lib/modules/emails/interceptor.ex` | 251 | `sent_at` | FIXED (PR #355) |
| `lib/modules/emails/templates.ex` | 480 | `last_used_at` | FIXED (PR #355) |
| `lib/modules/emails/rate_limiter.ex` | 284 | `inserted_at` (EmailBlocklist) | FIXED (PR #355) |
| `lib/modules/emails/rate_limiter.ex` | 285 | `updated_at` (EmailBlocklist) | FIXED (PR #355) |
| `lib/modules/emails/rate_limiter.ex` | 290 | `updated_at` (on_conflict) | FIXED (PR #355) |
| `lib/modules/emails/sqs_processor.ex` | 452 | `bounced_at` | FIXED (PR #355) |
| `lib/modules/emails/sqs_processor.ex` | 490 | `complained_at` | FIXED (PR #355) |
| `lib/modules/emails/sqs_processor.ex` | 639 | `rejected_at` | FIXED (PR #355) |
| `lib/modules/emails/sqs_processor.ex` | 683, 686 | `delayed_at` | FIXED (PR #355) |
| `lib/modules/emails/sqs_processor.ex` | 811 | `failed_at` | FIXED (PR #355) |
| `lib/modules/emails/sqs_processor.ex` | 1220, 1224 | `occurred_at` (parse_timestamp fallback) | FIXED (PR #355) |

### 5b. Billing Module (11 crash sites)

| File | Line(s) | Field(s) | Status |
|------|---------|----------|--------|
| `lib/modules/billing/schemas/invoice.ex` | 163-165 | `sent_at`, `paid_at`, `voided_at` | FIXED (PR #355) |
| `lib/modules/billing/schemas/invoice.ex` | 175 | `receipt_generated_at` (via billing.ex) | FIXED (PR #355) |
| `lib/modules/billing/schemas/order.ex` | 217-222 | `confirmed_at`, `paid_at`, `cancelled_at` | FIXED (PR #355) |
| `lib/modules/billing/schemas/subscription.ex` | 158 | `last_renewal_attempt_at` | FIXED (PR #355) |
| `lib/modules/billing/schemas/subscription.ex` | 186 | `cancelled_at` | FIXED (PR #355) |
| `lib/modules/billing/schemas/subscription.ex` | 203 | `trial_start` | FIXED (PR #355) |
| `lib/modules/billing/schemas/webhook_event.ex` | 72 | `processed_at` | FIXED (PR #355) |
| `lib/modules/billing/billing.ex` | 1957 | `receipt_generated_at` | FIXED (PR #355) |
| `lib/modules/billing/billing.ex` | 2681 | `current_period_start`, `trial_start` | FIXED (PR #355) |
| `lib/modules/billing/utils/webhook_processor.ex` | 268, 269 | `inserted_at`, `updated_at` (raw insert_all) | FIXED (PR #355) |
| `lib/modules/billing/utils/webhook_processor.ex` | 302, 304 | `processed_at`, `updated_at` (raw update_all) | FIXED (PR #355) |
| `lib/modules/billing/workers/subscription_dunning_worker.ex` | 163 | `last_renewal_attempt_at` | FIXED (PR #355) |

### 5c. Sync Module (8 crash sites, beyond already-known connections/transfer)

| File | Line(s) | Field(s) | Status |
|------|---------|----------|--------|
| `lib/modules/sync/connection.ex` | 219 | `approved_at` | FIXED (PR #355) |
| `lib/modules/sync/connection.ex` | 232 | `suspended_at` | FIXED (PR #355) |
| `lib/modules/sync/connection.ex` | 246 | `revoked_at` | FIXED (PR #355) |
| `lib/modules/sync/connections.ex` | 500-501 | `last_connected_at`, `last_transfer_at` | FIXED (PR #355) |
| `lib/modules/sync/connections.ex` | 521 | `last_connected_at` | FIXED (PR #355) |
| `lib/modules/sync/connections.ex` | ~631 | `updated_at` (expire_connections update_all) | FIXED (PR #355) |
| `lib/modules/sync/transfer.ex` | 179 | `started_at` | FIXED (PR #355) |
| `lib/modules/sync/transfer.ex` | 219 | `completed_at` | FIXED (PR #355) |
| `lib/modules/sync/transfer.ex` | 231 | `completed_at` | FIXED (PR #355) |
| `lib/modules/sync/transfer.ex` | 242 | `completed_at` | FIXED (PR #355) |
| `lib/modules/sync/transfer.ex` | 250 | `approval_expires_at` (DateTime.add on untruncated) | FIXED (PR #355) |
| `lib/modules/sync/transfer.ex` | 267 | `approved_at` | FIXED (PR #355) |
| `lib/modules/sync/transfer.ex` | 280 | `denied_at` | FIXED (PR #355) |
| `lib/modules/sync/connection_notifier.ex` | 542 | `started_at` (passed to Transfers.create_transfer) | FIXED (PR #355) |
| `lib/modules/sync/web/api_controller.ex` | 379 | `last_connected_at` | FIXED (PR #355) |
| `lib/modules/sync/web/api_controller.ex` | 434 | `last_transfer_at` | FIXED (PR #355) |
| `lib/modules/sync/web/api_controller.ex` | 450, 451 | `started_at`, `completed_at` | FIXED (PR #355) |

### 5d. Connections Module (7 crash sites)

| File | Line(s) | Field(s) | Status |
|------|---------|----------|--------|
| `lib/modules/connections/follow.ex` | 116 | `inserted_at` | FIXED (PR #355) |
| `lib/modules/connections/follow_history.ex` | 58 | `inserted_at` | FIXED (PR #355) |
| `lib/modules/connections/block.ex` | 124 | `inserted_at` | FIXED (PR #355) |
| `lib/modules/connections/block_history.ex` | 59 | `inserted_at` | FIXED (PR #355) |
| `lib/modules/connections/connection.ex` | 170 | `requested_at` | FIXED (PR #355) |
| `lib/modules/connections/connection.ex` | 182 | `responded_at` | FIXED (PR #355) |
| `lib/modules/connections/connection_history.ex` | 98 | `inserted_at` | FIXED (PR #355) |

### 5e. Entities Module (6 crash sites)

| File | Line(s) | Field(s) | Status |
|------|---------|----------|--------|
| `lib/modules/entities/entity_data.ex` | 383 | `date_created` | FIXED |
| `lib/modules/entities/entity_data.ex` | 393 | `date_updated` | FIXED |
| `lib/modules/entities/entity_data.ex` | 863 | `date_updated` (update_all) | FIXED |
| `lib/modules/entities/entity_data.ex` | 883 | `date_updated` (update_all) | FIXED |
| `lib/modules/entities/entities.ex` | 282 | `date_created` | FIXED |
| `lib/modules/entities/entities.ex` | 292 | `date_updated` | FIXED |

### 5f. Shop Module (4 crash sites beyond PR #350 fixes)

| File | Line(s) | Field(s) | Status |
|------|---------|----------|--------|
| `lib/modules/shop/shop.ex` | 539-541 | `updated_at` (bulk products) | FIXED (PR #355) |
| `lib/modules/shop/shop.ex` | 585 | `updated_at` (single product update_all) | FIXED (PR #355) |
| `lib/modules/shop/shop.ex` | 965-967 | `updated_at` (bulk categories) | FIXED (PR #355) |
| `lib/modules/shop/shop.ex` | 998 | `updated_at` (delete category update_all) | FIXED (PR #355) |
| `lib/modules/shop/shop.ex` | 1062 | `updated_at` (unassign category) | FIXED (PR #355) |
| `lib/modules/shop/shop.ex` | 2389-2391 | `updated_at` (cart converting) | FIXED (PR #355) |
| `lib/modules/shop/shop.ex` | 2408 | `converted_at` (cart conversion) | FIXED (PR #355) |

### 5g. AI Module (2 crash sites)

| File | Line(s) | Field(s) | Status |
|------|---------|----------|--------|
| `lib/modules/ai/endpoint.ex` | 203 | `last_validated_at` | FIXED (PR #355) |
| `lib/modules/ai/prompt.ex` | 149 | `last_used_at` | FIXED (PR #355) |

### 5h. Posts Module (1 crash site)

| File | Line(s) | Field(s) | Status |
|------|---------|----------|--------|
| `lib/modules/posts/posts.ex` | 419 | `published_at` | FIXED (PR #355) |

### 5i. Core (fixed by PR #350, unified to UtilsDate by PR #355)

| File | Line(s) | Field(s) | Status |
|------|---------|----------|--------|
| `lib/phoenix_kit/settings/setting.ex` | 122, 129, 137 | `date_added`, `date_updated` | FIXED (PR #355) |
| `lib/phoenix_kit/scheduled_jobs.ex` | 132 | `updated_at` | FIXED (PR #355) |
| `lib/phoenix_kit/scheduled_jobs/scheduled_job.ex` | 87 | `executed_at` | FIXED (PR #355) |
| `lib/phoenix_kit/users/auth.ex` | 6 sites | `anonymized_at` | FIXED (PR #355) |
| `lib/phoenix_kit/users/auth/user.ex` | 322 | `confirmed_at` | FIXED (PR #355) |
| `lib/phoenix_kit/users/magic_link_registration.ex` | 166 | `confirmed_at` | FIXED (PR #355) |
| `lib/phoenix_kit/users/permissions.ex` | 738 | bulk insert `now` | FIXED (PR #355) |
| `lib/phoenix_kit/users/role_assignment.ex` | 102 | `assigned_at` | FIXED (PR #355) |
| `lib/phoenix_kit/users/roles.ex` | 802 | `confirmed_at` | FIXED (PR #355) |
| `lib/modules/comments/comments.ex` | 307 | `updated_at` | FIXED (PR #355) |
| `lib/modules/referrals/referrals.ex` | 760 | `date_created` | FIXED (PR #355) |
| `lib/modules/referrals/schemas/referral_code_usage.ex` | 220 | `date_used` | FIXED (PR #355) |
| `lib/modules/tickets/tickets.ex` | 589, 592 | `resolved_at`, `closed_at` | FIXED (PR #355) |

---

## Verified SAFE Calls (No Fix Needed)

These `DateTime.utc_now()` calls do NOT write to `:utc_datetime` schema fields:

| Pattern | Examples |
|---------|----------|
| **LiveView assigns** | `assign(:last_updated, DateTime.utc_now())` — in-memory only |
| **Query predicates** | `where: c.expires_at < ^now` — Ecto handles comparison fine |
| **String conversion** | `DateTime.utc_now() \|> DateTime.to_iso8601()` — no DB write |
| **ETS / GenServer state** | `%{state \| last_poll: DateTime.utc_now()}` — in-memory only |
| **PubSub payloads** | `%{timestamp: DateTime.utc_now()}` — broadcast metadata |
| **Logger metadata** | `Logger.info("...", timestamp: DateTime.utc_now())` |
| **Plain struct fields** | `%SitemapFile{lastmod: DateTime.utc_now()}` — not Ecto schema |
| **Filesystem paths** | `DateTime.utc_now() \|> Calendar.strftime(...)` |
| **JSON/map fields** | Writing into `:map` / `{:array, :map}` JSONB — accepts any value |
| **Arithmetic only** | `DateTime.diff(DateTime.utc_now(), other)` — no write |

---

## Already Correct (No Change Needed)

- **7 schemas already on `:utc_datetime`** — billing/shop (webhook_event, payment_option, subscription, subscription_plan, payment_method, cart, cart_item)
- **Display/formatter code** — `date.ex`, `time_display.ex`, `file_display.ex` already handle both DateTime and NaiveDateTime (keep NaiveDateTime clauses for backward compat)
- **DB migration** — converting `timestamp(0)` → `timestamptz` columns deferred to separate V58 migration

---

## Post-PR #350 Analysis (Added 2026-02-19)

### What PR #350 Fixed (19 sites)

| Module | Sites Fixed | Risk Level |
|--------|-------------|------------|
| Billing | 6 sites (Invoice, Order) | High |
| Core | 6 sites (Settings, ScheduledJobs, Auth) | High |
| Referrals | 2 sites | Medium |
| Tickets | 2 sites | Medium |
| Comments | 1 site | Medium |
| Shop | 3 sites | Medium |
| Group struct conversion | 1 site | High |
| Live sessions UUID | 1 site | High |

### All Sites Fixed (PR #355 + post-review fixes)

| Module | Sites | Status |
|--------|-------|--------|
| Emails | 22 sites | ✅ ALL FIXED (PR #355 + post-review fix for `event.ex` parse_timestamp) |
| Sync | 15 sites | ✅ ALL FIXED (PR #355) |
| Connections | 7 sites | ✅ ALL FIXED (PR #355) |
| Shop | 3 sites | ✅ ALL FIXED (PR #355) |
| Entities | 6 sites | ✅ FIXED (pre-PR #355) |
| AI | 2 sites | ✅ ALL FIXED (PR #355) |
| Posts | 1 site | ✅ ALL FIXED (PR #355) |
| Billing | 5 sites | ✅ ALL FIXED (PR #355) |

### Remaining Action

1. ~~**Add centralized helper**~~ ✅ Done — `UtilsDate.utc_now/0` in `lib/phoenix_kit/utils/date.ex`
2. ~~**Fix Entities module**~~ ✅ Done — 6/6 sites fixed
3. ~~**Fix Emails module**~~ ✅ Done (PR #355 + post-review) — all 22 sites fixed
4. ~~**Fix Sync module**~~ ✅ Done (PR #355) — all 15 sites fixed
5. ~~**Fix Connections module**~~ ✅ Done (PR #355) — all 7 sites fixed
6. ~~**Fix `event.ex` parse_timestamp**~~ ✅ Done (post-review) — truncation + `UtilsDate.utc_now()` fallback
7. **Add integration tests** for datetime-heavy workflows

## Verification

1. `mix compile --warnings-as-errors` — no type warnings
2. `mix test` — all tests pass
3. `mix format` — clean
4. `mix credo --strict` — no issues
5. `mix dialyzer` — no new warnings
6. `grep -r "NaiveDateTime.utc_now" lib/` — should only remain in display code (`time_display.ex`, `file_display.ex`)
7. `grep -r "utc_datetime_usec" lib/` — should return zero matches
8. **NEW:** `ast-grep --lang elixir --pattern 'DateTime.utc_now()' lib/` then verify every hit either has `truncate` or is in the SAFE list above

---

## PR History

| PR | What It Did | Status | Date |
|----|-------------|--------|------|
| #347 | Changed all schemas from `:utc_datetime_usec`/`:naive_datetime` → `:utc_datetime` and all `NaiveDateTime.utc_now()` → `DateTime.utc_now()` | ✅ Merged | 2026-02-17 |
| #350 | Fixed 19/50+ truncation sites, fixed Group struct conversion, fixed live sessions UUID lookup | ✅ Merged | 2026-02-18 |
| — | Add `UtilsDate.utc_now/0` centralized helper + fix Entities module | ✅ Done | 2026-02-21 |
| #355 | Fixed remaining ~35 truncation sites across all modules using `UtilsDate.utc_now()`, added form try/rescue handlers, fixed CommentsComponent + media upload bugs | ✅ Merged | 2026-02-22 |
| — | Post-review fixes: `event.ex` parse_timestamp + 4 misplaced try/rescue blocks + gettext consistency | ✅ Done | 2026-02-22 |
| #TBD | V58 DB migration: `timestamp(0)` → `timestamptz` columns | ⏭️ Deferred | - |

---

## Testing Strategy for Truncation Fixes

### Manual Testing Priority
1. **Emails module**: Send test emails through all paths (SQS, interceptor, templates)
2. **Sync module**: Run connection approval, transfer workflows
3. **Connections**: Create follows, blocks, connection requests
4. **Billing**: Process subscriptions, invoices, webhooks

### Automated Test Coverage
```elixir
# Example test pattern for each fixed site
test "DateTime fields are truncated to seconds" do
  # Before fix: would raise ArgumentError
  {:ok, record} = create_record_with_timestamp()
  assert record.timestamp.microsecond == 0
end
```

### Smoke Test Command
```bash
# Verify no untruncated DateTime.utc_now() in DB write contexts
# Should only return: utils/date.ex (the helper itself), display code, and SAFE patterns
ast-grep --lang elixir --pattern 'DateTime.utc_now()' lib/ | \
  grep -v "utils/date.ex" | \
  grep -v "SAFE_PATTERNS"
```

## Centralized Helper — ✅ IMPLEMENTED

### Location: `lib/phoenix_kit/utils/date.ex` → `PhoenixKit.Utils.Date.utc_now/0`

Added to the existing `PhoenixKit.Utils.Date` module (not a separate file) since it's already the date/time utility module used across the codebase.

```elixir
alias PhoenixKit.Utils.Date, as: UtilsDate

# In changesets:
put_change(changeset, :updated_at, UtilsDate.utc_now())

# In bulk updates:
Repo.update_all(Query, set: [updated_at: UtilsDate.utc_now()])
```

### Remaining Migration Steps
1. ~~Add the helper function~~ ✅ Done
2. Replace all remaining `DateTime.utc_now()` DB write sites with `UtilsDate.utc_now()` (see sections 5a-5h)
3. Replace existing `DateTime.truncate(DateTime.utc_now(), :second)` from PR #350 with `UtilsDate.utc_now()` for consistency
4. Update CLAUDE.md to reference the helper
5. Add Credo check to warn on bare `DateTime.utc_now()` in DB contexts

---

**Related:**
- Parent PR #347 (schema migration)
- CLAUDE.md section "DateTime: Always Use `DateTime.utc_now()`" — should be updated to reference the truncation requirement once the helper is implemented.
