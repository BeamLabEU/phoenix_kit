# PR #317: Added support for uuid to referral module

**Author**: @alexdont  
**Reviewer**: @claude  
**Status**: Merged  
**Commit**: `ed5e363d` (merge)  
**Date**: 2026-02-04

## Goal

Add UUID support to the Referrals module, enabling referral codes to be looked up by either integer ID or UUID string. This completes the UUID migration across all PhoenixKit modules with database schemas.

## What Was Changed

### Files Modified (4 files)

| File | Additions | Deletions | Description |
|------|-----------|-----------|-------------|
| `lib/modules/referrals/referrals.ex` | +42 | -3 | Added flexible `get_code/1` lookup |
| `lib/modules/referrals/schemas/referral_code_usage.ex` | +1 | -1 | Added `read_after_writes: true` |
| `lib/modules/referrals/web/list.ex` | +2 | -2 | Removed `String.to_integer/1` calls |
| `lib/modules/referrals/web/list.html.heex` | +1 | -1 | Changed edit link to use UUID |

## Implementation Details

### 1. Flexible ID Lookup

New `get_code/1` function supports multiple input types:

```elixir
# Integer ID
PhoenixKit.Modules.Referrals.get_code(123)

# UUID string
PhoenixKit.Modules.Referrals.get_code("550e8400-e29b-41d4-a716-446655440000")

# Integer string (fallback)
PhoenixKit.Modules.Referrals.get_code("123")

# Invalid input returns nil
PhoenixKit.Modules.Referrals.get_code("invalid")  # => nil
```

### 2. Security Improvement

URLs now use UUIDs instead of sequential integers:
- Before: `/admin/users/referral-codes/edit/42`
- After: `/admin/users/referral-codes/edit/550e8400-...`

This prevents enumeration attacks on referral codes.

### 3. Post-Review Fixes Applied

#### 3.1 Documentation Improvements

**`get_code/1`** - Enhanced to list all accepted inputs:
```elixir
@doc """
Gets a single referral code by integer ID or UUID.

Accepts:
- Integer ID (e.g., `123`)
- UUID string (e.g., `"550e8400-e29b-41d4-a716-446655440000"`)
- Integer string (e.g., `"123"`)
- Any other input returns `nil`

Returns the referral code if found, `nil` otherwise.
"""
```

**`get_code!/1`** - Simplified to reference main function:
```elixir
@doc """
Same as `get_code/1`, but raises `Ecto.NoResultsError` if the code does not exist.
"""
```

#### 3.2 Route Parameter Rename

Changed route parameter from `:id` to `:code_id` for clarity:
```elixir
# Before
live "/admin/users/referral-codes/edit/:id", Referrals.Web.Form, :edit

# After
live "/admin/users/referral-codes/edit/:code_id", Referrals.Web.Form, :edit
```

Updated `form.ex` accordingly:
```elixir
code_id = params["code_id"]  # was params["id"]
```

## Code Quality Assessment

### Strengths

1. **Follows project conventions** - Uses `PhoenixKit.Utils.UUID` for validation as documented in CLAUDE.md
2. **Proper fallback handling** - Handles integer IDs, UUID strings, and integer strings
3. **Consistent with project patterns** - Matches the UUID field pattern documented in "Adding UUID Fields to Existing Schemas"
4. **Good documentation** - Added proper `@doc` with examples

### Issues Identified and Fixed

1. **Duplicate `@doc` block** - Both `get_code/1` and `get_code!/1` had nearly identical documentation
2. **Incomplete input documentation** - The catch-all clause returning `nil` wasn't documented
3. **Route parameter name mismatch** - Used `:id` when passing UUID, misleading

## Testing

- [x] Code compiles without warnings (`mix compile --warnings-as-errors`)
- [x] Credo passes with no issues (`mix credo --strict`)
- [x] Code properly formatted (`mix format`)

## UUID Migration Status Update

With PR #317, the Referrals module is now fully migrated to the new UUID standard. This completes the UUID migration across all PhoenixKit modules:

| Category | Modules | Schemas |
|----------|---------|---------|
| New Standard | 8 | 31 |
| Native UUID PK | 4 | 28 |
| Old Pattern | 0 | 0 |
| No schemas | 7 | 0 |

## Related

- Referrals Module: `lib/modules/referrals/`
- UUID Utilities: `lib/phoenix_kit/utils/uuid.ex`
