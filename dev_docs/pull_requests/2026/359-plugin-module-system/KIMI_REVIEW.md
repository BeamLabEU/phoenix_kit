# PR #359 — Add plugin module system with zero-config auto-discovery

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/359  
**Author:** @mdon  
**Merged:** 2026-02-24 into `dev`  
**Additions:** +4,427 | **Deletions:** -2,285  
**Reviewer:** Kimi (Claude Code CLI)

---

## Executive Summary

This PR introduces a comprehensive plugin architecture that transforms PhoenixKit from a monolithic, hardcoded system into an extensible platform. The implementation is **well-architected and production-ready**, following established Elixir patterns (behaviours, persistent_term, beam_lib scanning).

**Overall verdict: Strong approve.** The architecture is sound, test coverage is thorough, and the plugin system achieves its goals with minimal breaking changes. A few minor issues exist but none are blockers.

---

## Architecture Analysis

### Core Components

| Component | Purpose | Assessment |
|-----------|---------|------------|
| `PhoenixKit.Module` | Behaviour contract with 5 required + 8 optional callbacks | ✅ Clean, well-documented |
| `PhoenixKit.ModuleRegistry` | GenServer + `:persistent_term` for zero-cost reads | ✅ Proper separation of concerns |
| `PhoenixKit.ModuleDiscovery` | Beam file scanning for auto-discovery | ✅ Efficient, targeted scanning |

### Design Strengths

1. **Beam attribute persistence** — Using `@phoenix_kit_module` with `persist: true` mirrors Elixir's protocol consolidation pattern. This enables discovery without module loading, which is both efficient and safe.

2. **`static_children/0` design** — This is a thoughtful solution to the supervisor boot-ordering problem. It can be called before the GenServer starts, preventing circular dependencies.

3. **Startup validation** — `validate_modules/1` catches duplicate keys, permission mismatches, and missing tab permissions at boot time rather than at runtime. This is excellent developer experience.

4. **Graceful degradation** — `safe_call/3` rescues errors from external modules, preventing one buggy plugin from crashing the entire system.

---

## Code Review

### `lib/phoenix_kit/module.ex` — Behaviour Definition

**Excellent documentation and design.** The callback separation (required vs optional) with sensible defaults via `__using__` makes external module development straightforward.

**One concern:** The default `get_config/0` implementation calls `enabled?()` which for most modules hits the database. This is noted in the docs, but external module authors should be aware that this gets called on every modules admin page render.

```elixir
# Line 127 - consider adding caching recommendation in moduledoc
def get_config, do: %{enabled: enabled?()}
```

### `lib/phoenix_kit/module_registry.ex` — Registry Implementation

**Well-structured.** The use of `:persistent_term` for reads with GenServer serialization for writes is the correct choice for this read-heavy workload.

**Observation:** `get_by_key/1` does a linear search through all modules. With 21 modules this is negligible, but for a large ecosystem this could become O(n). Consider caching a key→module map in `:persistent_term` in future iterations.

**Validation logic is thorough:**
- Duplicate key detection
- Permission metadata key matching
- Duplicate tab ID warnings
- Missing permission field warnings

### `lib/phoenix_kit/module_discovery.ex` — Auto-Discovery

**Good targeted scanning.** Only checks apps that depend on `:phoenix_kit`, keeping the scan fast.

**⚠️ Security concern:**

```elixir
# Line 143-146
 defp beam_file_to_module(path) do
   path
   |> Path.basename(".beam")
   |> String.to_atom()  # <-- Should be String.to_existing_atom/1
 end
```

While the comment states this is safe (scanning known ebin directories), defense-in-depth suggests using `String.to_existing_atom/1`. Any module with the `@phoenix_kit_module` attribute that's in an app's module list will already exist as an atom.

**Risk assessment:** Low in practice (apps must already be dependencies), but worth fixing.

### `lib/phoenix_kit_web/live/modules.ex` — Module Admin UI

**Proper authorization:** `authorize_toggle/2` validates against `accessible_modules` MapSet before dispatching, closing the WebSocket bypass vulnerability.

**Cascade fix is correct:** Shop is now disabled *after* billing succeeds, preventing orphaned state on failure.

**Remaining concern:** The billing→shop cascade is still not atomic. Two separate DB writes could leave inconsistent state if the second fails. Low probability but worth documenting or wrapping in a transaction in future work.

### `lib/phoenix_kit_web/integration.ex` — Route Integration

**Clean compile-time route generation.** The `safe_route_call/3` helper prevents compilation failures when modules are extracted to separate packages.

**Plugin route generation** (`compile_plugin_admin_routes/0`) correctly uses `ModuleDiscovery` to auto-generate routes for external modules with `live_view` tabs.

---

## Bug Fixes (in this PR)

| Bug | Fix | Assessment |
|-----|-----|------------|
| Billing→Shop cascade | Shop disabled AFTER billing succeeds | ✅ Correct |
| `Tab.permission_granted?/2` | Now handles atom keys | ✅ Correctness fix |
| `static_children/0` | Catches per-module failures | ✅ Reliability fix |
| Server-side toggle auth | Validates against `accessible_modules` | ✅ Security fix |

---

## Test Coverage

**Excellent for infrastructure:**

- `module_test.exs` — 273 lines covering all 21 modules: callback presence, return types, key uniqueness, permission consistency, tab structure
- `module_registry_test.exs` — 296 lines covering all public API functions
- `module_discovery_test.exs` — 65 lines covering scan behavior and config fallback

**Gaps identified:**
- Live sidebar update flow (PubSub → assign bump → re-render)
- External module discovery via actual beam file scanning (would need fixture dep)
- Billing→Shop cascade failure modes
- The `String.to_atom` path in `scan_app_ebin`

---

## Performance Considerations

| Operation | Complexity | Notes |
|-----------|------------|-------|
| `all_modules/0` | O(1) | `:persistent_term` lookup |
| `get_by_key/1` | O(n) | Linear search, room for optimization |
| `all_admin_tabs/0` | O(n) | Iterates all modules |
| `enabled_modules/0` | O(n) | Filters all modules |
| Startup validation | O(n) | Acceptable tradeoff for early error detection |

**Note:** The dashboard registry already caches admin tabs in ETS, so direct calls to `ModuleRegistry.all_admin_tabs()` are typically bypassed in normal operation.

---

## Security Assessment

1. **Toggle authorization** ✅ — Correctly validates against precomputed `accessible_modules` MapSet server-side before any state change.

2. **Atom creation** ⚠️ — `String.to_atom/1` in `ModuleDiscovery.beam_file_to_module/1` should use `to_existing_atom/1` for defense-in-depth.

3. **Module isolation** ✅ — `safe_call/3` prevents one module's errors from affecting others.

---

## Comparison with Previous Reviews

**Agreements with Mistral and Claude Sonnet 4.6:**
- Overall positive assessment of the architecture
- `String.to_atom/1` should be changed to `String.to_existing_atom/1`
- Billing/shop cascade improvement is correct but non-atomic
- Praise for validation and error handling

**Additional observations:**
- The `get_by_key/1` O(n) complexity may need addressing as the ecosystem grows
- The test coverage for `module_discovery_test.exs` is relatively light compared to the other test files
- The `safe_route_call/3` compile-time guard is a nice touch for package extraction

---

## Recommendations

### Must Fix (Before 1.0)

1. **Change `String.to_atom/1` to `String.to_existing_atom/1`**
   - File: `lib/phoenix_kit/module_discovery.ex:146`
   - One-line change for defense-in-depth

### Should Fix (High Priority)

2. **Document `get_config/0` performance implications**
   - Add note in `PhoenixKit.Module` moduledoc about DB calls
   - Recommend caching for external modules that do heavy work

3. **Add integration test for sidebar LiveView updates**
   - Test PubSub → assign bump → re-render flow

### Nice to Have (Future Work)

4. **Optimize `get_by_key/1`** — Consider caching key→module map
5. **Document cascade limitations** — Add comment about non-atomic billing/shop writes
6. **Benchmark registry operations** — Establish baseline for future optimization

---

## Ecosystem Impact

This PR enables a significant shift for PhoenixKit:

**Before:** Adding a module required changes to 7+ core files (admin_tabs, permissions, registry, modules, supervisor, etc.)

**After:** External packages just `use PhoenixKit.Module` and get auto-wired:
- Admin sidebar tabs
- Permission system integration  
- Supervisor children
- Route generation
- Modules admin page integration

This positions PhoenixKit well for ecosystem growth — third-party modules like `phoenix_kit_tickets`, `phoenix_kit_analytics`, etc. can now exist as separate hex packages.

---

## Conclusion

PR #359 is a **landmark architectural improvement** that successfully transforms PhoenixKit into an extensible platform. The implementation follows Elixir best practices, achieves zero-config auto-discovery through clever use of beam attributes, and maintains backwards compatibility.

The code is production-ready. The identified issues are minor and can be addressed in follow-up work.

**Final rating: 9/10** — Excellent architecture, solid implementation, minor polish items remain.

---

## Action Items

| Priority | Item | File |
|----------|------|------|
| 🔴 High | Fix `String.to_atom/1` → `String.to_existing_atom/1` | `module_discovery.ex:146` |
| 🟡 Medium | Document `get_config/0` DB implications | `module.ex` moduledoc |
| 🟡 Medium | Add LiveView sidebar update integration test | New test file |
| 🟢 Low | Consider `get_by_key/1` optimization | `module_registry.ex` |
| 🟢 Low | Document cascade atomicity limitation | `modules.ex` |
