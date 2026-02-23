# PR #353: Memoize IbanData.all_specs/0 with compile-time module attribute

**PR**: https://github.com/BeamLabEU/phoenix_kit/pull/353
**Author**: alexdont (Alexander Don)
**Merged**: 2026-02-21

## What

Moves `IbanData.all_specs/0` struct construction from runtime to compile-time by storing the pre-computed map of `%IbanData{}` structs in a `@all_specs` module attribute.

## Why

`all_specs/0` previously ran `Map.new/2` over 92 country entries on every call, creating fresh structs each time. This was flagged in the PR #346 review as a candidate for memoization.

## How

- Added `@all_specs` module attribute that pre-computes the struct map at compile time
- Uses `%{__struct__: __MODULE__, ...}` syntax (standard workaround for struct literals in module attributes)
- Replaced `all_specs/0` function body with direct attribute reference

## Related PRs

- Previous: [#346](../346-typed-structs-map-audit/) — Typed structs audit (introduced `all_specs/0` returning structs)
