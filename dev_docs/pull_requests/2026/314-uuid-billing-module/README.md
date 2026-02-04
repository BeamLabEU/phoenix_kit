# PR #314: Update billing module to use DB-generated UUIDs

**Author**: @mdon
**Reviewer**: @claude
**Status**: Merged
**Commit**: `28fee87d`
**Date**: 2026-02-03

**Related PRs**: [#311](https://github.com/BeamLabEU/phoenix_kit/pull/311), [#313](https://github.com/BeamLabEU/phoenix_kit/pull/313) - AI and Entities module UUID implementation

## Goal

Migrate the Billing module (10 schemas) from app-generated UUIDs (`maybe_generate_uuid`) to database-generated UUIDs using PostgreSQL triggers with `read_after_writes: true`. This aligns the Billing module with the UUID standard established in previous PRs.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/modules/billing/billing.ex` | Added UUIDUtils alias, updated 8 get functions for dual ID/UUID lookup |
| `lib/modules/billing/schemas/billing_profile.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/billing/schemas/currency.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/billing/schemas/invoice.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/billing/schemas/order.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/billing/schemas/payment_method.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/billing/schemas/payment_option.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/billing/schemas/subscription.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/billing/schemas/subscription_plan.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/billing/schemas/transaction.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/billing/schemas/webhook_event.ex` | `read_after_writes: true`, removed `maybe_generate_uuid` |
| `lib/modules/billing/utils/country_data.ex` | Bug fix for `subdivision_type` access |
| `dev_docs/uuid_module_status.md` | Updated module status documentation |

### Schema Changes

```elixir
# Before (all 10 schemas)
field :uuid, Ecto.UUID
# ... in changeset
|> maybe_generate_uuid()

defp maybe_generate_uuid(changeset) do
  case get_field(changeset, :uuid) do
    nil -> put_change(changeset, :uuid, UUIDv7.generate())
    _ -> changeset
  end
end

# After (all 10 schemas)
field :uuid, Ecto.UUID, read_after_writes: true
# maybe_generate_uuid function removed entirely
```

### Lookup Function Updates

8 get functions now accept both integer IDs and UUIDs:

```elixir
# Pattern used consistently across all functions
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

- **DB-generated UUIDs**: Uses `read_after_writes: true` so database generates UUIDv7 via trigger/default, Ecto reads it back after insert
- **Removed app-side generation**: `maybe_generate_uuid/1` functions deleted from all 10 schemas
- **Flexible lookups**: All 8 get functions accept integer, UUID string, or integer string
- **Shared UUID validation**: Uses `PhoenixKit.Utils.UUID.valid?/1`
- **Bang functions refactored**: Now delegate to non-bang versions and raise `Ecto.NoResultsError`
- **Preload handling**: Functions with preload options handle them correctly in both integer and UUID branches

### Functions Updated

| Function | Return Type |
|----------|-------------|
| `get_billing_profile/1` | `%BillingProfile{}` or `nil` |
| `get_currency/1` | `%Currency{}` or `nil` |
| `get_order/2` | `%Order{}` or `nil` |
| `get_invoice/2` | `%Invoice{}` or `nil` |
| `get_transaction/2` | `%Transaction{}` or `nil` |
| `get_subscription/2` | `%Subscription{}` or `nil` |
| `get_subscription_plan/1` | `{:ok, plan}` or `{:error, :plan_not_found}` |
| `get_payment_method/1` | `%PaymentMethod{}` or `nil` |

Note: `get_subscription_plan/1` uses tuple return for backwards compatibility.

### Bug Fix

Fixed `CountryData.get_subdivision_label/1` KeyError when `BeamLabCountries.Country` struct lacks `subdivision_type` field:

```elixir
# Before - direct struct access could crash
country.subdivision_type || "State/Province"

# After - safe map access
Map.get(country, :subdivision_type) || "State/Province"
```

## ID System Usage

| Use Case | Field | Example |
|----------|-------|---------|
| URLs and external APIs | `.uuid` | `/invoices/#{invoice.uuid}` |
| Foreign keys | `.id` | `order_id: order.id` |
| Database queries | `.id` | `repo.get(Order, id)` |
| Stats map keys | `.id` | `Map.get(stats, order.id)` |
| Event handlers (phx-value) | `.id` | `phx-value-id={order.id}` |

## Testing

- [x] Compilation successful
- [x] Follows established UUID pattern from CLAUDE.md
- [x] All 10 schemas consistently updated
- [x] Bang functions properly raise on not found
- [x] Backward compatibility maintained (integer ID lookups work)
- [x] Documentation updated (uuid_module_status.md)

## Migration Notes

No migration required - the existing migrations already added `uuid` columns to billing tables with DB triggers for UUIDv7 generation. This PR updates the schema definitions and lookup functions to use them properly.

## Schemas Updated

1. `billing_profile.ex` - `phoenix_kit_billing_profiles`
2. `currency.ex` - `phoenix_kit_currencies`
3. `invoice.ex` - `phoenix_kit_invoices`
4. `order.ex` - `phoenix_kit_orders`
5. `payment_method.ex` - `phoenix_kit_payment_methods`
6. `payment_option.ex` - `phoenix_kit_payment_options`
7. `subscription.ex` - `phoenix_kit_subscriptions`
8. `subscription_plan.ex` - `phoenix_kit_subscription_plans`
9. `transaction.ex` - `phoenix_kit_transactions`
10. `webhook_event.ex` - `phoenix_kit_webhook_events`

## Related

- AI Module UUID: PR #311, #312
- Entities Module UUID: PR #313
- UUID Utility: `lib/phoenix_kit/utils/uuid.ex`
- Status Tracking: `dev_docs/uuid_module_status.md`
