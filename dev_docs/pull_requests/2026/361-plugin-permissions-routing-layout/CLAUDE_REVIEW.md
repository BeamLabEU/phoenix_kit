# PR #361 — Fix external plugin module permissions, routing, and layout integration

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/361
**Author:** @mdon
**Merged:** 2026-02-24 into `dev`
**Additions:** +76 | **Deletions:** -30
**Reviewer:** Claude Sonnet 4.6

---

## Executive Summary

This is a well-scoped follow-up to PR #359 that fixes six concrete issues found when exercising the plugin system in a real integration. All fixes are in the right places. The implementation is clean — no over-engineering, no churn. The routing consolidation (moving plugin routes into the core session) is the most impactful change and the right architectural call.

**Verdict: All fixes correct. No blocking concerns. One minor observation about the `_plugin_session_name` dead variable. Correctly merged.**

---

## Fix-by-Fix Analysis

### Fix 1: `settings_visible?` false positives (`admin_tabs.ex`)

**Correct.** The original `all_feature_keys()` check had no way to know which modules actually provide settings — it just iterated all 20 feature keys. The new `settings_tab_permissions/0` asks the registry directly for modules that have settings content.

The `Enum.filter(&is_binary/1)` guard is defensive but appropriate — tab permissions should always be strings, but an atom or nil could theoretically slip through from a misconfigured external module.

One small note: `settings_tab_permissions/0` calls `ModuleRegistry.all_settings_tabs()` at every `settings_visible?` call, which iterates all modules. In practice this is called once per admin page mount and the module list is backed by `:persistent_term`, so it's fast enough. If it becomes a hotspot, memoization in the ETS cache (same as `settings_tabs/0`) would be the path.

---

### Fix 2: Cache live_view → permission mapping at ETS init (`registry.ex`)

**Correct.** The root cause was clear: the auth module enforces permissions by looking up `view_module → permission` in a cache populated by `cache_custom_view_permission/2`. If that cache was never populated for plugin tabs, the enforcement silently fell back to allowing access.

The fix has two parts:
1. The ETS caching loop in `cache_tabs_in_ets/1` now calls `auto_register_custom_permission` for each tab. This is idempotent (the underlying `cache_custom_view_permission` is an ETS insert) and safe to call multiple times.
2. Passing `live_view:` in the `auto_register_custom_permission` map call on line 503 ensures the field is available when processing the config path.

The fix correctly gates on `tab.level == :admin and is_binary(tab.permission)` — settings tabs at non-admin level don't need this mapping.

---

### Fix 3: Auto-grant feature module keys to Admin role (`registry.ex` + `permissions.ex`)

**Correct.** The existing `register_custom_key` path called `auto_grant_to_admin_roles` internally. Feature module keys took a different branch (they're already registered, so `register_custom_key` is skipped) and therefore never got auto-granted.

The fix adds an explicit `if perm in builtin_keys` branch inside `auto_register_custom_permission`. The flag-key mechanism in `auto_grant_to_admin_roles` (`"auto_granted_perm:#{key}"` in settings) ensures repeated calls are no-ops if the Owner has manually revoked the key — idempotency is preserved.

Promoting `auto_grant_to_admin_roles` to `def` is necessary and correct. The `@spec` and `@doc` additions are welcome — this is now a cross-module API.

---

### Fix 4: Move plugin routes into core `live_session` (`integration.ex`)

**Correct and architecturally important.**

Having plugin routes in a separate `live_session` caused full LiveView disconnects on navigation between core admin pages and plugin pages. Two separate sessions = two separate websocket connections = navigation triggers a reconnect rather than a patch.

Moving plugin routes into `:phoenix_kit_admin{suffix}` makes navigation seamless. The layout is no longer applied at the session level — it's applied per-view by the `on_mount` hook (`maybe_apply_plugin_layout/1`), which correctly distinguishes core from external views.

**`_plugin_session_name` dead variable:** The variable is now unused (prefixed with `_` to silence the warning). It could be removed entirely, but keeping it documents that the session name was intentionally reserved and might be useful if plugin routes ever need re-separation (e.g., for different auth requirements). Harmless either way.

---

### Fix 5: Collect `settings_tabs` for route generation (`integration.ex`)

**Correct.** The `collect_module_tabs/2` abstraction is a small but clean improvement over the duplicated `function_exported?` + `filter` + `map` pattern it replaces. The logic is identical for `admin_tabs` and `settings_tabs` — extracting it is appropriate.

Including `settings_tabs` in route generation is necessary: without routes, tabs appear in the sidebar but navigate to a 404. This was a silent UX breakage.

---

### Fix 6: Auto-apply admin layout for external plugin views (`auth.ex`)

**Correct.** The implementation choice is sound:

- Core `PhoenixKitWeb.*` and `PhoenixKit.*` views manage their own layout via `LayoutWrapper` in templates. Applying the layout again via `socket.private[:live_layout]` would double-wrap.
- External plugin views render content only. They should get the admin chrome without any extra work by the plugin author.

The `external_plugin_view?/1` detection by namespace prefix is the right heuristic. It's simple, explicit, and handles the common case. An external `MyApp.Admin.BillingLive` or `PhoenixKitBilling.AdminLive` will both correctly be detected as external.

**Edge case:** A plugin that intentionally opts out of the admin layout (e.g., a full-screen editor) has no escape hatch currently. It would need to explicitly override `socket.private[:live_layout]` in its own `on_mount`. This is an uncommon case and can be documented if it comes up.

**`socket.private[:live_layout]`:** This uses a Phoenix LiveView internal mechanism. It's the same pattern Phoenix itself uses when you declare `layout:` on a `live_session`. It's stable across Phoenix LiveView versions and is the right approach here.

---

## Security Review

The key security-relevant fix is Fix 2 (live_view → permission cache). Before this fix, the auth enforcement in `:phoenix_kit_ensure_admin` would look up a plugin view's permission key, find nothing in the cache, and fall back to allowing access for any admin. After this fix, plugin views are correctly gated behind their declared permission keys.

The `external_plugin_view?/1` check in Fix 6 is not a security boundary — it only determines layout application. Auth enforcement happens in `enforce_admin_view_permission/2` regardless of namespace.

---

## What This Means for Plugin Authors

After this PR, the external plugin author workflow is:

1. Declare `admin_tabs/0` (and optionally `settings_tabs/0`) with `live_view:` and `permission:` fields
2. Write a content-only LiveView (no LayoutWrapper, no explicit layout)
3. Route generation, layout application, permission enforcement, sidebar visibility, and Admin auto-grant all happen automatically

This is the correct DX for a plugin system.

---

## Minor Issues

**`_plugin_session_name` retained but unused** (`integration.ex:437`)
The dead variable could be removed entirely. The `_` prefix suppresses the warning, but removing it would clean up intent. Very low priority.

---

## No Blocking Concerns

All six fixes address real integration bugs and are implemented correctly. The changes are tight — 76 additions across 5 files for 6 distinct fixes is a healthy ratio. No refactoring scope creep, no unnecessary abstraction.
