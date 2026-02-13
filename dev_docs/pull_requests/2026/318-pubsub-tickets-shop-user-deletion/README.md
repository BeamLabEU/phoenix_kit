# PR #318: Add PubSub events for Tickets and Shop modules, User Deletion API

**Author**: @timujinne  
**Reviewer**: @claude  
**Status**: Merged  
**Commit**: `3a6bd51c` (merge)  
**Date**: 2026-02-04

## Goal

Add PubSub events for real-time updates in Tickets and Shop modules, implement User Deletion API with GDPR-compliant data handling, and fix compilation errors in auth.ex.

## What Was Changed

### Summary

| Area | Changes |
|------|---------|
| Tickets PubSub | New Events module with ticket lifecycle broadcasts |
| Shop PubSub | Extended with product, category, inventory events |
| Billing Events | New billing events module for orders, invoices, subscriptions |
| User Deletion API | GDPR-compliant deletion with cascade + anonymization |
| V51 Migration | Cart constraint fix + FK updates for user deletion |

### Files Modified (24 files)

| File | Additions | Deletions | Description |
|------|-----------|-----------|-------------|
| `lib/modules/tickets/events.ex` | +224 | - | New PubSub events module |
| `lib/modules/tickets/tickets.ex` | +51 | - | Event integration in CRUD |
| `lib/modules/tickets/web/details.ex` | +61 | - | Real-time detail view updates |
| `lib/modules/tickets/web/list.ex` | +102 | - | Real-time list updates |
| `lib/modules/tickets/web/new.ex` | +206 | - | New ticket creation LiveView |
| `lib/modules/tickets/web/new.html.heex` | +186 | - | Ticket form template |
| `lib/modules/tickets/web/user_list.ex` | +70 | - | User ticket list |
| `lib/modules/shop/events.ex` | +179 | - | Extended product/category/inventory events |
| `lib/modules/shop/shop.ex` | +90 | - | Event integration |
| `lib/modules/shop/web/catalog_product.ex` | +29 | - | Catalog event handlers |
| `lib/modules/shop/web/categories.ex` | +21 | - | Category event handlers |
| `lib/modules/shop/web/products.ex` | +32 | - | Product event handlers |
| `lib/modules/billing/events.ex` | +156 | - | New billing events module |
| `lib/modules/billing/billing.ex` | +60 | - | Billing event integration |
| `lib/modules/billing/web/subscriptions.ex` | +31 | - | Subscription event handlers |
| `lib/phoenix_kit/users/auth.ex` | +411 | - | User deletion API |
| `lib/phoenix_kit/admin/events.ex` | +8 | - | User deleted broadcast |
| `lib/phoenix_kit/migrations/postgres/v51.ex` | +235 | - | Migration for constraints and FKs |
| `lib/phoenix_kit/migrations/postgres.ex` | +4 | - | Register V51 migration |
| `lib/phoenix_kit_web/live/users/user_details.ex` | +40 | - | Delete handlers |
| `lib/phoenix_kit_web/live/users/user_details.html.heex` | +51 | - | Delete confirmation modal |
| `lib/phoenix_kit_web/live/users/users.ex` | +87 | - | Real-time deletion sync |
| `lib/phoenix_kit_web/live/users/users.html.heex` | +13 | - | Delete button |
| `lib/phoenix_kit_web/routes/tickets.ex` | +5 | - | New ticket route |
| `CHANGELOG.md` | +14 | - | Document changes |
| `mix.exs` | +1 | - | Version bump to 1.7.33 |

## Implementation Details

### 1. Tickets PubSub

**Topics:**
- `tickets:all` - All tickets (admin view)
- `tickets:user:{user_id}` - User's tickets
- `tickets:{id}` - Specific ticket

**Events:**
```elixir
{:ticket_created, ticket}
{:ticket_updated, ticket}
{:ticket_status_changed, ticket, old_status, new_status}
{:ticket_assigned, ticket, old_assignee_id, new_assignee_id}
{:ticket_priority_changed, ticket, old_priority, new_priority}
{:tickets_bulk_updated, tickets, changes}
{:comment_created, comment, ticket}
{:internal_note_created, comment, ticket}  # Not broadcast to user topic
```

**LiveView Integration:**
```elixir
def mount(_params, _session, socket) do
  Tickets.Events.subscribe_to_all()
  {:ok, socket}
end

def handle_info({:ticket_created, ticket}, socket) do
  # Prepend to stream or update UI
  {:noreply, stream_insert(socket, :tickets, ticket, at: 0)}
end
```

### 2. Shop PubSub Extension

**New Topics:**
- `shop:products` / `shop:products:{id}`
- `shop:categories`
- `shop:inventory`

**Events:**
```elixir
# Products
{:product_created, product}
{:product_updated, product}
{:product_deleted, product_id}
{:products_bulk_status_changed, product_ids, status}

# Categories
{:category_created, category}
{:category_updated, category}
{:category_deleted, category_id}

# Inventory
{:inventory_updated, product_id, stock_change}
```

### 3. Billing Events

**Topics:**
- `phoenix_kit:billing:orders`
- `phoenix_kit:billing:invoices`
- `phoenix_kit:billing:subscriptions`
- `phoenix_kit:billing:profiles`
- `phoenix_kit:billing:transactions`

All topics support user-specific subtopics (`:user:{user_id}`).

### 4. User Deletion API

**Function:**
```elixir
PhoenixKit.Users.Auth.delete_user(user, %{current_user: admin_user})
```

**Protections:**
| Check | Error |
|-------|-------|
| Cannot delete self | `{:error, :cannot_delete_self}` |
| Cannot delete last Owner | `{:error, :cannot_delete_last_owner}` |
| Non-Owner deleting Admin | `{:error, :insufficient_permissions}` |

**Data Strategy:**

| Data Type | Action |
|-----------|--------|
| OAuth providers | Cascade delete |
| Billing profiles | Cascade delete |
| Shop carts | Cascade delete |
| Admin notes | Cascade delete |
| Orders | Anonymize (user_id = NULL) |
| Posts | Anonymize + `author_deleted: true` |
| Comments | Anonymize + `author_deleted: true` |
| Tickets | Anonymize + `anonymized_at` |
| Email logs | Anonymize |
| Files | Anonymize |

**Compilation Fix:** Uses `Ecto.dynamic/2` for dynamic module queries:
```elixir
# Before (compilation error with pin operator)
from(o in module, where: o.user_id == ^user_id)

# After (fixed)
dynamic_query = dynamic([o], o.user_id == ^user_id)
from(o in module, where: ^dynamic_query)
```

### 5. V51 Migration

**Cart Items Constraint Fix:**
```sql
-- Old: prevented same product with different options
CREATE UNIQUE INDEX idx_shop_cart_items_unique ON ... (cart_id, product_id)

-- New: allows different options
CREATE UNIQUE INDEX idx_shop_cart_items_unique ON ... (
  cart_id, 
  product_id, 
  MD5(COALESCE(selected_specs::text, '{}'))
)
```

**FK Constraints for User Deletion:**
| Table | Old | New |
|-------|-----|-----|
| orders | RESTRICT | SET NULL |
| billing_profiles | CASCADE | SET NULL |
| tickets | DELETE_ALL | SET NULL |

## Code Quality Assessment

### Strengths

1. **Clean PubSub architecture** - Consistent topic naming, clear separation of concerns
2. **Security-conscious** - Internal notes don't leak to users, proper deletion protections
3. **GDPR compliant** - Proper data anonymization while preserving business records
4. **Real-time UX** - LiveViews subscribe/unsubscribe properly, handle events cleanly
5. **Database integrity** - Transaction-safe deletion with rollback on failure

### Minor Observations

1. **No unit tests** - New event modules and deletion API lack dedicated test coverage
2. **No telemetry** - Event broadcasts could include telemetry metrics
3. **Rate limiting** - User deletion could benefit from rate limiting to prevent abuse

## Testing

- [x] Pre-commit checks passed (`mix format`, `mix credo --strict`)
- [x] Compilation successful
- [x] 35 existing tests pass

## Commits (5)

1. `152ed9b0` - Add V51 migration to fix cart items unique constraint
2. `f728a462` - Fix transaction safety in cart-to-order conversion
3. `10c2c409` - Add PubSub events for Tickets and Shop modules, fix User Deletion compilation
4. `913b983c` - Update version to 1.7.33 and changelog
5. `3a6bd51c` - Merge pull request #318 from timujinne/dev

## Related

- Tickets Module: `lib/modules/tickets/`
- Shop Module: `lib/modules/shop/`
- Billing Module: `lib/modules/billing/`
- Auth Module: `lib/phoenix_kit/users/auth.ex`
- V51 Migration: `lib/phoenix_kit/migrations/postgres/v51.ex`
