# PR #313: Update entities module to UUID standard matching AI module

**Author**: @mdon
**Reviewer**: @claude
**Status**: Merged
**Commit**: `aab1ef81`
**Date**: 2026-02-02

**Related PRs**: [#311](https://github.com/BeamLabEU/phoenix_kit/pull/311), [#312](https://github.com/BeamLabEU/phoenix_kit/pull/312) - AI module UUID implementation

## Goal

Bring the Entities module (`Entity` and `EntityData` schemas) in line with the UUID standard established in the AI module. This enables UUID-based lookups for external references (URLs, APIs) while maintaining full backward compatibility with integer primary keys.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/modules/entities/entities.ex` | UUID schema update, flexible `get_entity/1` lookup |
| `lib/modules/entities/entity_data.ex` | UUID schema update, flexible `get/1` lookup |
| `lib/modules/entities/web/data_form.ex` | Remove `String.to_integer` calls |
| `lib/modules/entities/web/data_navigator.ex` | Remove `String.to_integer` calls |
| `lib/modules/entities/web/data_view.ex` | Remove `String.to_integer` calls |
| `lib/modules/entities/web/entities.ex` | Remove `String.to_integer` calls |
| `lib/modules/entities/web/entities_settings.ex` | Remove `String.to_integer` calls |
| `lib/modules/entities/web/entity_form.ex` | Remove `String.to_integer` calls |

### Schema Changes

```elixir
# Entity schema
@derive {Jason.Encoder,
         only: [
           :id,      # NEW - added for JSON serialization
           :uuid,    # NEW - added for JSON serialization
           :name,
           # ... rest unchanged
         ]}

schema "phoenix_kit_entities" do
  # UUID for external references (URLs, APIs) - DB generates UUIDv7
  field :uuid, Ecto.UUID, read_after_writes: true  # CHANGED - added read_after_writes
  # ... rest unchanged
end

# Removed: maybe_generate_uuid/1 function (DB handles generation now)
```

### Lookup Function Updates

```elixir
# Now supports multiple ID types
def get_entity(id) when is_integer(id) do
  # Direct integer lookup
end

def get_entity(id) when is_binary(id) do
  if UUIDUtils.valid?(id) do
    # UUID lookup via :uuid field
  else
    # Parse string to integer and retry
  end
end

def get_entity(_), do: nil
```

## Implementation Details

- **DB-generated UUIDs**: Uses `read_after_writes: true` so database generates UUIDv7 via trigger/default, Ecto reads it back after insert
- **Removed app-side generation**: `maybe_generate_uuid/1` functions deleted from both schemas
- **Flexible lookups**: `get_entity/1` and `EntityData.get/1` accept integer, UUID string, or integer string
- **Shared UUID validation**: Uses `PhoenixKit.Utils.UUID.valid?/1` (created in PR #312)
- **Web layer simplified**: All `String.to_integer` calls removed - lookup functions handle type coercion
- **JSON serialization**: `:id` and `:uuid` added to `Jason.Encoder` for API responses

## ID System Usage

| Use Case | Field | Example |
|----------|-------|---------|
| URLs and external APIs | `.uuid` | `/entities/#{entity.uuid}/edit` |
| Foreign keys | `.id` | `entity_id: entity.id` |
| Database queries | `.id` | `repo.get(Entity, id)` |
| Stats map keys | `.id` | `Map.get(stats, entity.id)` |
| Event handlers (phx-value) | `.id` | `phx-value-id={entity.id}` |

## Testing

- [x] Compilation successful
- [x] Credo passes
- [x] Backward compatibility maintained (integer ID lookups work)
- [x] UUID lookups functional
- [x] Web layer handles both ID types transparently

## Migration Notes

No migration required - the V40 migration already added `uuid` columns to entity tables. This PR updates the schema definitions and lookup functions to use them properly.

## Improvements Over PR #311

This PR uses the improved pattern from PR #312:

| Aspect | PR #311 (AI Module Initial) | PR #313 (Entities) |
|--------|---------------------------|-------------------|
| UUID Generation | App-side via `maybe_generate_uuid/1` | DB-side with `read_after_writes: true` |
| UUID Validation | Regex pattern | `Ecto.UUID.cast/1` via `UUIDUtils.valid?/1` |
| Lookup Functions | Separate by type | Single function with pattern matching |

## Related

- AI Module UUID: PR #311, #312
- UUID Utility: `lib/phoenix_kit/utils/uuid.ex`
- V40 Migration: `lib/phoenix_kit/migrations/postgres/v40.ex`
- Tables affected: `phoenix_kit_entities`, `phoenix_kit_entity_data`
