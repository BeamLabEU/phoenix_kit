# PR #311: Add UUID columns to AI module tables

**Author**: @mdon
**Reviewer**: @claude
**Status**: ✅ Merged
**Commit**: `d246aef..083d9a4`
**Date**: 2026-01-XX

**Follow-up PR**: [#312](https://github.com/BeamLabEU/phoenix_kit/pull/312) - Clarify AI module ID naming convention

## Goal

Enable UUID support for AI module schemas (Endpoint, Prompt, Request) as part of the V40 migration strategy. This allows parent applications to use UUIDs in URLs for security (non-enumerable) while maintaining full backward compatibility with existing integer ID-based code.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/modules/ai/endpoint.ex` | Added `field :uuid, Ecto.UUID` and `maybe_generate_uuid/1` changeset helper |
| `lib/modules/ai/prompt.ex` | Added `field :uuid, Ecto.UUID` and `maybe_generate_uuid/1` changeset helper |
| `lib/modules/ai/request.ex` | Added `field :uuid, Ecto.UUID` and `maybe_generate_uuid/1` changeset helper |

### Schema Changes

```elixir
# Added to all three schemas:
schema "phoenix_kit_ai_*" do
  field :uuid, Ecto.UUID  # NEW
  # ... existing fields
end

# Changeset now generates UUIDv7:
defp maybe_generate_uuid(changeset) do
  case get_field(changeset, :uuid) do
    nil -> put_change(changeset, :uuid, UUIDv7.generate())
    _ -> changeset
  end
end
```

## Implementation Details

- **UUIDv7 format**: Time-ordered UUIDs for better index performance (vs random UUIDv4)
- **Non-breaking**: Integer `id` remains the primary key; existing code continues to work
- **Elixir-side generation**: UUIDs generated in changeset, not DB default (consistent with other schemas)
- **Foreign keys unchanged**: All FK relationships still use integer IDs internally
- **Backward compatibility**: Existing records will get UUIDs via the V40 migration's backfill

## Testing

- [x] Schema tests pass
- [x] Changeset validation tests pass
- [x] V40 migration handles AI tables correctly
- [x] Backward compatibility verified (existing integer ID lookups work)

## Migration Notes

No action required for parent applications. The V40 migration automatically:
1. Adds `uuid` column to AI tables
2. Backfills existing records with UUIDv7 values
3. Creates unique index on `uuid` column

To use UUIDs in your application:

```elixir
# Lookup by UUID instead of integer ID
endpoint = PhoenixKit.UUID.get(PhoenixKit.Modules.AI.Endpoint, "019b5704-...")
```

## Related

- V40 Migration: `lib/phoenix_kit/migrations/postgres/v40.ex`
- UUID Helper: `lib/phoenix_kit/uuid.ex`
- Migration Guide: `dev_docs/guides/2025-12-25-uuid-migration.md`
- Tables affected: `phoenix_kit_ai_endpoints`, `phoenix_kit_ai_prompts`, `phoenix_kit_ai_requests`

---

## Follow-up: PR #312

PR #311's initial implementation used confusing terminology (`id`/`legacy_id`) that was corrected in [PR #312](https://github.com/BeamLabEU/phoenix_kit/pull/312).

### What PR #312 Fixed

- **Naming clarity**: Changed from `id`/`legacy_id` to `id`/`uuid`
- **7 bugs fixed**: UUID queries, HEEx interpolation, string/int comparison, validation
- **UI cleanup**: Removed ID badge displays from lists
- **New utility**: `PhoenixKit.Utils.UUID.valid?/1` for shared UUID validation

### Current ID System (Post-PR #312)

```elixir
schema "phoenix_kit_ai_endpoints" do
  # id = standard integer primary key (auto-increment)
  # uuid = UUID field for external references (URLs, APIs)
  field :uuid, Ecto.UUID, read_after_writes: true
  # ...
end
```

| Use Case | Field |
|----------|-------|
| URLs and external APIs | `.uuid` |
| Foreign keys | `.id` |
| Database queries | `.id` |
| Stats map keys | `.id` |

See [AI_REVIEW.md](AI_REVIEW.md) for detailed verification results.
