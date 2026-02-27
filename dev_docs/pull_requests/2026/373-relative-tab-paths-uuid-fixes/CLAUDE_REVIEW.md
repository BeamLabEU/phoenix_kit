# PR #373 Review — Relative Tab Paths, Layout Double-Wrap Fix, UUID Migration Bugs

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/373
**Author:** mdon (Max Don)
**Merged:** 2026-02-27
**Reviewer:** Claude (Opus 4.6)
**Verdict:** Approve with medium-severity notes

---

## Summary

A multi-faceted PR with three distinct changes:

1. **Relative tab paths** — Modules now define short slugs (`"billing"`) instead of absolute paths (`"/admin/billing"`). `Tab.resolve_path/2` prepends the prefix based on context (`:admin`, `:settings`, `:user_dashboard`) at collection boundaries.

2. **Layout double-wrap guard** — Prevents double admin sidebar rendering when the admin layout wraps a plugin LiveView that also calls `app_layout`. Uses a `from_layout` attr + Process dictionary flag.

3. **UUID migration bug fixes** — Storage orphan query crash on missing tables, `.id` -> `.uuid` identity comparisons in user management views.

## What's Good

1. **`Tab.resolve_path/2` design is clean** — The three-clause function with pattern matching on path prefix (`"/"`, `""`, other) is elegant and easy to understand. Absolute paths pass through unchanged, making it safe for double-resolution scenarios.

2. **Collection-boundary resolution** — Paths are resolved at the point where tabs are collected (in `ModuleRegistry`, `AdminTabs`, `Registry`, `Integration`), not inside individual modules. This means modules stay decoupled from the routing structure.

3. **Storage orphan query rewrite** — Moving from unconditional `NOT EXISTS` subqueries to a dynamic approach with `existing_optional_tables()` is the right fix. Modules like Shop or Publishing may not be installed, and the old code would crash on missing tables.

4. **`.id` -> `.uuid` comparisons** — Critical fix in `users.ex` and `user_details.ex`. Using `.id` for identity comparison would silently fail or compare wrong values after UUID migration.

5. **Test updated** — `module_test.exs` correctly tests that paths resolve to `/admin` prefix.

## Issues Found

### Medium: `existing_optional_tables/0` hardcodes `table_schema = 'public'`

**File:** `lib/modules/storage/storage.ex:769-778`

```elixir
repo.query!(
  "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name LIKE 'phoenix_kit_%'"
)
```

PhoenixKit supports custom table prefixes (multi-tenant schemas). If a parent app uses a non-`public` schema, this query returns nothing and the orphan detection skips all optional table checks — effectively marking all files as orphaned.

**Impact:** Could cause incorrect orphan detection in multi-tenant setups. The `orphaned_files_query` function itself doesn't receive a prefix parameter, so the fix may require threading prefix through.

**Note:** The old code (before this PR) had the same issue — it hardcoded table names without schema prefix in the SQL fragments. So this is a pre-existing concern that the refactor made more visible, not a regression.

### Medium: Process dictionary flag for double-wrap guard is fragile

**File:** `lib/phoenix_kit_web/components/layout_wrapper.ex:82-101`

The `Process.put(:phoenix_kit_admin_chrome_rendered, true)` / `Process.delete` pattern works but has edge cases:

1. **Race condition with concurrent renders**: Process dictionary is per-process, and LiveView renders happen in the same process, so this is safe for normal LiveView. But if anything triggers a concurrent render in the same process (unlikely but possible with certain Phoenix internals), the flag could leak.

2. **Missing cleanup on non-admin paths**: `Process.put` happens in `wrap_inner_block_with_admin_nav_if_needed` only when `admin_page?` is true. The `Process.delete` happens in `app_layout` when `from_layout` is true. If a non-admin page follows an admin page in the same process, the flag persists harmlessly (it's only checked with `from_layout=true`), but it's still technically leaked state.

3. **Logger.warning on expected behavior**: The warning message says "Plugin LiveViews should not call LayoutWrapper.app_layout" — but the guard exists precisely because they do. The warning will fire on every admin page render for plugin LiveViews, which could be noisy. Consider demoting to `Logger.debug` or adding a configurable silence option.

**Impact:** The guard works correctly for the stated use case. The concerns above are theoretical edge cases, not active bugs.

### Low: `tab_callback_context/1` missing `:user_dashboard_tabs` clause

**File:** `lib/phoenix_kit_web/integration.ex:984-985`

```elixir
defp tab_callback_context(:admin_tabs), do: :admin
defp tab_callback_context(:settings_tabs), do: :settings
```

There's no clause for `:user_dashboard_tabs`. Currently `collect_module_tabs` is only called with `:admin_tabs` and `:settings_tabs`, so this doesn't crash. But if someone adds a `:user_dashboard_tabs` call, it will raise `FunctionClauseError` at runtime with no helpful message.

**Fix:** Add `defp tab_callback_context(:user_dashboard_tabs), do: :user_dashboard` for completeness.

### Low: Billing "Payment Providers" tab has cross-context path

**File:** `lib/modules/billing/billing.ex:218-227`

```elixir
# In admin_tabs(), not settings_tabs()
Tab.new!(
  id: :admin_billing_providers,
  path: "settings/billing/providers",  # resolves to /admin/settings/billing/providers
  ...
  parent: :admin_billing
)
```

This tab is in `admin_tabs()` but its path starts with `settings/`, so it resolves to `/admin/settings/billing/providers`. This is the same as the old absolute path, so it's not a regression. But it's architecturally odd — a tab in `admin_tabs()` pointing to a settings path. Consider whether this should be in `settings_tabs()` instead, or whether the path should be restructured.

### Info: No double-resolution risk (confirmed safe)

`resolve_path/2` correctly passes through already-resolved paths via the `"/" <> _` pattern match. Tabs flowing through both `ModuleRegistry.all_admin_tabs()` and then `admin_sidebar.ex` won't be double-prefixed. Verified by tracing all call paths.

## Observations

- This PR touches 31 files across 17 modules — high blast radius. The test coverage (only `module_test.exs` updated) is thin relative to the scope. Integration testing in the parent app is critical for validating all paths resolve correctly.
- The `~H"{render_slot(@inner_block)}"` in the double-wrap guard renders the inner content without any wrapping — no admin chrome, no flash messages, no cookie consent. This is intentional (the LiveView's own render already provides these), but it's worth understanding.
- The "Plugin" -> "External" rename in `modules.html.heex` is a nice terminology cleanup.
- The `dynamic_children` resolution in `admin_sidebar.ex:256` is necessary because dynamic children bypass `ModuleRegistry.all_admin_tabs()` — they're generated at render time from a closure.
