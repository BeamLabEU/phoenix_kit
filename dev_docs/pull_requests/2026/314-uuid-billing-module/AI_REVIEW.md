# PR #314: Update billing module to use DB-generated UUIDs

**Author**: @mdon
**Reviewer**: Claude Opus 4.5
**Status**: ✅ Approved
**Date**: 2026-02-03

## Goal

Migrate the Billing module from app-generated UUIDs (`maybe_generate_uuid`) to database-generated UUIDs using PostgreSQL triggers with `read_after_writes: true`. This aligns the Billing module with the new UUID standard established in PRs #311 and #313.

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

### API Changes

8 get functions now accept both integer IDs and UUIDs:

| Function | Change |
|----------|--------|
| `get_billing_profile/1` | Accepts integer ID or UUID string |
| `get_currency/1` | Accepts integer ID or UUID string |
| `get_order/2` | Accepts integer ID or UUID string |
| `get_invoice/2` | Accepts integer ID or UUID string |
| `get_transaction/2` | Accepts integer ID or UUID string |
| `get_subscription/2` | Accepts integer ID or UUID string |
| `get_subscription_plan/1` | Accepts integer ID or UUID string |
| `get_payment_method/1` | Accepts integer ID or UUID string |

## Implementation Details

### Lookup Pattern (Consistent Across All Functions)

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

### Bang Functions

All `!` variants now delegate to non-bang versions:

```elixir
def get_currency!(id) do
  case get_currency(id) do
    nil -> raise Ecto.NoResultsError, queryable: Currency
    currency -> currency
  end
end
```

### Bug Fix

Fixed `CountryData.get_subdivision_label/1` KeyError when `BeamLabCountries.Country` struct lacks `subdivision_type` field:

```elixir
# Before
country.subdivision_type || "State/Province"

# After
Map.get(country, :subdivision_type) || "State/Province"
```

## Review Assessment

### Positives

1. **Consistent pattern** across all 8 get functions
2. **Clean removal** of `maybe_generate_uuid` from all 10 schemas
3. **Correct use** of `read_after_writes: true` for DB-generated UUIDs
4. **Proper guards** (`when is_integer(id)`, `when is_binary(id)`)
5. **Fallback handling** for string IDs that could be integers
6. **Documentation updated** to reflect "by ID or UUID"
7. **Backwards compatible** - existing integer ID lookups continue to work
8. **Functions with preloads** handle options correctly in both branches

### Observations

- `get_subscription_plan/1` returns `{:ok, plan}` / `{:error, :plan_not_found}` (tuple pattern) while other functions return entity or `nil`. This is intentionally preserved for backwards compatibility.

### Verdict

**Approved.** The implementation follows project guidelines from CLAUDE.md, is consistent across all schemas and functions, and maintains backwards compatibility.

## Testing

- [x] Follows established UUID pattern from CLAUDE.md
- [x] All schemas consistently updated
- [x] Bang functions properly raise on not found
- [x] Backwards compatible with integer ID lookups
- [x] Documentation updated (uuid_module_status.md)

## Related

- Previous PR: [#311 - AI Module UUID](/dev_docs/pull_requests/2026/311-uuid-ai-module/)
- Previous PR: [#313 - Entities Module UUID](/dev_docs/pull_requests/2026/313-uuid-entities-module/)
- Documentation: `dev_docs/uuid_module_status.md`
