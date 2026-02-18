# DateTime Standardization Plan

**Date:** 2026-02-17
**Status:** Planned
**Related:** `dev_docs/2026-02-15-datetime-inconsistency-report.md`

---

## Context

A production bug (Entities crash from `NaiveDateTime` in a `:utc_datetime_usec` field) revealed that PhoenixKit uses 3 different datetime conventions. Copying code between modules causes runtime crashes. The audit at `dev_docs/2026-02-15-datetime-inconsistency-report.md` documents the full scope.

**Goal:** Standardize **everything** on `:utc_datetime` and `DateTime.utc_now()`. Microsecond precision is not needed. Existing `:utc_datetime_usec` schemas will be downgraded to `:utc_datetime` — Ecto automatically truncates microseconds on read, so existing DB data is preserved (just trimmed to seconds).

---

## What Needs Fixing: Summary

| Problem | Count | Action |
|---------|-------|--------|
| Schemas using `:naive_datetime` (default or explicit) | **38 files** | Change to `:utc_datetime` |
| Schemas using `:utc_datetime_usec` (timestamps) | **~17 files** | Downgrade to `:utc_datetime` |
| Individual fields typed `:naive_datetime` | **11 fields in 9 files** | Change to `:utc_datetime` |
| Individual fields typed `:utc_datetime_usec` | **~30+ fields in ~17 files** | Downgrade to `:utc_datetime` |
| Application code using `NaiveDateTime.utc_now()` | **19 calls in 14 files** | Change to `DateTime.utc_now()` |
| Schemas already on `:utc_datetime` | **7 files** | No change needed |

**Data safety:** Changing `:utc_datetime_usec` → `:utc_datetime` does NOT delete data. Ecto truncates microseconds on read. The DB column retains full precision — only the Elixir representation loses sub-second detail.

---

## Step 1: Update Schema Timestamp Declarations (~55 files)

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

## Step 2: Update Individual Field Type Declarations

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

## Step 3: Update Application Code (14 files, 19 calls)

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

## Step 4: Update Documentation

- Update `dev_docs/2026-02-15-datetime-inconsistency-report.md` recommendation to target `:utc_datetime`
- Add DateTime Convention section to CLAUDE.md:
  - Always use `timestamps(type: :utc_datetime)` in new schemas
  - Always use `DateTime.utc_now()` in application code
  - Never use `NaiveDateTime.utc_now()` or `:utc_datetime_usec` in new code

---

## Already Correct (No Change Needed)

- **7 schemas already on `:utc_datetime`** — billing/shop (webhook_event, payment_option, subscription, subscription_plan, payment_method, cart, cart_item)
- **Display/formatter code** — `date.ex`, `time_display.ex`, `file_display.ex` already handle both DateTime and NaiveDateTime (keep NaiveDateTime clauses for backward compat)
- **DB migration** — converting `timestamp(0)` → `timestamptz` columns deferred to separate V58 migration

---

## Verification

1. `mix compile --warnings-as-errors` — no type warnings
2. `mix test` — all tests pass
3. `mix format` — clean
4. `mix credo --strict` — no issues
5. `mix dialyzer` — no new warnings
6. `grep -r "NaiveDateTime.utc_now" lib/` — should only remain in display code (`time_display.ex`, `file_display.ex`)
7. `grep -r "utc_datetime_usec" lib/` — should return zero matches
