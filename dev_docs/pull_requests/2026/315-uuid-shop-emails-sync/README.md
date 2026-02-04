# PR #315: Update Shop, Emails, and Sync modules to new UUID standard

**Author**: @mdon
**Reviewer**: @claude
**Status**: Merged
**Commit**: `1091127f` (merge), `385790ad` (final)
**Date**: 2026-02-03

**Related PRs**: [#311](https://github.com/BeamLabEU/phoenix_kit/pull/311), [#313](https://github.com/BeamLabEU/phoenix_kit/pull/313), [#314](https://github.com/BeamLabEU/phoenix_kit/pull/314) - Previous UUID migrations

## Goal

Migrate three modules (Shop, Emails, Sync) totaling 13 schemas from app-generated UUIDs (`maybe_generate_uuid`) to database-generated UUIDs using PostgreSQL triggers with `read_after_writes: true`. This continues the UUID standardization effort across PhoenixKit modules.

## What Was Changed

### Summary by Module

| Module | Schemas | Files Changed |
|--------|---------|---------------|
| Shop | 7 | 8 files |
| Emails | 4 | 5 files |
| Sync | 2 | 4 files |
| **Total** | **13** | **17 files** |

### Files Modified

#### Shop Module (8 files)

| File | Change |
|------|--------|
| `lib/modules/shop/shop.ex` | Added UUIDUtils alias, updated 4 get functions for dual ID/UUID lookup |
| `lib/modules/shop/schemas/cart.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/shop/schemas/cart_item.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/shop/schemas/category.ex` | `read_after_writes: true` |
| `lib/modules/shop/schemas/product.ex` | `read_after_writes: true` |
| `lib/modules/shop/schemas/shipping_method.ex` | `read_after_writes: true` |
| `lib/modules/shop/schemas/import_config.ex` | `read_after_writes: true`, removed `generate_uuid` |
| `lib/modules/shop/schemas/import_log.ex` | `read_after_writes: true`, removed `generate_uuid` |

#### Emails Module (5 files)

| File | Change |
|------|--------|
| `lib/modules/emails/event.ex` | `read_after_writes: true`, removed `maybe_generate_uuid`, added `get_event/1` |
| `lib/modules/emails/log.ex` | `read_after_writes: true`, removed `maybe_generate_uuid`, added `get_log/1` |
| `lib/modules/emails/rate_limiter.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/emails/template.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |

#### Sync Module (4 files)

| File | Change |
|------|--------|
| `lib/modules/sync/connection.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/sync/connections.ex` | Added UUIDUtils alias, added flexible `get_connection/1` |
| `lib/modules/sync/transfer.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/sync/transfers.ex` | Added UUIDUtils alias, added flexible `get_transfer/1` |

### Schema Changes

```elixir
# Before (all 13 schemas)
field :uuid, Ecto.UUID
# ... in changeset
|> maybe_generate_uuid()

defp maybe_generate_uuid(changeset) do
  case get_field(changeset, :uuid) do
    nil -> put_change(changeset, :uuid, UUIDv7.generate())  # or Ecto.UUID.generate()
    _ -> changeset
  end
end

# After (all 13 schemas)
field :uuid, Ecto.UUID, read_after_writes: true
# maybe_generate_uuid function removed entirely
```

### Lookup Function Updates

New flexible get functions added:

```elixir
# Shop module - 4 functions updated
get_product/2, get_category/2, get_shipping_method/1, get_cart/1

# Emails module - 2 functions added
get_event/1, get_log/1

# Sync module - 2 functions added
get_connection/1, get_transfer/1
```

Pattern used consistently:

```elixir
def get_something(id) when is_integer(id), do: repo().get(Schema, id)

def get_something(id) when is_binary(id) do
  if UUIDUtils.valid?(id) do
    repo().get_by(Schema, uuid: id)
  else
    case Integer.parse(id) do
      {int_id, ""} -> get_something(int_id)
      _ -> nil
    end
  end
end

def get_something(_), do: nil
```

## Implementation Details

- **DB-generated UUIDs**: Uses `read_after_writes: true` so database generates UUIDv7 via trigger/default
- **Removed app-side generation**: `maybe_generate_uuid/1` and `generate_uuid/1` functions deleted
- **Flexible lookups**: Get functions accept integer, UUID string, or integer string
- **Shared UUID validation**: Uses `PhoenixKit.Utils.UUID.valid?/1`
- **Bang functions refactored**: Now delegate to non-bang versions and raise `Ecto.NoResultsError`

### Functions Updated/Added

| Module | Function | Notes |
|--------|----------|-------|
| Shop | `get_product/2` | Handles preload option |
| Shop | `get_category/2` | Handles preload option |
| Shop | `get_shipping_method/1` | Simple lookup |
| Shop | `get_cart/1` | Preloads items, shipping_method, payment_option |
| Emails | `get_event/1` | Preloads email_log |
| Emails | `get_log/1` | Preloads user, events |
| Sync | `get_connection/1` | Simple lookup |
| Sync | `get_transfer/1` | Simple lookup |

## Review Notes

### Post-merge fix (commit `8f73f56f`)

Fixed duplicate docstrings in Emails module:
- `get_event!/1` and `get_log!/1` had identical docs to their non-bang counterparts
- Changed to "Same as `get_*/1`, but raises `Ecto.NoResultsError` if not found"

## Testing

- [x] Compilation successful
- [x] Follows established UUID pattern from CLAUDE.md
- [x] All 13 schemas consistently updated
- [x] Bang functions properly raise on not found
- [x] Backward compatibility maintained (integer ID lookups work)
- [x] Documentation updated (uuid_module_status.md)
- [x] Docstring duplication fixed

## Migration Notes

No migration required - the existing migrations already added `uuid` columns to these tables with DB triggers for UUIDv7 generation. This PR updates the schema definitions and lookup functions to use them properly.

## Schemas Updated

### Shop Module (7 schemas)
1. `cart.ex` - `phoenix_kit_shop_carts`
2. `cart_item.ex` - `phoenix_kit_shop_cart_items`
3. `category.ex` - `phoenix_kit_shop_categories`
4. `product.ex` - `phoenix_kit_shop_products`
5. `shipping_method.ex` - `phoenix_kit_shop_shipping_methods`
6. `import_config.ex` - `phoenix_kit_shop_import_configs`
7. `import_log.ex` - `phoenix_kit_shop_import_logs`

### Emails Module (4 schemas)
1. `event.ex` - `phoenix_kit_email_events`
2. `log.ex` - `phoenix_kit_email_logs`
3. `rate_limiter.ex` - `phoenix_kit_email_blocklist`
4. `template.ex` - `phoenix_kit_email_templates`

### Sync Module (2 schemas)
1. `connection.ex` - `phoenix_kit_sync_connections`
2. `transfer.ex` - `phoenix_kit_sync_transfers`

## Remaining Work

After this PR, only 2 modules with 3 schemas remain on the old pattern:
- **Referrals** (2 schemas) - Low priority
- **Legal** (1 schema) - Low priority

## Related

- AI Module UUID: PR #311, #312
- Entities Module UUID: PR #313
- Billing Module UUID: PR #314
- UUID Utility: `lib/phoenix_kit/utils/uuid.ex`
- Status Tracking: `dev_docs/uuid_module_status.md`
