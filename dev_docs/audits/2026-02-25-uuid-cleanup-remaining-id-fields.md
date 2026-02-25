# UUID Migration Cleanup — Remaining `_id` Fields Audit

**Date:** 2026-02-25  
**Auditor:** Kimi  
**Scope:** All PhoenixKit schemas with legacy `_id` integer fields  

---

## Executive Summary

After the V62 migration and subsequent cleanup PRs, **28 schemas** still contain legacy `field :*_id, :integer` declarations. Of these:
- **8 schemas** are in "dual-write" mode (have both `_id` and `_uuid` fields)
- **20 schemas** have `_id` fields only (some with `belongs_to` using `_uuid` FK)

**Recommendation:** Remove all `_id` fields from changesets and context functions to complete the UUID migration.

---

## Category 1: Dual-Write Schemas (Both `_id` and `_uuid`)

These schemas have explicit `field :*_id, :integer` and `field :*_uuid, UUIDv7` declarations. The `_id` fields should be removed from changesets.

### 1. Billing Module

#### `lib/modules/billing/schemas/invoice.ex`
```elixir
# Legacy fields:
field :user_id, :integer
field :order_id, :integer

# UUID fields:
field :subscription_uuid, UUIDv7
belongs_to :user, User, foreign_key: :user_uuid, ...
belongs_to :order, Order, foreign_key: :order_uuid, ...

# Changeset casts BOTH (line 119-146):
cast(attrs, [:user_id, :user_uuid, :order_id, :order_uuid, :subscription_uuid, ...])
```

### 2. Comments Module

#### `lib/modules/comments/schemas/comment.ex`
```elixir
# Legacy fields:
field :user_id, :integer

# UUID fields:
field :resource_uuid, Ecto.UUID
belongs_to :user, User, foreign_key: :user_uuid, ...

# Changeset casts BOTH:
cast(attrs, [:user_id, :user_uuid, :resource_uuid, ...])
```

### 3. Legal Module

#### `lib/modules/legal/schemas/consent_log.ex`
```elixir
# Legacy fields:
field :user_id, :integer

# UUID fields:
field :user_uuid, UUIDv7

# Changeset casts BOTH:
cast(attrs, [:user_id, :user_uuid, ...])
```

### 4. Referrals Module

#### `lib/modules/referrals/schemas/referral_code_usage.ex`
```elixir
# Legacy fields:
field :code_id, :integer
field :used_by, :integer  # user_id equivalent

# UUID fields:
field :used_by_uuid, UUIDv7
belongs_to :referral_code, Referrals, foreign_key: :code_uuid, ...

# Changeset casts BOTH (line 62):
cast(attrs, [:code_id, :code_uuid, :used_by, :used_by_uuid, :date_used])
```

### 5. Shop Module

#### `lib/modules/shop/schemas/cart.ex`
```elixir
# Legacy fields:
field :user_id, :integer
field :shipping_method_id, :integer
field :payment_option_id, :integer
field :merged_into_cart_id, :integer

# UUID fields:
field :merged_into_cart_uuid, UUIDv7
belongs_to :user, User, foreign_key: :user_uuid, ...

# Changeset casts BOTH (lines 166, 176):
cast(attrs, [:payment_option_id, :payment_option_uuid])
cast(attrs, [:merged_into_cart_id, :merged_into_cart_uuid])
# Note: shipping_method_id has no _uuid counterpart (V62 didn't cover it)
```

#### `lib/modules/shop/schemas/cart_item.ex`
```elixir
# Legacy fields:
field :cart_id, :integer
field :product_id, :integer

# UUID fields:
field :variant_uuid, UUIDv7
belongs_to :cart, Cart, foreign_key: :cart_uuid, ...
belongs_to :product, Product, foreign_key: :product_uuid, ...

# No _id in changeset (GOOD - only UUIDs cast)
```

#### `lib/modules/shop/schemas/category.ex`
```elixir
# Legacy fields:
field :parent_id, :integer
field :featured_product_id, :integer

# UUID fields:
field :image_uuid, Ecto.UUID
belongs_to :parent, __MODULE__, foreign_key: :parent_uuid, ...
belongs_to :featured_product, Product, foreign_key: :featured_product_uuid, ...

# Changeset casts BOTH (lines 90-98):
cast(attrs, [:featured_product_id, :featured_product_uuid, :parent_id, :parent_uuid, ...])
```

#### `lib/modules/shop/schemas/product.ex`
```elixir
# Legacy fields:
field :category_id, :integer
field :created_by, :integer

# UUID fields:
field :featured_image_uuid, Ecto.UUID
field :file_uuid, Ecto.UUID
belongs_to :category, Category, foreign_key: :category_uuid, ...
belongs_to :created_by_user, User, foreign_key: :created_by_uuid, ...

# Changeset casts BOTH (lines 150-154):
cast(attrs, [:category_id, :category_uuid, :created_by, :created_by_uuid, ...])
```

---

## Category 2: Schemas with `_id` Only (No `_uuid` Field Declaration)

These schemas have `field :*_id, :integer` but may have `belongs_to` with `foreign_key: :*_uuid`. The `field :*_id` declarations are truly legacy and should be removed.

### Billing Module

| Schema | Legacy `_id` Fields | Has `_uuid` FK? |
|--------|---------------------|-----------------|
| `billing_profile.ex` | `user_id` | ✅ `user_uuid` |
| `order.ex` | `user_id` | ✅ `user_uuid` |
| `payment_method.ex` | `user_id` | ✅ `user_uuid` |
| `subscription.ex` | `user_id`, `plan_id`, `payment_method_id` | ✅ All have `_uuid` |
| `transaction.ex` | `invoice_id`, `user_id` | ✅ `invoice_uuid`, `user_uuid` |
| `webhook_event.ex` | (check if any) | - |

### Comments Module

| Schema | Legacy `_id` Fields | Has `_uuid` FK? |
|--------|---------------------|-----------------|
| `comment_dislike.ex` | `user_id` | ✅ `user_uuid` |
| `comment_like.ex` | `user_id` | ✅ `user_uuid` |

### Posts Module

| Schema | Legacy `_id` Fields | Has `_uuid` FK? |
|--------|---------------------|-----------------|
| `comment_dislike.ex` | `user_id` | ✅ `user_uuid` |
| `comment_like.ex` | `user_id` | ✅ `user_uuid` |
| `post_comment.ex` | `user_id` | ✅ `user_uuid` |
| `post_dislike.ex` | `user_id` | ✅ `user_uuid` |
| `post.ex` | (check) | Pattern 2 table (UUID PK) |
| `post_group.ex` | (check) | Pattern 2 table (UUID PK) |
| `post_like.ex` | `user_id` | ✅ `user_uuid` |
| `post_mention.ex` | `user_id` | ✅ `user_uuid` |
| `post_view.ex` | `user_id`, `session_id` | ✅ `user_uuid` |

### Publishing Module

| Schema | Legacy `_id` Fields | Has `_uuid` FK? |
|--------|---------------------|-----------------|
| `publishing_post.ex` | `created_by_id`, `updated_by_id` | ✅ `created_by_uuid`, `updated_by_uuid` |
| `publishing_version.ex` | `created_by_id` | ✅ `created_by_uuid` |

### Shop Module

| Schema | Legacy `_id` Fields | Has `_uuid` FK? |
|--------|---------------------|-----------------|
| `import_log.ex` | `user_id` | ✅ `user_uuid` |

### Storage Module

| Schema | Legacy `_id` Fields | Has `_uuid` FK? |
|--------|---------------------|-----------------|
| `file.ex` | `user_id` | ✅ `user_uuid` |

---

## Category 3: Context Functions Using `_id`

These context functions still reference `_id` fields in queries or attrs:

### Billing Context (`lib/modules/billing/billing.ex`)

| Line | Function | Issue |
|------|----------|-------|
| 959 | `create_order(attrs)` | Resolves `user_id` from attrs |
| 2877-2882 | `create_subscription/2` | Removed in latest commit |
| 3332-3343 | `resolve_*_uuid` helpers | Removed in latest commit |

### Shop Context (`lib/modules/shop/shop.ex`)

| Line | Function | Issue |
|------|----------|-------|
| 1315 | `filter_by_category` | Uses `category_id` |
| 2641-2648 | `filter_by_category` | Pattern match on integer |
| 2730 | `filter_by_parent` | Uses `parent_id` |

### AI Context (`lib/modules/ai/ai.ex`)

| Line | Function | Issue |
|------|----------|-------|
| 1240-1247 | `maybe_filter_by/3` | Uses `endpoint_id` |

### Sync Context (`lib/modules/sync/transfers.ex`)

| Line | Function | Issue |
|------|----------|-------|
| 632-644 | `filter_by_connection/2` | Uses `connection_id` |

### Entities Context (`lib/modules/entities/entity_data.ex`)

| Line | Function | Issue |
|------|----------|-------|
| 478, 506, 793 | Various | Uses `entity_id` |

---

## Recommended Cleanup Priority

### Priority 1: High Impact (Used in Active Code)

1. **Shop Module**
   - `cart.ex` - Remove `payment_option_id`, `merged_into_cart_id` from changesets
   - `category.ex` - Remove `parent_id`, `featured_product_id` from changeset
   - `product.ex` - Remove `category_id`, `created_by` from changeset
   - `shop.ex` context - Update `filter_by_category`, `filter_by_parent` to use UUID only

2. **Billing Module**
   - `invoice.ex` - Remove `user_id`, `order_id` from changeset
   - `billing.ex` context - Remove `user_id` resolution from `create_order/1`

3. **Referrals Module**
   - `referral_code_usage.ex` - Remove `code_id`, `used_by` from changeset

### Priority 2: Medium Impact (Schemas Ready for Cleanup)

4. **Billing Schemas**
   - `billing_profile.ex`, `payment_method.ex`, `subscription.ex`, `transaction.ex`
   - Remove `field :user_id, :integer` and `:user_id` from changesets

5. **Comments/Posts Schemas**
   - All `*_like`, `*_dislike`, `comment`, `mention`, `view` schemas
   - Remove `field :user_id, :integer` (already have `user_uuid`)

6. **Publishing Schemas**
   - `publishing_post.ex`, `publishing_version.ex`
   - Remove `created_by_id`, `updated_by_id` fields

### Priority 3: Low Impact (Pattern 2 Tables)

7. **Posts Schemas**
   - `post.ex`, `post_group.ex` - Pattern 2 tables (UUID native PK)
   - Verify no `_id` FK references remain

---

## Files to Modify

### Schemas (Remove `_id` from `cast()` and `field` declarations):

```
lib/modules/billing/schemas/invoice.ex
lib/modules/billing/schemas/billing_profile.ex
lib/modules/billing/schemas/order.ex
lib/modules/billing/schemas/payment_method.ex
lib/modules/billing/schemas/subscription.ex
lib/modules/billing/schemas/transaction.ex
lib/modules/comments/schemas/comment.ex
lib/modules/comments/schemas/comment_dislike.ex
lib/modules/comments/schemas/comment_like.ex
lib/modules/legal/schemas/consent_log.ex
lib/modules/posts/schemas/comment_dislike.ex
lib/modules/posts/schemas/comment_like.ex
lib/modules/posts/schemas/post_comment.ex
lib/modules/posts/schemas/post_dislike.ex
lib/modules/posts/schemas/post_like.ex
lib/modules/posts/schemas/post_mention.ex
lib/modules/posts/schemas/post_view.ex
lib/modules/publishing/schemas/publishing_post.ex
lib/modules/publishing/schemas/publishing_version.ex
lib/modules/referrals/schemas/referral_code_usage.ex
lib/modules/shop/schemas/cart.ex
lib/modules/shop/schemas/category.ex
lib/modules/shop/schemas/import_log.ex
lib/modules/shop/schemas/product.ex
lib/modules/storage/schemas/file.ex
```

### Context Modules (Update functions):

```
lib/modules/billing/billing.ex
lib/modules/shop/shop.ex
lib/modules/ai/ai.ex
lib/modules/sync/transfers.ex
lib/modules/entities/entity_data.ex
```

---

## Migration Needed?

**No new migration required** — this is code cleanup only. The V62 migration already added all `_uuid` columns. This audit is about:
1. Removing `_id` fields from changesets (stop writing to them)
2. Removing `_id` field declarations (they're already optional in DB)
3. Updating context functions to use UUIDs only

After code cleanup, a future migration can drop the `_id` columns entirely.

---

## Estimated Effort

- **Schemas:** ~25 files, 1-2 lines each (remove from `cast()` and `field`)
- **Context functions:** ~10-15 functions to refactor
- **Tests:** May need updates if they pass integer IDs
- **Total:** ~4-6 hours of work

---

## Appendix: Core PhoenixKit Schemas

These schemas in `lib/phoenix_kit/` also have legacy `_id` fields:

| Schema | Legacy `_id` Fields | Has `_uuid` FK? |
|--------|---------------------|-----------------|
| `scheduled_jobs/scheduled_job.ex` | `created_by_id` | ✅ `created_by_uuid` (V61 added) |
| `users/oauth_provider.ex` | `user_id` | ✅ `user_uuid` |
| `users/admin_note.ex` | `user_id`, `author_id` | Check if `_uuid` exists |
| `users/role_permission.ex` | `role_id` | Check if `_uuid` exists |
| `users/auth/user_token.ex` | `user_id` | ✅ `user_uuid` |
| `audit_log/entry.ex` | `target_user_id`, `admin_user_id` | Check if `_uuid` exists |

---

## Related PRs

- PR #365 — UUID field fixes (Storage, Posts, Publishing, Comments, Tickets)
- Latest commits — Removed `billing_profile_id` support
- This audit — Documents remaining cleanup needed
