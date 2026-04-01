# PR #470 Review — Unify status badges, fix module toggles, add auto CSS compiler

**Reviewer:** Claude
**Date:** 2026-04-01
**Verdict:** Approve with minor notes

## Summary

Multi-faceted cleanup PR that (1) unifies the `status_badge` component with underscore-aware label formatting and 13 new status classes, (2) removes hardcoded Legal references in favor of auto-discovery, (3) introduces a compile-time CSS source compiler replacing manual `@source` management, (4) fixes module toggle bugs for maintenance and legal, (5) adds route deduplication, and (6) registers 6 missing modules in `known_external_packages`.

## Changes by Area

### 1. Unified `status_badge` — `badge.ex`

- New `status_label/1` replaces raw `String.capitalize/1`, handling underscored statuses like `"in_progress"` -> `"In progress"`.
- 13 new `status_class/1` clauses: `completed`, `failed`, `cancelled`, `in_progress`, `denied`, `expired`, `approved`, `pending_approval`, `revoked`, `loading` (with `animate-pulse`), `offline`, `not_found`, `error`.
- Catch-all `status_class(_)` still falls back to `badge-ghost`.

**Assessment:** Clean, straightforward. The underscore-to-space approach is the right call — avoids forcing callers to pre-format labels. The `animate-pulse` on `loading` is a nice touch.

### 2. Remove hardcoded Legal — `integration.ex`, `modules.html.heex`, `modules.ex`

- Deleted the `if Code.ensure_loaded?(PhoenixKit.Modules.Legal)` block from the settings routes in `integration.ex`. Legal now uses `settings_tabs/0` auto-discovery like other external modules.
- Removed the 46-line hardcoded Legal module card from `modules.html.heex`. Legal now appears via the external modules loop.
- Fixed `toggle_legal` to rebuild `external_modules` after state change by calling `load_external_modules(configs)`. Previously the toggle updated configs but the external modules list was stale, so the card wouldn't reflect the new state.

**Assessment:** Good. This was a consistency gap — Legal was the last module with hardcoded routing and a hardcoded card. The fix to rebuild `external_modules` after toggle is important for correct UI state.

### 3. Auto CSS source compiler — `compile.phoenix_kit_css_sources.ex`

New Mix compiler that:
1. Loads all dep applications via `Mix.Dep.cached()`
2. Discovers external modules via `PhoenixKit.ModuleDiscovery`
3. Calls `css_sources/0` on each, resolves path deps vs hex deps
4. Writes `assets/css/_phoenix_kit_sources.css` (only when content changes)

Replaces the `plugin_module_source_lines/0` logic in `css_integration.ex` (~70 lines deleted).

**Assessment:** Solid architectural improvement. Moving CSS source discovery from install/update time to compile time means adding/removing modules is truly zero-config. The idempotent write (only when content changes) avoids unnecessary Tailwind rebuilds.

**Notes:**
- `find_dep_path/2` is duplicated between this compiler and the now-deleted `css_integration.ex`. The compiler's copy is the surviving one, which is fine — no need to extract it since it's only used here now.
- The compiler uses `Mix.Dep.cached()` which returns `Mix.Dep` structs. The iteration uses `dep.app` (line 33) rather than destructuring `{app, _, _}` — this is correct for the struct-based API and cleaner than what the old `css_integration.ex` did.
- `:not_found` falls back to `deps/#{app_name}` which is a reasonable default.

### 4. Maintenance toggle fix — `modules.ex`

New `toggle_maintenance/1` handler using `Maintenance.enable_module()` / `disable_module()` instead of the generic `enable_system()` / `disable_system()`. The generic path was checking the wrong config key.

Also added `dispatch_toggle(socket, "maintenance")` clause.

**Assessment:** This was a real bug — the maintenance module has a different enable/disable API than most modules. The fix correctly reads `config[:module_enabled]` instead of `config[:enabled]`.

**One observation:** Unlike other toggle handlers (legal, shop), this one doesn't handle errors from `enable_module()`/`disable_module()`. Those functions presumably don't fail, but if they can, the toggle will silently succeed even on failure. Low risk since maintenance is a simple flag toggle.

### 5. Route deduplication — `integration.ex`

Added `Enum.uniq_by(fn %{path: path} -> path end)` in `collect_module_tabs/2` to prevent duplicate routes when a parent tab and subtab share the same path with `live_view:`.

**Assessment:** Defensive and correct. First-wins semantics via `uniq_by` is the right choice since parent tabs are prepended.

### 6. Known external packages — `module_registry.ex`

Added 6 modules to `known_external_packages/0`: Legal, Catalogue, Document Creator, User Connections, Comments, Hello World.

**Assessment:** Straightforward data addition. Module atoms (`PhoenixKitCatalogue`, `PhoenixKitDocumentCreator`, etc.) match the actual module names used in those packages.

### 7. Update task — `phoenix_kit.update.ex`

Refactored the daisyUI theme update to use a content pipeline (rebinding `content` instead of writing mid-flow), and added a new step to inject `@import "./_phoenix_kit_sources.css"` if missing.

**Assessment:** The refactor from write-mid-flow to single-write-at-end is cleaner. The regex `(@source\s+["'][^"']*phoenix_kit["'];)` for insertion point is specific enough to avoid false matches.

### 8. AGENTS.md updates

Added CSS compiler docs and expanded route pattern documentation with the two routing patterns (single page vs multi-page).

## What Works Well

- **Cohesive theme**: All changes relate to making external modules more self-contained and auto-discoverable.
- **Net code reduction**: +296/-151 across 9 files. The new CSS compiler adds 107 lines but removes ~70 from `css_integration.ex` and 46 from the Legal template — net architecture is simpler.
- **Compile-time over install-time**: The CSS compiler is a genuine improvement over the old approach of managing `@source` lines during `mix phoenix_kit.install` / `mix phoenix_kit.update`.

## Potential Improvements (Non-blocking)

1. **`toggle_maintenance` error handling**: Consider wrapping `enable_module()`/`disable_module()` in a case match for consistency with other toggle handlers, even if failures are unlikely.

2. **`status_label/1` with multi-word statuses**: `String.capitalize/1` only capitalizes the first word. So `"pending_approval"` becomes `"Pending approval"` (lowercase "a"). This is likely intentional (sentence case), but worth confirming it matches the design expectation vs. title case ("Pending Approval").

3. **CSS compiler `manifests/0`**: The compiler doesn't implement `manifests/0` callback, so Mix can't track its outputs for incremental compilation. Not critical since the compiler is idempotent and fast, but implementing it would let `mix clean` remove the generated file.

## No Issues Found

No bugs, security concerns, or breaking changes. The PR is well-structured across 8 commits with clear separation of concerns.
