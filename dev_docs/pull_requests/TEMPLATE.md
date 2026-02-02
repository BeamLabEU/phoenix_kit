# PR #{number}: {title}

**Author**: @{username}  
**Reviewer**: @{reviewer}  
**Status**: 🔄 In Review / ✅ Merged / ❌ Closed  
**Commit**: `{commit_range}`  
**Date**: YYYY-MM-DD

## Goal

One paragraph explaining what this PR aims to achieve and why.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `path/to/file.ex` | Brief description of changes |
| `path/to/another.ex` | Brief description |

### Schema Changes (if applicable)

```elixir
# Before
field :status, :string

# After  
field :status, :string, default: "pending"
field :uuid, Ecto.UUID
```

### API Changes (if applicable)

| Endpoint | Change |
|----------|--------|
| `POST /api/users` | Added `uuid` field to response |

## Implementation Details

- Key technical decisions
- Design patterns used
- Performance considerations
- Security implications

## Testing

- [ ] Unit tests added/updated
- [ ] Integration tests pass
- [ ] Migration tested on staging
- [ ] Backward compatibility verified
- [ ] Documentation updated

## Migration Notes (if breaking)

```elixir
# For parent applications upgrading:
config :phoenix_kit, :feature_flag, true
```

## Related

- Migration: `path/to/migration.ex`
- Documentation: `path/to/guide.md`
- Previous PR: [#{number}](/docs/pull_requests/YYYY/{number}-slug/)
