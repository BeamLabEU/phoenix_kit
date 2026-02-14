# UUIDv7 Migration Summary - Critical Issues Found

## 🔍 Analysis Results

Found **50+ instances** of legacy `:id` field usage that need to be migrated to UUIDv7 across the PhoenixKit codebase.

## 🚨 Critical Issues by Category

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

### 2. **Broken Relationships (8+ files)**

**🔴 Connections Module - Most Critical:**
- `lib/modules/connections/follow.ex:45-46` - Uses `type: :integer`
- `lib/modules/connections/block.ex:50-51` - Uses `type: :integer`
- `lib/modules/connections/block_history.ex:22-23` - Uses `type: :integer`
- `lib/modules/connections/connection_history.ex:29-30` - Uses `type: :integer`

**🟡 Relationship Issues:**
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

## 🎯 Top 5 Files to Fix First

### 1. **`lib/modules/connections/follow.ex`** ⭐ START HERE
```elixir
# PROBLEM: Uses type: :integer instead of UUIDv7
belongs_to :follower, PhoenixKit.Users.Auth.User, type: :integer
belongs_to :followed, PhoenixKit.Users.Auth.User, type: :integer

# SOLUTION: Should be
belongs_to :follower, PhoenixKit.Users.Auth.User,
  foreign_key: :follower_uuid,
  references: :uuid,
  type: UUIDv7
```

### 2. **`lib/modules/connections/block.ex`**
Same issue as follow.ex - uses `type: :integer`

### 3. **`lib/modules/comments/schemas/comment.ex`**
```elixir
# PROBLEM: Wrong foreign key name
has_many :children, __MODULE__, foreign_key: :parent_id

# SOLUTION:
has_many :children, __MODULE__, foreign_key: :parent_uuid
```

### 4. **`lib/modules/referrals/referrals.ex`**
Multiple `.id` accesses in referral code operations

### 5. **`lib/modules/shop/schemas/product.ex`**
Still uses `field :id, :integer` - core ecommerce schema

## 📋 Migration Checklist

- [ ] Fix Connections module (follow, block, connection_history, block_history)
- [ ] Fix Comment and Ticket modules (foreign key naming)
- [ ] Fix Referrals module (.id access)
- [ ] Update all schemas to use `field :uuid, UUIDv7`
- [ ] Update all relationships to use `references: :uuid`
- [ ] Replace all `.id` with `.uuid` in code
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

## ⚠️ Warning

The Connections module is the most critical - it has explicit `type: :integer` relationships that will cause database errors when trying to join UUID fields with integer fields.

**Recommendation:** Start with `lib/modules/connections/follow.ex` as it's the simplest example of the pattern that needs fixing across all connection schemas.