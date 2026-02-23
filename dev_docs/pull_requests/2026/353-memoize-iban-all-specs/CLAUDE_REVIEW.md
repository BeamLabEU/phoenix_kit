# PR #353 Review: Memoize IbanData.all_specs/0

**PR**: https://github.com/BeamLabEU/phoenix_kit/pull/353
**Author**: alexdont (Alexander Don)
**Merged**: 2026-02-21
**Files changed**: 1 (+5 / -5)
**Commits**: 1
**Reviewer**: Claude Opus 4.6

---

## Summary

Micro-optimization that moves the `IbanData.all_specs/0` struct conversion from runtime to compile-time by pre-computing the result into a `@all_specs` module attribute. Previously, every call to `all_specs/0` ran `Map.new/2` over all 92 country entries, constructing a new `%IbanData{}` struct for each. Now the map of structs is built once at compile time and returned directly.

## Verdict: Approve — low-impact housekeeping

Clean, correct, minimal change. Net zero lines (5 added, 5 removed). Directly addresses feedback from PR #346 review.

### Practical Impact: Negligible

While technically correct, this optimization has near-zero real-world impact:

- **`all_specs/0` has no callers in the codebase** — the only consumer of `IbanData` is `country_data.ex`, which calls `get_iban_length/1`, not `all_specs/0`.
- **Building 92 small two-field structs is microseconds** — not a meaningful performance bottleneck even if it were called frequently.
- **The data is static** — there's no hot path or repeated computation to worry about.

This is a nice-to-have cleanup following review feedback, not something that solves a real problem.

---

## What Changed

**Before:**
```elixir
def all_specs do
  Map.new(@iban_specs, fn {code, %{length: length, sepa: sepa}} ->
    {code, %__MODULE__{length: length, sepa: sepa}}
  end)
end
```

**After:**
```elixir
@all_specs Map.new(@iban_specs, fn {code, %{length: length, sepa: sepa}} ->
             {code, %{__struct__: __MODULE__, length: length, sepa: sepa}}
           end)

def all_specs, do: @all_specs
```

## Analysis

### Correctness

The `%{__struct__: __MODULE__, length: length, sepa: sepa}` pattern is the standard Elixir idiom for constructing structs inside module attributes, where `%__MODULE__{}` syntax is not available (the struct is not yet fully defined during attribute evaluation). Verified via eval that this produces proper structs with `is_struct/2` returning `true`.

### Why not `%__MODULE__{}`?

Elixir doesn't allow `%MyModule{}` struct literal syntax inside the same module's attribute definitions because `defstruct` hasn't finished compiling yet at that point. The `%{__struct__: __MODULE__, ...}` workaround is well-established in the Elixir community and produces an identical result at the BEAM level.

### `@enforce_keys` bypass

The `%{__struct__: ...}` map literal bypasses `@enforce_keys [:length, :sepa]` validation. This is safe here because both keys are always present in the hardcoded `@iban_specs` data — there's no user input path where a key could be missing.

### Origin

This change was explicitly recommended in the [PR #346 review](../346-typed-structs-map-audit/CLAUDE_REVIEW.md):

> **IbanData.all_specs/0 constructs structs on every call**: Converts the entire @iban_specs map (92 countries) to structs each time. Consider memoizing with a module attribute if this is called frequently.

Good follow-through.

## Minor Observation

`get_spec/1` (line 184-188) still constructs a fresh `%__MODULE__{}` struct on every call via pattern matching on `@iban_specs`. It could instead do a simple lookup into `@all_specs`:

```elixir
def get_spec(country_code) when is_binary(country_code) do
  Map.get(@all_specs, String.upcase(country_code))
end
```

This is a trivial optimization (single struct construction vs map lookup) and not a blocker — just a consistency note for a future pass.

## Risk Assessment

**Risk: None.** Pure compile-time optimization with identical runtime behavior. No API changes, no new dependencies, no behavioral changes.
