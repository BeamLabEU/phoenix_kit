# UUID Migration Cleanup — Remaining `_id` Fields Audit

**Date:** 2026-02-25
**Auditor:** Kimi
**Verified:** 2026-02-25 by Claude (see corrections below)
**Scope:** All PhoenixKit schemas with legacy `_id` integer fields

---

## Executive Summary

**VERIFIED 2026-02-25:** All findings verified against current codebase. Corrections applied inline (marked with ⚠️). The audit is directionally correct but had factual errors around what was "already removed" and some miscategorizations.

After the V62 migration and subsequent cleanup PRs:
- **40+ schemas** still contain legacy `field :*_id, :integer` declarations
- **Only 3 schemas cleaned from cast:** `comments/comment_dislike.ex`, `comments/comment_like.ex`, `billing/order.ex`
- **Dual-write mode:** Most schemas still cast both `_id` and `_uuid` fields (high priority)
- **Field declarations remain:** All schemas keep `_id` fields for DB compatibility

**Recommendation:**
1. **High Priority:** Remove `_id` fields from `cast()` functions in dual-write schemas (~30 files)
2. **High Priority:** Update context functions to stop supporting integer IDs (~6 modules)
3. **Action Required:** Add `created_by_uuid` field to `scheduled_job.ex` (missing from V61/V62)
4. **Future Phase:** Remove field declarations once DB columns can be dropped

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
# Legacy fields (lines 38, 47, 58, 87):
field :user_id, :integer
field :shipping_method_id, :integer
field :payment_option_id, :integer
field :merged_into_cart_id, :integer

# UUID fields:
field :merged_into_cart_uuid, UUIDv7
belongs_to :user, User, foreign_key: :user_uuid, ...
belongs_to :shipping_method, ShippingMethod, foreign_key: :shipping_method_uuid, ...
belongs_to :payment_option, PaymentOption, foreign_key: :payment_option_uuid, ...

# Changeset casts BOTH (lines 100-124) — 4 dual-write pairs:
cast(attrs, [:user_id, :user_uuid, :shipping_method_id, :shipping_method_uuid,
             :payment_option_id, :payment_option_uuid, :merged_into_cart_id, :merged_into_cart_uuid, ...])
```

> ⚠️ **Correction:** Original audit claimed `shipping_method_id` has "no _uuid counterpart" — this is **wrong**. `shipping_method_uuid` exists as `belongs_to` (lines 49-52) and was covered by V62 migration.

#### `lib/modules/shop/schemas/cart_item.ex`
```elixir
# Legacy fields (lines 41, 44):
field :cart_id, :integer
field :product_id, :integer

# UUID fields:
field :variant_uuid, UUIDv7
belongs_to :cart, Cart, foreign_key: :cart_uuid, ...
belongs_to :product, Product, foreign_key: :product_uuid, ...

# Changeset casts BOTH (lines 82-101):
cast(attrs, [:cart_id, :cart_uuid, :product_id, :product_uuid, ...])
```

> ⚠️ **Correction:** Original audit claimed "No _id in changeset (GOOD)" — this is **wrong**. Both `:cart_id` and `:product_id` are still cast alongside their `_uuid` counterparts. This is a dual-write schema.

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

## Category 2: Remaining Dual-Write Schemas

> ⚠️ **Correction:** Original audit titled this "Schemas with `_id` Only (No `_uuid` Field Declaration)" — this is misleading. Nearly all these schemas have `_uuid` equivalents AND still cast `_id` in changesets. They are effectively dual-write schemas, same as Category 1.

These schemas have `field :*_id, :integer` with corresponding `belongs_to :*, foreign_key: :*_uuid`. Most still cast `_id` fields in changesets.

### Billing Module

| Schema | Legacy `_id` Fields | Has `_uuid` FK? | `_id` in cast()? |
|--------|---------------------|-----------------|-------------------|
| `billing_profile.ex` | `user_id` | ✅ `user_uuid` | ✅ Yes (line 109) |
| `order.ex` | `user_id` | ✅ `user_uuid` | ❌ **Already cleaned** |
| `payment_method.ex` | `user_id` | ✅ `user_uuid` | ✅ Yes (line 89) |
| `subscription.ex` | `user_id`, `plan_id`, `payment_method_id` | ✅ All have `_uuid` | ✅ All 3 in cast (lines 120-123) |
| `transaction.ex` | `invoice_id`, `user_id` | ✅ `invoice_uuid`, `user_uuid` | ✅ Both in cast (lines 64, 66) |
| `webhook_event.ex` | None (only PK) | N/A | N/A — **Clean** |

> ⚠️ **Note:** `subscription.ex` has 3 dual-write pairs — should really be in Category 1.

### Comments Module

| Schema | Legacy `_id` Fields | Has `_uuid` FK? | `_id` in cast()? |
|--------|---------------------|-----------------|-------------------|
| `comment_dislike.ex` | `user_id` | ✅ `user_uuid` | ❌ **Already cleaned** |
| `comment_like.ex` | `user_id` | ✅ `user_uuid` | ❌ **Already cleaned** |

### Posts Module

| Schema | Legacy `_id` Fields | Has `_uuid` FK? | `_id` in cast()? |
|--------|---------------------|-----------------|-------------------|
| `comment_dislike.ex` | `user_id` | ✅ `user_uuid` | ✅ Yes (line 53) |
| `comment_like.ex` | `user_id` | ✅ `user_uuid` | ✅ Yes (line 53) |
| `post_comment.ex` | `user_id` | ✅ `user_uuid` | ✅ Yes (line 83) |
| `post_dislike.ex` | `user_id` | ✅ `user_uuid` | ✅ Yes (line 66) |
| `post.ex` | `user_id` | ✅ `user_uuid` | ✅ Yes (line 175) |
| `post_group.ex` | `user_id` | ✅ `user_uuid` | ✅ Yes (line 117) |
| `post_like.ex` | `user_id` | ✅ `user_uuid` | ✅ Yes (line 66) |
| `post_mention.ex` | `user_id` | ✅ `user_uuid` | ✅ Yes (line 86) |
| `post_view.ex` | `user_id` | ✅ `user_uuid` | ✅ Yes (line 96) |

> ⚠️ **Correction:** `session_id` in `post_view.ex` is `field :session_id, :string` — a session identifier for view deduplication, **NOT a foreign key**. Not relevant to UUID cleanup.

> ⚠️ **Correction:** `post.ex` and `post_group.ex` both have `user_id` in cast — original audit said "(check)".

### Publishing Module

| Schema | Legacy `_id` Fields | Has `_uuid` FK? | `_id` in cast()? |
|--------|---------------------|-----------------|-------------------|
| `publishing_post.ex` | `created_by_id`, `updated_by_id` | ✅ `created_by_uuid`, `updated_by_uuid` | ✅ Both (lines 100, 102) |
| `publishing_version.ex` | `created_by_id` | ✅ `created_by_uuid` | ✅ Yes (line 71) |

### Shop Module

| Schema | Legacy `_id` Fields | Has `_uuid` FK? | `_id` in cast()? |
|--------|---------------------|-----------------|-------------------|
| `import_log.ex` | `user_id` | ✅ `user_uuid` | ✅ Yes (line 69) |

### Storage Module

| Schema | Legacy `_id` Fields | Has `_uuid` FK? | `_id` in cast()? |
|--------|---------------------|-----------------|-------------------|
| `file.ex` | `user_id` | ✅ `user_uuid` | ✅ Yes (line 186) |

---

## Category 3: Context Functions Using `_id`

These context functions still reference `_id` fields in queries or attrs:

### Billing Context (`lib/modules/billing/billing.ex`)

| Line | Function | Issue |
|------|----------|-------|
| 954-999 | `create_order(attrs)` | Resolves `user_id` from attrs via `extract_user_uuid/1` |
| 2858-2903 | `create_subscription/2` | Accepts integer `user_id` as first param, resolves to UUID |
| 3322-3333 | `resolve_plan_uuid/1` | Resolves integer `plan_id` to UUID via DB lookup |
| 3335+ | `maybe_mark_linked_order_paid/1` | Pattern matches on `order_id` field |

> ⚠️ **Correction:** Original audit claimed `create_subscription/2` and `resolve_*_uuid` helpers were "removed in latest commit" — both **still exist and are active**.

### Shop Context (`lib/modules/shop/shop.ex`)

| Line | Function | Issue |
|------|----------|-------|
| 1313-1323 | `category_product_options_query/1` | Accepts integer `category_id`, queries `p.category_id` |
| 2629-2644 | `filter_by_category/2` | Integer overload queries `p.category_id`; binary overload falls back to integer parse |
| 2723-2729 | `filter_by_parent/2` | Queries `c.parent_id` directly (separate `filter_by_parent_uuid/2` exists at lines 2727-2729) |

> ⚠️ **Correction:** Line ~1315 was cited as `filter_by_category` — the actual function is `category_product_options_query/1`.

### AI Context (`lib/modules/ai/ai.ex`)

| Line | Function | Issue |
|------|----------|-------|
| 1239-1248 | `maybe_filter_by/3` `:endpoint_id` | Integer overload queries `r.endpoint_id`; binary falls back to integer parse |
| 1250-1259 | `maybe_filter_by/3` `:user_id` | Integer overload queries `r.user_id`; binary falls back to integer parse |

> ⚠️ **Correction:** Original audit missed the `:user_id` overload at lines 1250-1259.

### Sync Context (`lib/modules/sync/transfers.ex`)

| Line | Function | Issue |
|------|----------|-------|
| 630-644 | `filter_by_connection/2` | Integer overload queries `t.connection_id`; binary falls back to integer parse |

### Entities Context (`lib/modules/entities/entity_data.ex`)

| Line | Function | Issue |
|------|----------|-------|
| 476-483 | `list_by_entity/1` | Integer overload queries `d.entity_id` |
| 503-511 | `list_by_entity_and_status/2` | Integer overload queries `d.entity_id` |
| 792-795 | `count_by_entity/1` | Integer overload queries `d.entity_id` |

> **Note:** All entity_data functions have dual overloads (integer + binary UUID). Cleanup means removing the integer overloads.

---

## Recommended Cleanup Priority

### Priority 1: High Impact (Active Dual-Write + Context Functions)

1. **Shop Module** (5 schemas + 1 context)
   - `cart.ex` — Remove `user_id`, `shipping_method_id`, `payment_option_id`, `merged_into_cart_id` from cast (4 pairs)
   - `cart_item.ex` — Remove `cart_id`, `product_id` from cast (2 pairs)
   - `category.ex` — Remove `parent_id`, `featured_product_id` from cast (2 pairs)
   - `product.ex` — Remove `category_id`, `created_by` from cast (2 pairs)
   - `import_log.ex` — Remove `user_id` from cast
   - `shop.ex` context — Remove integer overloads from `filter_by_category`, `filter_by_parent`, `category_product_options_query`

2. **Billing Module** (5 schemas + 1 context)
   - `invoice.ex` — Remove `user_id`, `order_id` from cast (2 pairs)
   - `billing_profile.ex` — Remove `user_id` from cast
   - `payment_method.ex` — Remove `user_id` from cast
   - `subscription.ex` — Remove `user_id`, `plan_id`, `payment_method_id` from cast (3 pairs)
   - `transaction.ex` — Remove `invoice_id`, `user_id` from cast (2 pairs)
   - `billing.ex` context — Remove `user_id` resolution from `create_order`, `create_subscription`; remove `resolve_plan_uuid` integer path

3. **Referrals Module**
   - `referral_code_usage.ex` — Remove `code_id`, `used_by` from cast (2 pairs)

4. **Core PhoenixKit Schemas** (4 schemas)
   - `oauth_provider.ex` — Remove `user_id` from cast
   - `admin_note.ex` — Remove `user_id`, `author_id` from cast (2 pairs)
   - `role_permission.ex` — Remove `role_id`, `granted_by` from cast (2 pairs)
   - `audit_log/entry.ex` — Remove `target_user_id`, `admin_user_id` from cast (2 pairs)

### Priority 2: Medium Impact (Module Schemas)

5. **Posts Module** (9 schemas)
   - All `*_like`, `*_dislike`, `post_comment`, `post_mention`, `post_view` — Remove `user_id` from cast
   - `post.ex`, `post_group.ex` — Remove `user_id` from cast (Pattern 2 tables with UUID PK)

6. **Other Modules**
   - `comments/comment.ex` — Remove `user_id` from cast
   - `legal/consent_log.ex` — Remove `user_id` from cast (note: custom validator checks `user_id OR user_uuid OR session_id`)
   - `publishing_post.ex` — Remove `created_by_id`, `updated_by_id` from cast
   - `publishing_version.ex` — Remove `created_by_id` from cast
   - `storage/file.ex` — Remove `user_id` from cast

7. **Context function cleanup**
   - `ai/ai.ex` — Remove integer overloads from `maybe_filter_by/3` (`:endpoint_id` and `:user_id`)
   - `sync/transfers.ex` — Remove integer overload from `filter_by_connection/2`
   - `entities/entity_data.ex` — Remove integer overloads from `list_by_entity/1`, `list_by_entity_and_status/2`, `count_by_entity/1`

### Priority 3: Action Required (Missing UUID Field)

8. **`scheduled_jobs/scheduled_job.ex`** — `created_by_id` exists but **`created_by_uuid` is missing entirely**. Needs schema field addition and possibly a migration column addition if DB column doesn't exist.

---

## Files to Modify

### Schemas — Remove `_id` from `cast()` (30 files):

**Already cleaned (3 files — no action needed):**
```
lib/modules/billing/schemas/order.ex          # user_id already removed from cast
lib/modules/comments/schemas/comment_dislike.ex  # user_id already removed from cast
lib/modules/comments/schemas/comment_like.ex     # user_id already removed from cast
```

**Need cleanup (27 files):**
```
lib/modules/billing/schemas/invoice.ex
lib/modules/billing/schemas/billing_profile.ex
lib/modules/billing/schemas/payment_method.ex
lib/modules/billing/schemas/subscription.ex
lib/modules/billing/schemas/transaction.ex
lib/modules/comments/schemas/comment.ex
lib/modules/legal/schemas/consent_log.ex
lib/modules/posts/schemas/comment_dislike.ex
lib/modules/posts/schemas/comment_like.ex
lib/modules/posts/schemas/post_comment.ex
lib/modules/posts/schemas/post_dislike.ex
lib/modules/posts/schemas/post.ex
lib/modules/posts/schemas/post_group.ex
lib/modules/posts/schemas/post_like.ex
lib/modules/posts/schemas/post_mention.ex
lib/modules/posts/schemas/post_view.ex
lib/modules/publishing/schemas/publishing_post.ex
lib/modules/publishing/schemas/publishing_version.ex
lib/modules/referrals/schemas/referral_code_usage.ex
lib/modules/shop/schemas/cart.ex
lib/modules/shop/schemas/cart_item.ex
lib/modules/shop/schemas/category.ex
lib/modules/shop/schemas/import_log.ex
lib/modules/shop/schemas/product.ex
lib/modules/storage/schemas/file.ex
lib/phoenix_kit/users/oauth_provider.ex
lib/phoenix_kit/users/admin_note.ex
lib/phoenix_kit/users/role_permission.ex
lib/phoenix_kit/audit_log/entry.ex
```

**Needs UUID field added first (1 file):**
```
lib/phoenix_kit/scheduled_jobs/scheduled_job.ex  # created_by_uuid missing entirely
```

**Special case — no changeset (manual struct construction):**
```
lib/phoenix_kit/users/auth/user_token.ex  # user_id populated manually in build_*_token functions
```

### Context Modules — Remove integer ID support (6 files):

```
lib/modules/billing/billing.ex       # create_order, create_subscription, resolve_plan_uuid
lib/modules/shop/shop.ex             # filter_by_category, filter_by_parent, category_product_options_query
lib/modules/ai/ai.ex                 # maybe_filter_by :endpoint_id, :user_id
lib/modules/sync/transfers.ex        # filter_by_connection
lib/modules/entities/entity_data.ex  # list_by_entity, list_by_entity_and_status, count_by_entity
```

---

## Migration Needed?

**Mostly no** — this is primarily code cleanup. The V62 migration already added `_uuid` columns for nearly all schemas. This audit is about:
1. Removing `_id` fields from changesets (stop writing to them)
2. Removing `_id` field declarations (they're already optional in DB)
3. Updating context functions to use UUIDs only

**Exception:** `scheduled_job.ex` has `created_by_id` but **no `created_by_uuid` field or DB column**. This needs either a V63 migration to add the column, or a schema-only field addition if the column already exists in DB.

After code cleanup, a future migration can drop the `_id` columns entirely.

---

## Estimated Effort

- **Schemas:** 27 files need `_id` removed from cast, 1-2 lines each
- **Core schemas:** 4 additional files (oauth_provider, admin_note, role_permission, audit_log)
- **Context functions:** ~15 functions across 5 modules to remove integer overloads
- **Special cases:** `scheduled_job.ex` needs UUID field added; `user_token.ex` needs manual struct construction updated; `consent_log.ex` has custom validator to update
- **Tests:** May need updates if they pass integer IDs
- **Total:** ~4-6 hours of work

---

## Appendix: Core PhoenixKit Schemas

These schemas in `lib/phoenix_kit/` also have legacy `_id` fields:

| Schema | Legacy `_id` Fields | Has `_uuid` FK? | `_id` in cast? | Notes |
|--------|---------------------|-----------------|----------------|-------|
| `scheduled_jobs/scheduled_job.ex` | `created_by_id` (line 48) | ❌ **NO `_uuid` field** | ✅ Yes (line 67) | **Needs UUID field + possible migration** |
| `users/oauth_provider.ex` | `user_id` (line 20) | ✅ `user_uuid` (line 21) | ✅ Yes (line 40) | Dual-write |
| `users/admin_note.ex` | `user_id` (line 42), `author_id` (line 49) | ✅ Both have `_uuid` belongs_to | ✅ All 4 in cast (line 66) | Dual-write |
| `users/role_permission.ex` | `role_id` (line 41), `granted_by` (line 38) | ✅ Both have `_uuid` | ✅ All 4 in cast (line 52) | Dual-write |
| `users/auth/user_token.ex` | `user_id` (line 50) | ✅ `user_uuid` (lines 52-55) | N/A — no changeset | Manual struct construction in `build_*_token` functions |
| `audit_log/entry.ex` | `target_user_id` (line 51), `admin_user_id` (line 53) | ✅ Both have `_uuid` fields (lines 52, 54) | ✅ All 4 in cast (lines 79-82) | Dual-write |

> ⚠️ **Critical correction:** Original audit claimed `scheduled_job.ex` has `created_by_uuid` added in V61 — this is **wrong**. The schema has only `created_by_id` with no UUID counterpart at all. This is the only schema where the UUID field is genuinely missing.

---

## Related PRs

- PR #365 — UUID field fixes (Storage, Posts, Publishing, Comments, Tickets)
- Latest commits — Removed `billing_profile_id` support
- This audit — Documents remaining cleanup needed

---

## Verification Corrections Summary (2026-02-25)

Corrections applied after verifying all findings against current codebase:

| # | Original Claim | Correction |
|---|---------------|------------|
| 1 | `cart_item.ex` — "No _id in changeset (GOOD)" | **Wrong.** Both `cart_id` and `product_id` are still cast (lines 83-86) |
| 2 | `cart.ex` — "shipping_method_id has no _uuid counterpart" | **Wrong.** `shipping_method_uuid` exists as `belongs_to` (lines 49-52), covered by V62 |
| 3 | `create_subscription/2` — "Removed in latest commit" | **Wrong.** Still exists at line 2858, accepts integer `user_id` |
| 4 | `resolve_*_uuid` helpers — "Removed in latest commit" | **Wrong.** `resolve_plan_uuid/1` still exists at line 3322 |
| 5 | `shop.ex` line ~1315 — "filter_by_category" | **Wrong function name.** Actual function is `category_product_options_query/1` |
| 6 | `ai.ex` `maybe_filter_by/3` — only `endpoint_id` mentioned | **Incomplete.** Also has `:user_id` overload at lines 1250-1259 |
| 7 | `scheduled_job.ex` — "`created_by_uuid` (V61 added)" | **Wrong.** No `created_by_uuid` field exists in schema at all |
| 8 | Category 2 title — "No `_uuid` Field Declaration" | **Misleading.** Nearly all have `_uuid` equivalents and still cast `_id` |
| 9 | `post_view.ex` `session_id` listed as legacy FK | **Not a FK.** It's `field :session_id, :string` for view deduplication |
| 10 | `post.ex`, `post_group.ex` — "(check)" | **Verified.** Both have `user_id` in cast alongside `user_uuid` |

---

## Update: Comprehensive Analysis

**See also:** `dev_docs/audits/2026-02-26-comprehensive-uuid-cleanup-analysis.md` for a complete, up-to-date analysis including:

- Detailed findings by module
- Priority rankings for cleanup tasks
- Verification tools and commands
- Migration strategy recommendations
- Estimated effort breakdown

The comprehensive analysis provides actionable insights and specific file lists for immediate cleanup work.
