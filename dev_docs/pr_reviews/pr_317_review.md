# PR #317 Review: Added support for uuid to referral module

**PR URL**: https://github.com/BeamLabEU/phoenix_kit/pull/317
**Author**: alexdont (Sasha Don)
**Status**: MERGED
**Review Date**: 2026-02-04

## Summary

This PR adds UUID support to the Referrals module, enabling referral codes to be looked up by either integer ID or UUID string. This completes the UUID migration across all PhoenixKit modules with database schemas.

## Changes Overview

| File | Additions | Deletions | Description |
|------|-----------|-----------|-------------|
| `lib/modules/referrals/referrals.ex` | +42 | -3 | Added flexible `get_code/1` lookup |
| `lib/modules/referrals/schemas/referral_code_usage.ex` | +1 | -1 | Added `read_after_writes: true` |
| `lib/modules/referrals/web/list.ex` | +2 | -2 | Removed `String.to_integer/1` calls |
| `lib/modules/referrals/web/list.html.heex` | +1 | -1 | Changed edit link to use UUID |

## Positive Aspects

1. **Follows project conventions** - Uses `PhoenixKit.Utils.UUID` for validation as documented in CLAUDE.md
2. **Proper fallback handling** - The `get_code/1` function correctly handles integer IDs, UUID strings, and integer strings
3. **Consistent with project patterns** - Matches the UUID field pattern documented in "Adding UUID Fields to Existing Schemas"
4. **Good documentation** - Added proper `@doc` with examples for the new function

## Security Impact

**Positive**: URLs now use UUIDs (`/admin/users/referral-codes/edit/550e8400-...`) instead of sequential integers, preventing enumeration attacks on referral codes.

## Issues Identified During Review

### 1. Duplicate `@doc` Block
**Location**: `lib/modules/referrals/referrals.ex` lines 224 and 256
**Issue**: Both `get_code/1` and `get_code!/1` had nearly identical documentation
**Fix**: Updated `get_code!/1` doc to reference `get_code/1` with "Same as `get_code/1`, but raises..."

### 2. Incomplete Input Documentation
**Location**: `lib/modules/referrals/referrals.ex` line 254
**Issue**: The `get_code(_), do: nil` clause wasn't documented in the function docs
**Fix**: Enhanced `get_code/1` docs to list all accepted input types and document that invalid inputs return `nil`

### 3. Route Parameter Name Mismatch
**Location**: `lib/phoenix_kit_web/routes/referrals.ex` and `lib/modules/referrals/web/form.ex`
**Issue**: Route used `:id` but template now passes a UUID, making the parameter name misleading
**Fix**: Renamed route parameter from `:id` to `:code_id` and updated `form.ex` to use `params["code_id"]`

## Post-Review Fixes Applied

### 1. Improved Documentation for `get_code/1`

```elixir
@doc """
Gets a single referral code by integer ID or UUID.

Accepts:
- Integer ID (e.g., `123`)
- UUID string (e.g., `"550e8400-e29b-41d4-a716-446655440000"`)
- Integer string (e.g., `"123"`)
- Any other input returns `nil`

Returns the referral code if found, `nil` otherwise.
...
"""
```

### 2. Simplified Documentation for `get_code!/1`

```elixir
@doc """
Same as `get_code/1`, but raises `Ecto.NoResultsError` if the code does not exist.
...
"""
```

### 3. Renamed Route Parameter

Changed from:
```elixir
live "/admin/users/referral-codes/edit/:id", ...
```

To:
```elixir
live "/admin/users/referral-codes/edit/:code_id", ...
```

And updated `form.ex`:
```elixir
code_id = params["code_id"]  # was params["id"]
```

## Verification

- Code compiles without warnings (`mix compile --warnings-as-errors`)
- Credo passes with no issues (`mix credo --strict`)
- Code properly formatted (`mix format`)

## UUID Migration Status Update

With PR #317, the Referrals module is now fully migrated to the new UUID standard. This completes the UUID migration across all PhoenixKit modules:

| Category | Modules | Schemas |
|----------|---------|---------|
| New Standard | 8 | 31 |
| Native UUID PK | 4 | 28 |
| Old Pattern | 0 | 0 |
| No schemas | 7 | 0 |

## Verdict

The original PR was well-implemented and followed project conventions. The post-review fixes address minor documentation and naming issues that improve code clarity and maintainability.
