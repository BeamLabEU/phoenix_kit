# Plan: Remove All Legacy `_id` Fields from Code

**Date:** 2026-02-25
**Goal:** Remove all integer `_id` field usage so we can drop `_id` columns from DB in a few weeks
**Audit:** `dev_docs/audits/2026-02-25-uuid-cleanup-remaining-id-fields.md` (verified)
**Approach:** No backward compatibility. UUID-only. Delete integer code paths entirely.

---

## Phase 1: Schema Cleanup — Remove `_id` from field declarations and cast()

For each file: remove `field :*_id, :integer` declarations AND remove `_id` atoms from `cast()` calls.

### Billing Schemas

- [ ] `lib/modules/billing/schemas/invoice.ex` — Remove `user_id` (line 103), `order_id` (line 106) field + cast (lines 120, 122)
- [ ] `lib/modules/billing/schemas/billing_profile.ex` — Remove `user_id` (line 97) field + cast (line 109)
- [ ] `lib/modules/billing/schemas/payment_method.ex` — Remove `user_id` (line 61) field + cast (line 89)
- [ ] `lib/modules/billing/schemas/subscription.ex` — Remove `user_id` (line 78), `plan_id` (line 88), `payment_method_id` (line 91) fields + cast (lines 120-123)
- [ ] `lib/modules/billing/schemas/transaction.ex` — Remove `invoice_id` (line 41), `user_id` (line 44) fields + cast (lines 64, 66)
- [ ] `lib/modules/billing/schemas/order.ex` — Remove `user_id` (line 125) field declaration (already removed from cast)

### Shop Schemas

- [ ] `lib/modules/shop/schemas/cart.ex` — Remove `user_id` (line 38), `shipping_method_id` (line 47), `payment_option_id` (line 58), `merged_into_cart_id` (line 87) fields + cast (lines 101, 105, 108, 122)
- [ ] `lib/modules/shop/schemas/cart_item.ex` — Remove `cart_id` (line 41), `product_id` (line 44) fields + cast (lines 83, 85)
- [ ] `lib/modules/shop/schemas/category.ex` — Remove `parent_id` (line 54), `featured_product_id` (line 65) fields + cast (lines 90-93)
- [ ] `lib/modules/shop/schemas/product.ex` — Remove `category_id` (line 98), `created_by` (line 106) fields + cast (lines 150, 152)
- [ ] `lib/modules/shop/schemas/import_log.ex` — Remove `user_id` (line 58) field + cast (line 69)

### Comments Schemas

- [ ] `lib/modules/comments/schemas/comment.ex` — Remove `user_id` (line 65) field + cast (line 92)
- [ ] `lib/modules/comments/schemas/comment_dislike.ex` — Remove `user_id` (line 34) field (already removed from cast)
- [ ] `lib/modules/comments/schemas/comment_like.ex` — Remove `user_id` (line 34) field (already removed from cast)

### Posts Schemas

- [ ] `lib/modules/posts/schemas/post.ex` — Remove `user_id` (line 133) field + cast (line 175)
- [ ] `lib/modules/posts/schemas/post_group.ex` — Remove `user_id` (line 83) field + cast (line 117)
- [ ] `lib/modules/posts/schemas/post_comment.ex` — Remove `user_id` (line 52) field + cast (line 83)
- [ ] `lib/modules/posts/schemas/post_like.ex` — Remove `user_id` (line 47) field + cast (line 66)
- [ ] `lib/modules/posts/schemas/post_dislike.ex` — Remove `user_id` (line 47) field + cast (line 66)
- [ ] `lib/modules/posts/schemas/post_mention.ex` — Remove `user_id` (line 65) field + cast (line 86)
- [ ] `lib/modules/posts/schemas/post_view.ex` — Remove `user_id` (line 75) field + cast (line 96)
- [ ] `lib/modules/posts/schemas/comment_dislike.ex` — Remove `user_id` (line 34) field + cast (line 53)
- [ ] `lib/modules/posts/schemas/comment_like.ex` — Remove `user_id` (line 34) field + cast (line 53)

### Other Module Schemas

- [ ] `lib/modules/legal/schemas/consent_log.ex` — Remove `user_id` (line 76) field + cast (line 114). Note: custom validator (lines 130-140) checks `user_id` — update to check only `user_uuid`
- [ ] `lib/modules/referrals/schemas/referral_code_usage.ex` — Remove `code_id` (line 50), `used_by` (line 45) fields + cast (line 62)
- [ ] `lib/modules/publishing/schemas/publishing_post.ex` — Remove `created_by_id` (line 70), `updated_by_id` (line 77) fields + cast (lines 100, 102)
- [ ] `lib/modules/publishing/schemas/publishing_version.ex` — Remove `created_by_id` (line 53) field + cast (line 71)
- [ ] `lib/modules/storage/schemas/file.ex` — Remove `user_id` (line 140) field + cast (line 186)

### Core PhoenixKit Schemas

- [ ] `lib/phoenix_kit/users/oauth_provider.ex` — Remove `user_id` (line 20) field + cast (line 40)
- [ ] `lib/phoenix_kit/users/admin_note.ex` — Remove `user_id` (line 42), `author_id` (line 49) fields + cast (line 66)
- [ ] `lib/phoenix_kit/users/role_permission.ex` — Remove `role_id` (line 41), `granted_by` (line 38) fields + cast (line 52)
- [ ] `lib/phoenix_kit/audit_log/entry.ex` — Remove `target_user_id` (line 51), `admin_user_id` (line 53) fields + cast (lines 79-82)
- [ ] `lib/phoenix_kit/users/auth/user_token.ex` — Stop populating `user_id` in `build_session_token` (line 107), `build_email_token` (line 195), `build_hashed_token`. Remove `field :user_id` (line 50)

### Special Case: Missing UUID Field

- [ ] `lib/phoenix_kit/scheduled_jobs/scheduled_job.ex` — `created_by_id` (line 48) has **NO `created_by_uuid` counterpart**. Add `created_by_uuid` field to schema, verify DB column exists (or add via migration), then remove `created_by_id`

---

## Phase 2: Context Function Cleanup — Remove integer ID support

Delete integer overloads and ID-to-UUID resolution functions entirely.

### Billing Context

- [ ] `lib/modules/billing/billing.ex` — `create_order(attrs)` (line 954): Remove `user_id` extraction and `extract_user_uuid(user_id)` fallback. Require `user_uuid` directly
- [ ] `lib/modules/billing/billing.ex` — `create_order(user_or_id, attrs)` (line 922): Update to accept only UUID or User struct, remove integer path
- [ ] `lib/modules/billing/billing.ex` — `create_subscription/2` (line 2858): Change first param from `user_id` to `user_uuid`, remove `extract_user_uuid` call
- [ ] `lib/modules/billing/billing.ex` — `resolve_plan_uuid/1` (line 3322): Remove integer overload (keep UUID passthrough if needed)
- [ ] `lib/modules/billing/billing.ex` — `maybe_mark_linked_order_paid/1` (line 3335): Update to use `order_uuid` instead of `order_id`
- [ ] `lib/modules/billing/billing.ex` — Search for any remaining `extract_user_uuid` calls and replace with direct UUID usage

### Shop Context

- [ ] `lib/modules/shop/shop.ex` — `category_product_options_query/1` (line 1313): Change param from integer `category_id` to UUID, query on `p.category_uuid`
- [ ] `lib/modules/shop/shop.ex` — `filter_by_category/2` (lines 2629-2644): Remove integer overload and `Integer.parse` fallback, keep UUID-only path
- [ ] `lib/modules/shop/shop.ex` — `filter_by_parent/2` (lines 2723-2725): Remove entirely, replace callers with `filter_by_parent_uuid/2` (lines 2727-2729)

### AI Context

- [ ] `lib/modules/ai/ai.ex` — `maybe_filter_by/3` `:endpoint_id` (lines 1239-1248): Remove integer overload, query on `endpoint_uuid` only
- [ ] `lib/modules/ai/ai.ex` — `maybe_filter_by/3` `:user_id` (lines 1250-1259): Remove integer overload, query on `user_uuid` only

### Sync Context

- [ ] `lib/modules/sync/transfers.ex` — `filter_by_connection/2` (lines 630-644): Remove integer overload, query on `connection_uuid` only

### Entities Context

- [ ] `lib/modules/entities/entity_data.ex` — `list_by_entity/1` (line 476): Remove integer overload, keep UUID version
- [ ] `lib/modules/entities/entity_data.ex` — `list_by_entity_and_status/2` (line 503): Remove integer overload, keep UUID version
- [ ] `lib/modules/entities/entity_data.ex` — `count_by_entity/1` (line 792): Remove integer overload, keep UUID version

---

## Phase 3: Callers and References

- [ ] Search for any remaining `_id` usage in LiveViews, controllers, and templates that pass integer IDs to the above functions
- [ ] Search for `extract_user_uuid` calls across the codebase and eliminate them
- [ ] Search for `Integer.parse` patterns used for ID fallback and remove them
- [ ] Check `@type` specs on schemas — remove `_id` fields from typespecs

---

## Phase 4: Verify

- [ ] `mix compile --warnings-as-errors` — no warnings
- [ ] `mix format`
- [ ] `mix credo --strict`
- [ ] `mix test` — all pass
- [ ] Grep: `ast-grep --lang elixir --pattern 'field :$_id, :integer' lib/` returns nothing relevant
- [ ] Grep: `grep -r '_id.*:integer' lib/ --include='*.ex' | grep -v '#'` returns nothing relevant (excluding comments)

---

## Notes

- `field :id, :integer, read_after_writes: true` on Pattern 1 tables is the **primary key** — leave it alone until the full PK migration
- `session_id` in `post_view.ex` is a `:string` for deduplication — not an FK, leave it
- `webhook_event.ex` has no legacy `_id` FKs — clean
- `consent_log.ex` has a custom validator that checks `user_id OR user_uuid OR session_id` — needs special attention
