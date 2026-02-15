# PR #318: Add PubSub events for Tickets and Shop modules, User Deletion API

**Author**: @timujinne
**Reviewer**: Claude Opus 4.5
**Status**: ✅ Merged
**Date**: 2026-02-04

## Goal

Add PubSub event broadcasting for real-time updates across Tickets, Shop, and Billing modules, implement a GDPR-compliant User Deletion API with proper cascade handling and data anonymization, and fix cart items unique constraint to allow same product with different options.

## What Was Changed

### Files Modified (28 files, +2370/-61)

| File | Change |
|------|--------|
| `lib/modules/tickets/events.ex` | New PubSub events module for tickets |
| `lib/modules/tickets/tickets.ex` | Integrate events in CRUD operations |
| `lib/modules/tickets/web/details.ex` | Real-time ticket detail updates |
| `lib/modules/tickets/web/list.ex` | Real-time ticket list updates |
| `lib/modules/tickets/web/user_list.ex` | Real-time user ticket list |
| `lib/modules/tickets/web/new.ex` | New ticket creation LiveView |
| `lib/modules/shop/events.ex` | Extended with product/category/inventory events |
| `lib/modules/shop/shop.ex` | Integrate events + transaction-safe cart conversion |
| `lib/modules/shop/web/*.ex` | Real-time handlers in Products, Categories, CatalogProduct |
| `lib/modules/billing/events.ex` | New subscription/transaction/credit note events |
| `lib/modules/billing/billing.ex` | Integrate billing events |
| `lib/phoenix_kit/users/auth.ex` | User Deletion API (+411 lines) |
| `lib/phoenix_kit/admin/events.ex` | Add `broadcast_user_deleted/1` |
| `lib/phoenix_kit/migrations/postgres/v51.ex` | Cart constraint fix + FK changes |
| `lib/phoenix_kit_web/live/users/*.ex` | Admin UI for user deletion |

### Migration Changes (V51)

```sql
-- Cart items: Allow same product with different options
CREATE UNIQUE INDEX idx_shop_cart_items_unique
ON phoenix_kit_shop_cart_items(
  cart_id,
  product_id,
  MD5(COALESCE(selected_specs::text, '{}'))
)
WHERE variant_id IS NULL;

-- FK changes for user deletion
ALTER TABLE phoenix_kit_orders ... ON DELETE SET NULL;
ALTER TABLE phoenix_kit_billing_profiles ... ON DELETE SET NULL;
ALTER TABLE phoenix_kit_tickets ... ON DELETE SET NULL;
```

### API Changes

| Function | Description |
|----------|-------------|
| `Auth.delete_user/2` | Delete user with cascade and anonymization |
| `Auth.can_delete_user?/2` | Check deletion permissions |
| `Tickets.Events.*` | Full ticket lifecycle event broadcasting |
| `Shop.Events.*` | Product, category, inventory events |
| `Billing.Events.*` | Subscription, transaction, credit note events |

## Implementation Details

### 1. PubSub Architecture

**Consistent topic naming across modules:**

```elixir
# Tickets
"tickets:all"                    # Admin view
"tickets:user:{user_id}"         # User's tickets
"tickets:{id}"                   # Specific ticket

# Shop
"shop:products"                  # All products
"shop:products:{product_id}"     # Specific product
"shop:categories"                # All categories
"shop:inventory"                 # Inventory updates

# Billing
"phoenix_kit:billing:orders"
"phoenix_kit:billing:subscriptions"
"phoenix_kit:billing:transactions"
```

**Event payload patterns:**

```elixir
{:ticket_created, ticket}
{:ticket_status_changed, ticket, old_status, new_status}
{:product_updated, product}
{:subscription_cancelled, subscription}
```

### 2. User Deletion API

**Protection rules:**
1. Cannot delete self (prevents accidental self-deletion)
2. Cannot delete last Owner (system must have at least one)
3. Only Owner can delete Admin users
4. Admin/Owner required for any deletion

**Data handling strategy:**

| Data Type | Action | Reason |
|-----------|--------|--------|
| User tokens | CASCADE | Auth data not needed |
| OAuth providers | DELETE | No longer needed |
| Billing profiles | DELETE | Sensitive financial info |
| Shop carts | DELETE | No longer relevant |
| Admin notes | DELETE | Internal notes |
| **Orders** | SET NULL | Preserve financial records |
| **Posts** | SET NULL + `author_deleted: true` | Preserve content |
| **Comments** | SET NULL + `author_deleted: true` | Preserve discussions |
| **Tickets** | SET NULL + `anonymized_at` | Preserve support history |
| **Email logs** | SET NULL | Compliance retention |
| **Files** | SET NULL | Preserve uploaded content |

### 3. Dynamic Module Detection

Clever use of `Code.ensure_loaded?/1` for optional module support:

```elixir
defp anonymize_user_orders(user_id) do
  module = Module.concat([PhoenixKit, Modules, Shop, Order])

  if Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) do
    dynamic_query = dynamic([o], o.user_id == ^user_id)
    from(o in module, where: ^dynamic_query)
    |> Repo.repo().update_all(set: [user_id: nil, anonymized_at: DateTime.utc_now()])
    |> elem(0)
  else
    0
  end
rescue
  _ -> 0
end
```

### 4. Transaction Safety Fix

Cart-to-order conversion wrapped in transaction:

```elixir
def convert_cart_to_order(%Cart{} = cart, opts) do
  repo().transaction(fn ->
    with :ok <- validate_cart_convertible(cart),
         {:ok, cart} <- try_lock_cart_for_conversion(cart),
         # ... rest of conversion
    do
      {:ok, order}
    else
      error -> repo().rollback(error)
    end
  end)
end
```

### 5. Internal Notes Security

Internal notes don't broadcast to user topic:

```elixir
def broadcast_internal_note_created(comment, ticket) do
  # Internal notes only broadcast to admin topic and ticket topic
  # (not to user's personal topic since they shouldn't see internal notes)
  broadcast(@all_topic, message)
  broadcast(ticket_topic(ticket.id), message)
  # Note: user_topic NOT called
end
```

## Review Assessment

### Positives

1. **Comprehensive PubSub system** - Consistent patterns across Tickets, Shop, and Billing modules
2. **Security-conscious design** - Internal notes don't leak to users, proper deletion protections
3. **GDPR compliance** - Proper anonymization vs deletion strategy
4. **Transaction safety** - Cart conversion wrapped in transaction prevents partial orders
5. **Real-time UX** - LiveViews properly subscribe/unsubscribe and handle events
6. **Defensive coding** - `Code.ensure_loaded?` checks for optional modules with rescue fallbacks
7. **Good separation** - Events module separate from context module
8. **Audit logging** - User deletion logged with metadata

### Concerns

1. **No rate limiting on user deletion** - Could add Hammer-based rate limiting to prevent abuse:
   ```elixir
   # Suggested addition
   def delete_user(%User{} = user, opts) do
     with {:ok, _} <- check_rate_limit("user_deletion", opts[:current_user].id),
          :ok <- validate_can_delete_user(user, opts[:current_user]),
          ...
   ```

2. **Missing `connected?(socket)` checks** in some mounts - The Tickets detail view subscribes without checking if connected:
   ```elixir
   # In details.ex - should wrap in connected? check
   Events.subscribe_to_ticket(ticket.id)
   ```
   Most other views correctly use `if connected?(socket)`.

3. **Duplicate flash messages** - `handle_info({:user_deleted, ...})` in users.ex adds flash, but the deletion handler already shows a flash. This could result in double notifications.

4. **`Repo.repo()` pattern** - Some places use `Repo.repo().delete_all()` which is unusual. The standard pattern is just `repo().delete_all()`.

5. **Application module placeholder** - `lib/phoenix_kit/application.ex` is just a placeholder that starts an empty supervisor. Consider removing if not needed.

### Minor Observations

- Good use of `dynamic/2` to fix compilation errors with module variables in queries
- Proper handling of bulk updates with `ticket_matches_filters?/2` for list filtering
- Delete confirmation modal is informative with clear data handling explanations
- `subscribe_tickets/0` alias for `subscribe_to_all/0` improves API consistency

### Verdict

**Approved.** This is a substantial and well-architected PR that adds important real-time capabilities and GDPR-compliant user deletion. The concerns noted are minor and don't block the merge.

## Testing

- [x] Pre-commit checks passed (format, credo, dialyzer)
- [x] Compilation successful
- [x] User Deletion API manually tested
- [x] PubSub events manually tested
- [x] 35 existing tests pass

## Related

- Migration: `lib/phoenix_kit/migrations/postgres/v51.ex`
- Tickets Events: `lib/modules/tickets/events.ex`
- Shop Events: `lib/modules/shop/events.ex`
- Billing Events: `lib/modules/billing/events.ex`
- User Deletion: `lib/phoenix_kit/users/auth.ex:2098-2767`
