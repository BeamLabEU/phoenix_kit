# PR #361 — Fix external plugin module permissions, routing, and layout integration

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/361
**Author:** @mdon
**Merged:** 2026-02-24 into `dev`
**Follows:** [#359 — plugin module system](/dev_docs/pull_requests/2026/359-plugin-module-system/)
**Additions:** +76 | **Deletions:** -30

---

## Goal

Fix six real-world integration issues discovered after merging the external plugin module system (PR #359). All fixes are in the plugin integration layer — no changes to the core `PhoenixKit.Module` behaviour or `ModuleRegistry` API.

---

## What Changed

### 1. `admin_tabs.ex` — Fix `settings_visible?/1` false positives

**Problem:** The Settings tab was shown to users with access to _any_ feature module — even modules that have no settings tabs. Caused by iterating `all_feature_keys()` (all 20 module keys) instead of only keys for modules that actually declare settings tabs.

**Fix:** Added `settings_tab_permissions/0` helper that pulls permission keys from `ModuleRegistry.all_settings_tabs()` — only modules with actual settings content.

```elixir
# Before: checks ALL feature keys
Enum.any?(ModuleRegistry.all_feature_keys(), &Scope.has_module_access?(scope, &1))

# After: checks only keys from modules with settings tabs
Enum.any?(settings_tab_permissions(), &Scope.has_module_access?(scope, &1))
```

---

### 2. `registry.ex` — Cache live_view → permission mapping at tab init time

**Problem:** When module tabs were cached in ETS at startup, the live_view → permission mapping was not registered. This meant auth couldn't enforce permissions for plugin LiveViews — any admin user could access any plugin page regardless of whether they had the module permission.

**Fix (part 1):** In the ETS caching loop, call `auto_register_custom_permission` for each admin-level tab with a binary permission. This ensures the `live_view → permission` mapping is populated at init time, not only when tabs are explicitly registered via config.

**Fix (part 2):** Pass `live_view: tab.live_view` into the `auto_register_custom_permission` map in the tab config registration path (was previously omitted, so the mapping was never cached even when called).

---

### 3. `registry.ex` + `permissions.ex` — Auto-grant feature module keys to Admin role

**Problem:** `Permissions.auto_grant_to_admin_roles` was only called for _custom_ permission keys (registered via `register_custom_key`). Built-in feature module keys (like `"billing"`, `"tickets"`) took a different code path and were skipped. Result: Admin users didn't automatically receive feature module permissions on first discovery of external plugin modules.

**Fix:** In `auto_register_custom_permission`, added an explicit check: if the permission key is a built-in feature module key, call `Permissions.auto_grant_to_admin_roles(perm)` directly.

`auto_grant_to_admin_roles` was also promoted from `defp` to `def` (with `@doc` and `@spec`) since it is now called from `registry.ex` outside of `permissions.ex`.

---

### 4. `integration.ex` — Move plugin routes into the core admin `live_session`

**Problem:** Plugin module routes were in a separate `live_session` (`:phoenix_kit_plugins{suffix}`) with `layout` and `on_mount` declared independently. This caused navigation issues: clicking between core admin pages and plugin pages triggered a full LiveView disconnect/reconnect because they were in different sessions.

**Fix:** Plugin routes are merged into the single `:phoenix_kit_admin{suffix}` live_session alongside all core admin routes. The `_plugin_session_name` variable is retained but unused (prefixed with `_`).

Layout for plugin views is now applied by `maybe_apply_plugin_layout/1` in `auth.ex` (see below) rather than by the session declaration.

---

### 5. `integration.ex` — Collect `settings_tabs` in addition to `admin_tabs` for route generation

**Problem:** `compile_module_admin_routes` only called `admin_tabs/0` on external modules. Modules that provide settings panels via `settings_tabs/0` had their LiveViews silently unrouted — the tabs appeared in the sidebar but clicking them returned a 404.

**Fix:** `compile_module_admin_routes` now collects both `admin_tabs` and `settings_tabs` from each external module via the new `collect_module_tabs/2` helper.

```elixir
defp collect_module_tabs(mod, callback) do
  if function_exported?(mod, callback, 0) do
    apply(mod, callback, [])
    |> Enum.filter(&tab_has_live_view?/1)
    |> Enum.map(&tab_struct_to_route/1)
  else
    []
  end
end
```

---

### 6. `auth.ex` — Auto-apply admin layout for external plugin LiveViews

**Problem:** After merging plugin routes into the core `live_session`, plugin views lost their admin layout. Core views use `LayoutWrapper` in their templates to apply the layout. External plugin views don't — they're expected to just render content. The previous separate session handled this via `layout: {PhoenixKitWeb.Layouts, :admin}` on the session declaration.

**Fix:** Added `maybe_apply_plugin_layout/1` called from `:phoenix_kit_ensure_admin` `on_mount`. It detects external plugin views (not under `PhoenixKitWeb.*` or `PhoenixKit.*` namespaces) and injects the admin layout via `socket.private[:live_layout]`.

```elixir
defp maybe_apply_plugin_layout(socket) do
  view = socket.view
  if external_plugin_view?(view) do
    put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :admin})
  else
    socket
  end
end

defp external_plugin_view?(view) do
  case Module.split(view) do
    ["PhoenixKitWeb" | _] -> false
    ["PhoenixKit" | _]    -> false
    _                     -> true
  end
end
```

Plugin authors write content LiveViews. They get the admin chrome (sidebar, header, layout) for free.

---

## Files Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit/dashboard/admin_tabs.ex` | Fix `settings_visible?` to check only modules with settings tabs |
| `lib/phoenix_kit/dashboard/registry.ex` | Cache live_view→permission at ETS init; auto-grant feature keys to Admin |
| `lib/phoenix_kit/users/permissions.ex` | Promote `auto_grant_to_admin_roles` to public |
| `lib/phoenix_kit_web/integration.ex` | Merge plugin routes into core session; collect `settings_tabs` |
| `lib/phoenix_kit_web/users/auth.ex` | Auto-apply admin layout for external plugin views |

## Related PRs

- Previous: [#359 — plugin module system](/dev_docs/pull_requests/2026/359-plugin-module-system/)
