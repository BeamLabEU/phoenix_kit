# PR #359 — Add plugin module system with zero-config auto-discovery

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/359
**Author:** @mdon
**Merged:** 2026-02-24 into `dev`
**Additions:** +4,427 | **Deletions:** -2,285
**Reviewer:** Claude Sonnet 4.6

---

## Executive Summary

This is a landmark architectural PR that transforms PhoenixKit's module system from a hardcoded enumeration to a fully dynamic, extensible plugin architecture. The implementation is high quality — thoughtful design, good defaults, and solid test coverage for the new infrastructure. The core idea (behaviour + beam attribute + ModuleRegistry) is clean and follows established Elixir patterns.

**Overall verdict: Strong implementation. A few concerns worth addressing, primarily around the billing/shop cascade atomicity and the use of `String.to_atom/1` in beam scanning. No blockers. Recommended for merging.**

---

## What Changed

### New Infrastructure (Core of the PR)

| File | Purpose |
|------|---------|
| `lib/phoenix_kit/module.ex` | `PhoenixKit.Module` behaviour + `use` macro |
| `lib/phoenix_kit/module_registry.ex` | GenServer + `:persistent_term` registry |
| `lib/phoenix_kit/module_discovery.ex` | Zero-config beam-file auto-discovery |

### Refactored (All 21 internal modules + 7 core files)

All 21 modules now `use PhoenixKit.Module`. Seven core files that previously hardcoded all 21 modules now delegate to the registry:

| File | What Changed |
|------|-------------|
| `permissions.ex` | `@feature_module_keys`, label/icon/desc maps → `ModuleRegistry` queries |
| `admin_tabs.ex` | Module tab lists → `ModuleRegistry.all_admin_tabs()` |
| `dashboard/registry.ex` | `tickets_enabled?/billing_enabled?` etc. → `ModuleRegistry.feature_enabled_checks()` |
| `modules.ex` | 21 explicit aliases → generic `ModuleRegistry` iteration |
| `supervisor.ex` | Hardcoded module children → `ModuleRegistry.static_children()` |
| `integration.ex` | New `compile_module_admin_routes/0`, external route support |
| `users/auth.ex` | Module PubSub subscription for live sidebar updates |

### Bug Fixes

- **Billing→Shop cascade:** Shop now disabled _after_ billing toggle succeeds (not before), preventing orphaned state on failure.
- **`Tab.permission_granted?/2`:** Fixed to handle atom permission keys (was silently bypassing checks).
- **`static_children/0`:** Now catches individual module `children/0` failures instead of crashing the supervisor.
- **`admin_nav.ex`:** Added `Code.ensure_loaded?` guard for the Languages module.

### Standardization

AI, Billing, and Shop now use `update_boolean_setting_with_module/3` consistent with all other modules.

---

## Deep Dive: New Files

### `PhoenixKit.Module` behaviour (`module.ex`)

**Design: Excellent.**

The beam attribute trick (`Module.register_attribute(__MODULE__, :phoenix_kit_module, persist: true)`) is the right approach — it mirrors Elixir's own protocol consolidation pattern and enables scanning without loading modules. The 5-required / 8-optional callback split with sensible `use`-macro defaults makes external module development ergonomic.

```elixir
# use macro persists marker in .beam for zero-config discovery
Module.register_attribute(__MODULE__, :phoenix_kit_module, persist: true)
@phoenix_kit_module true
```

One thing to note: the `get_config/0` default calls `enabled?()` which could hit the database on every call. External module authors may need to be aware that `get_config/0` is called per-render on the modules admin page.

**Callback return types:** `enable_system/0` and `disable_system/0` accept `:ok | {:ok, term()} | {:error, term()}`. This is flexible, but the LiveView normalizes the result via `normalize_result/1` — external module authors need to know that all three are valid returns. Worth documenting explicitly in the moduledoc.

---

### `PhoenixKit.ModuleRegistry` (`module_registry.ex`)

**Design: Very good.**

The `:persistent_term` approach for zero-cost reads is the right choice here — module lists are read far more often than they're written (only at boot + explicit register/unregister). The GenServer serializes writes while `:persistent_term` serves reads lock-free.

**`static_children/0`** is a particularly nice design: it can be called from `PhoenixKit.Supervisor.init/1` _before_ the GenServer is started, since it builds its own list from `internal_modules()` directly. This avoids a chicken-and-egg problem.

**`validate_modules/1`** startup validation is well thought out:
- Warns on duplicate `module_key`
- Warns on `permission_metadata.key` ≠ `module_key` mismatch
- Warns on duplicate admin tab IDs
- Warns on tabs missing `:permission` field

These are all things that would otherwise cause subtle, hard-to-debug runtime failures.

**`safe_call/3`** is appropriate here — we need to tolerate external modules that may have bugs, but the rescue-all pattern is intentional for plugin safety. The log message includes the hint about Tab path validation which is helpful.

**Concern: `all_admin_tabs/0` iterates all modules on every call.** Since it's backed by `:persistent_term` for the module list but calls each module's `admin_tabs/0` fresh, repeated calls accumulate. The dashboard/registry.ex already caches these in ETS, so this is fine for normal use, but calling `ModuleRegistry.all_admin_tabs()` directly is unbounded. Low risk in practice but worth noting.

---

### `PhoenixKit.ModuleDiscovery` (`module_discovery.ex`)

**Design: Good, with one concern.**

The scan strategy is efficient — it only checks apps that declare `:phoenix_kit` in their application dependencies (via `:application.get_key(app, :applications)`), not every loaded app. This keeps the scan targeted.

**Concern: `String.to_atom/1` in `beam_file_to_module/1`.**

```elixir
defp beam_file_to_module(path) do
  path
  |> Path.basename(".beam")
  |> String.to_atom()
end
```

The comment says "safe here — scanning known ebin directories of apps that depend on `:phoenix_kit`", and that's largely true. But in theory, a malicious or corrupted dep could place unexpected .beam files in its ebin. `String.to_existing_atom/1` would be safer — any module that's already in `:application.get_key(app, :modules)` will already exist as an atom. The fallback `scan_app_ebin/1` path (triggered when the application module list isn't available) is where this matters most. Low risk in practice (you've already added the dep to mix.exs), but worth a one-line change.

**`Code.ensure_loaded/1` in the `:non_existing` branch** is a reasonable fallback but adds latency. If a module atom exists but isn't loaded, loading it just to re-check its beam path is roundabout. Could just do `Code.ensure_loaded(mod)` and then check `mod.__info__(:attributes)[:phoenix_kit_module]` directly. However, the current approach is correct and readable.

---

## Module Toggle Authorization

**`authorize_toggle/2` in `modules.ex`:**

```elixir
defp authorize_toggle(socket, key) do
  scope = socket.assigns[:phoenix_kit_current_scope]

  if scope &&
       (Scope.system_role?(scope) || MapSet.member?(socket.assigns.accessible_modules, key)) do
    :ok
  else
    {:error, :access_denied}
  end
end
```

This is the key security fix — validates the module key against the user's `accessible_modules` MapSet before dispatching. This correctly closes the WebSocket bypass where crafted events could toggle modules without checking permissions. The validation happens server-side before any DB operation.

**Important:** The check uses `socket.assigns.accessible_modules` which is a precomputed MapSet populated at mount time. If a role's permissions change during an active session, the user's `accessible_modules` could be stale until the next scope refresh event. This is acceptable behavior (the existing scope refresh hook handles role changes), but worth noting for anyone reasoning about security.

---

## Live Sidebar Updates

The real-time sidebar update mechanism is well-integrated with the existing pattern:

1. Module toggle → `Events.broadcast_module_enabled/disabled(key)` via PubSub
2. `on_mount(:phoenix_kit_ensure_admin)` in `auth.ex` subscribes all admin LiveViews
3. `handle_module_refresh/2` bumps `:phoenix_kit_modules_version` assign
4. Sidebar re-renders and re-evaluates `Registry.get_admin_tabs()` → `Permissions.feature_enabled?()` per tab

This follows the same pattern as the existing scope refresh hook. The guard `phoenix_kit_module_hook_attached?: true` prevents double-subscription if `on_mount` is called multiple times.

---

## Bug Fix Analysis

### Billing→Shop Cascade Fix

**Before (broken):**
```elixir
# Shop disabled BEFORE billing check — if billing fails, shop is now down with billing still up
shop_was_disabled = if not new_enabled, do: Shop.disable_system(), else: false
result = if new_enabled, do: billing_mod.enable_system(), else: billing_mod.disable_system()
```

**After (correct):**
```elixir
result = if new_enabled, do: billing_mod.enable_system(), else: billing_mod.disable_system()
# Shop disabled AFTER billing succeeds
shop_was_disabled = maybe_disable_shop_first(new_enabled, configs)
```

This is a correct fix. The cascade now only fires when billing toggle succeeds, and is wrapped in `maybe_disable_shop_first/2` which checks the shop's current state.

**Remaining gap:** `billing_mod.disable_system()` and `shop_mod.disable_system()` are still two separate settings writes. If billing succeeds but shop fails (e.g., DB error between the two), billing is disabled but shop remains "enabled" with no billing underneath. This is a very narrow failure window and probably acceptable — wrapping in a Repo.transaction would add complexity — but worth an issue or comment.

### `Tab.permission_granted?/2` atom key fix

Important correctness fix. The existing code was checking `String.t()` equality but some callers passed atom keys. Now handles both.

---

## Test Coverage

**Excellent for new infrastructure:**

- `module_test.exs` — 160+ lines covering all 21 modules implementing the behaviour: callback presence, return types, key uniqueness, permission_metadata consistency, admin tab structure, registry integration.
- `module_registry_test.exs` — Covers all public API: all_modules, register/unregister idempotency, get_by_key, all_admin_tabs, all_permission_metadata, all_feature_keys, feature_enabled_checks, permission_labels/icons/descriptions, enabled_modules, static_children.
- `module_discovery_test.exs` — (not read in detail but exists)

**Not tested:**
- Live sidebar update flow (PubSub → assign bump → re-render) — this is a LiveView integration concern, harder to unit test.
- Billing→Shop cascade atomicity / failure modes.
- External module discovery via actual beam file scanning (would need a fixture dep).
- The `String.to_atom` path in `scan_app_ebin` (the `:non_existing` fallback).

---

## Issues & Recommendations

### Issues Worth Addressing

**1. `String.to_atom/1` in `scan_app_ebin/1`** *(Low priority)*
File: `module_discovery.ex:143`

`String.to_existing_atom/1` is safer. The comment justifies `String.to_atom`, but any module in an app that passes the `@phoenix_kit_module` attribute check should already exist as an atom (it's in the app's module list). Worth a one-line change.

**2. Billing/Shop cascade non-atomic** *(Low priority, known gap)*
File: `modules.ex` ~line 210

The two DB writes (billing, then shop) are not wrapped in a transaction. A failure between them leaves inconsistent state. Current handling (fail-open logging) is pragmatic. Could be addressed with a future `Repo.transaction` wrapper.

**3. `all_admin_tabs/0` called on every sidebar render** *(Low priority)*
File: `module_registry.ex:91`

Each call re-iterates all modules and calls `admin_tabs/0` on each. The dashboard registry already caches this in ETS, so direct calls to `ModuleRegistry.all_admin_tabs()` bypass the cache. Consider a doc note warning callers to go through the registry for cached access.

**4. `get_config/0` default does DB work** *(Low priority, external author concern)*
File: `module.ex:127`

The default `get_config/0` implementation calls `enabled?()` which for most modules hits Settings (cached, but still). External module docs should note this.

### Positive Callouts

- **`validate_modules/1` at startup** — Catching duplicate keys and tab ID conflicts at startup rather than at runtime is excellent DX.
- **`static_children/0`** design — Callable before the GenServer starts, prevents supervisor boot ordering issues.
- **`safe_route_call/3`** compile-time guard — Allows modules to be safely extracted to separate packages without breaking the router macro.
- **`io.warn` during route compilation** — Emitting a warning (not an error) for missing LiveViews is the right choice — it doesn't halt compilation but alerts the developer.
- **Test comprehensiveness** — The `module_test.exs` suite is a good regression guard for the behaviour contract.

---

## Architecture Assessment

### What This Enables

The plugin system creates a clean extension point. An external `phoenix_kit_tickets` hex package (for example) can:

1. Add `{:phoenix_kit_tickets, "~> 1.0"}` to `mix.exs`
2. Auto-register via beam attribute scanning — no config needed
3. Get admin sidebar tab, permission key, supervisor children, and routes auto-wired
4. Show up in the admin modules page with enable/disable toggle

This is the right architecture for a starter-kit that wants to grow an ecosystem.

### Tradeoffs

| Decision | Tradeoff |
|----------|----------|
| `:persistent_term` for module list | Zero-cost reads, but global mutation on register/unregister; fine for rare writes |
| Compile-time route generation for external modules | Routes require recompile on new module add; expected Phoenix constraint |
| Warnings-only for startup validation | Permissive (won't crash bad config), but could mask issues in production |
| `safe_call` rescue-all for module callbacks | Plugin safety at the cost of masking implementation bugs |

All of these are reasonable choices given the constraints.

---

## Summary

This PR is well-executed. The beam attribute discovery pattern is clever and proven (Elixir uses it for protocols). The ModuleRegistry design correctly separates write serialization (GenServer) from read performance (`:persistent_term`). The test suite for new infrastructure is thorough. The bug fixes (cascade, atom key, supervisor crash) are real improvements.

The `String.to_atom` in the fallback scan path is the most concrete thing worth fixing before shipping external plugin docs. Everything else is low-priority polish.
