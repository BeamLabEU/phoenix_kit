# UUIDv7 Migration Summary - Critical Issues Found

**Last updated:** 2026-02-14 (post PR #337 merge)

## 🔍 Analysis Results

Found **50+ instances** of legacy `:id` field usage that need to be migrated to UUIDv7 across the PhoenixKit codebase.

## ✅ Resolved by PR #337

- **Connections module `type: :integer`** — Confirmed CORRECT. DB FKs are BIGINT. Not a bug.
- **Billing form assigns** — Renamed `*_id` → `*_uuid` in 3 form modules + templates.
- **13 LiveViews** — Applied `dashboard_assigns()` optimization.
- **16 alias-in-function-body** instances moved to module level.
- **New analysis:** `dev_docs/uuid_naming_convention_report.md` documents 25 Pattern 2 schemas (`@primary_key {:id, UUIDv7}`) — decision pending.

## 🚨 Remaining Issues by Category

### 1. **Schemas with Legacy ID Fields (20+ files)**
Schemas still using `field :id, :integer` instead of UUIDv7:

**Core System:**
- `lib/phoenix_kit/users/auth/user.ex` ⭐ HIGH PRIORITY
- `lib/phoenix_kit/users/role.ex`
- `lib/phoenix_kit/settings/setting.ex`

**Feature Modules:**
- `lib/modules/ai/endpoint.ex`, `prompt.ex`, `request.ex`
- `lib/modules/entities/entities.ex`, `entity_data.ex`
- `lib/modules/shop/schemas/product.ex`, `cart.ex`, `cart_item.ex`, `shipping_method.ex`
- `lib/modules/legal/schemas/consent_log.ex`

### 2. **Broken Relationships (4+ files)**

**~~🔴 Connections Module~~ ✅ NOT A BUG (PR #337):**
~~Uses `type: :integer`~~ — Confirmed correct. V36 migration created FK columns as BIGINT referencing `phoenix_kit_users(id)`. Dual-write `*_uuid` fields exist via V56. Will migrate to UUID FKs in Phase 4.

**🟡 Relationship Issues (Still Open):**
- `lib/modules/comments/schemas/comment.ex:64` - Uses `foreign_key: :parent_id`
- `lib/modules/tickets/ticket_comment.ex:88-89` - Uses `foreign_key: :parent_id` and `:comment_id`
- `lib/modules/sync/connection.ex:126-153` - Missing `references: :uuid` in 4 relationships

### 3. **Direct .id Access (15+ instances)**

**High Impact Areas:**
- `lib/modules/referrals/referrals.ex:415,819` - Referral code operations
- `lib/modules/referrals/web/form.ex:49,80,105,249,252` - Form handling
- `lib/mix/tasks/shop.deduplicate_products.ex:119,122,130,147` - Product deduplication
- `lib/mix/tasks/phoenix_kit/email_export.ex:176,253` - Email export
- `lib/phoenix_kit/admin/simple_presence.ex:59` - Presence tracking

## 🎯 Top Files to Fix Next

### ~~1. `lib/modules/connections/follow.ex`~~ ✅ NOT A BUG (PR #337)
~~Uses `type: :integer`~~ — Confirmed correct per V36 migration analysis. Integer FKs reference `phoenix_kit_users(id)` BIGINT column.

### ~~2. `lib/modules/connections/block.ex`~~ ✅ NOT A BUG (PR #337)
Same as above — `type: :integer` is correct.

### 1. **`lib/modules/comments/schemas/comment.ex`** ⭐ START HERE
```elixir
# PROBLEM: Wrong foreign key name
has_many :children, __MODULE__, foreign_key: :parent_id

# SOLUTION:
has_many :children, __MODULE__, foreign_key: :parent_uuid
```

### 2. **`lib/modules/referrals/referrals.ex`**
Multiple `.id` accesses in referral code operations

### 3. **`lib/modules/shop/schemas/product.ex`**
Still uses `field :id, :integer` - core ecommerce schema

## 📋 Migration Checklist

- [x] ~~Fix Connections module (follow, block, connection_history, block_history)~~ — NOT A BUG (PR #337)
- [x] Billing form assigns renamed `*_id` → `*_uuid` (PR #337)
- [x] 13 LiveViews: `dashboard_assigns()` optimization (PR #337)
- [x] 16 alias-in-function-body instances moved to module level (PR #337)
- [ ] Fix Comment and Ticket modules (foreign key naming: `parent_id` → `parent_uuid`)
- [ ] Fix Referrals module (`.id` access → `.uuid`)
- [ ] Fix Sync module (add missing `references: :uuid` to 4 belongs_to)
- [ ] Update all schemas to use `field :uuid, UUIDv7`
- [ ] Update all relationships to use `references: :uuid`
- [ ] Replace all `.id` with `.uuid` in code (email export, shop dedup, entities export, admin presence)
- [ ] Decide on Pattern 2 resolution for 25 schemas (see `dev_docs/uuid_naming_convention_report.md`)
- [ ] Test all relationships and queries

## 🔧 Quick Fix Pattern

**Before:**
```elixir
field :id, :integer
belongs_to :user, User, type: :integer
```

**After:**
```elixir
field :uuid, UUIDv7
belongs_to :user, User,
  foreign_key: :user_uuid,
  references: :uuid,
  type: UUIDv7
```

## ⚠️ Key Decisions Pending

### Pattern 2 Primary Key Naming (25 schemas)
25 schemas use `@primary_key {:id, UUIDv7, ...}` where the `id` column is actually a UUID. Four options documented in `dev_docs/uuid_naming_convention_report.md`:
- **Option A:** Full DB rename `id` → `uuid` (heavy migration, 27 tables, 50+ FKs)
- **Option B:** Schema-only fix with `source: :id` (no DB migration, recommended)
- **Option C:** Document and accept two patterns
- **Option D:** Fix going forward only

### Connections Module Phase 4
The integer FKs in connections (`requester_id`, `follower_id`, etc.) are correct today but need eventual migration to UUID FKs. Dual-write `*_uuid` fields are already in place via V56.