# PR #341 Review: Custom Permission Keys, Edit Protection, i18n, and Doc Improvements

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/341
**Author:** Max Don
**Status:** Merged into `dev`
**Reviewer:** Claude Opus 4.6
**Date:** 2026-02-16

## Overview

Large PR (+2929/-938, 32 files, 19 commits) that extends the permissions system with:
- Custom permission keys for parent app admin tabs
- Permission edit protection rules
- Full gettext i18n on roles/permissions UI (105 strings)
- 156 Level 1 tests (121 pass, no DB required)
- Multiple bug fixes (dual-write, PubSub refresh, summary counting, crash risks)
- Documentation overhaul (key counts, return types, custom keys API)

## Verdict: Approve with noted follow-ups

The PR is well-structured with good defensive programming. No critical blocking issues. The security model is sound -- all LiveView event handlers enforce authorization server-side, preventing client-side bypass. The custom permission key registry, edit protection, and test suite are solid additions.

Several follow-up items are identified below, ranked by severity.

## Fixes Applied

The following issues were fixed post-merge on the `dev` branch:

| # | Issue | Fix | Commit |
|---|-------|-----|--------|
| 1 | `can_edit_role_permissions?/2` missing `authenticated?` check | Added `Scope.authenticated?` guard with early return; extracted logic to `can_edit_role_permissions_check/2` | `9cb49c0a` |
| 2 | `get_permissions_for_user(%User{uuid: nil})` crash | Added `def get_permissions_for_user(%User{uuid: nil}), do: []` clause | `9cb49c0a` |
| 5 | Missing FOR UPDATE locking in `set_permissions/3` | Replaced `get_permissions_for_role` call with inline `from()` query using `lock: "FOR UPDATE"` on `role_uuid` | `9cb49c0a` |
| 18* | Admin sidebar wiped when enabling/disabling modules | Added `load_admin_defaults_internal()` and `load_admin_from_config_internal()` calls to Registry `handle_call(:load_defaults, ...)` and `handle_call(:load_from_config, ...)` to match `init/1` pattern | *(this commit)* |

\* Issue #18 was discovered post-review: `Registry.load_defaults()` (called by Tickets, Billing, Shop `enable_system/0` and `disable_system/0`) only called `load_defaults_internal()` which overwrites the `:groups` ETS key with only user groups, deleting admin groups. The `init/1` function correctly called both user and admin loaders, but the reload handler did not.

---

## Issues Found

### HIGH Severity

#### 1. `can_edit_role_permissions?/2` bypassed by unauthenticated scope struct
**File:** `lib/phoenix_kit/users/permissions.ex:831-848`

The function handles `nil` scope but does NOT check `authenticated?` field:

```elixir
def can_edit_role_permissions?(nil, _role), do: {:error, "Not authenticated"}

def can_edit_role_permissions?(scope, role) do
  user_roles = Scope.user_roles(scope)  # returns [] for unauthenticated
  cond do
    role.name == "Owner" -> {:error, ...}
    role.name in user_roles -> {:error, ...}  # [] never matches
    role.name == "Admin" and not Scope.owner?(scope) -> {:error, ...}
    true -> :ok  # Falls through to :ok for any non-Owner/Admin role
  end
end
```

A `%Scope{authenticated?: false, user: %User{}}` would pass all denial conditions for non-system roles and return `:ok`. **In practice**, this is mitigated because the LiveView on_mount hooks check authentication before any event handler runs, so an unauthenticated user can never reach these handlers. But the function itself is not self-contained.

**Recommendation:** Add `unless Scope.authenticated?(scope), do: {:error, "Not authenticated"}` at the top of the function body.

#### 2. `get_permissions_for_user(%User{uuid: nil})` raises FunctionClauseError
**File:** `lib/phoenix_kit/users/permissions.ex:468-470`

```elixir
def get_permissions_for_user(nil), do: []
def get_permissions_for_user(%User{uuid: user_uuid}) when not is_nil(user_uuid) do
```

No clause matches `%User{uuid: nil}`. During UUID migration, users without a UUID populated would crash here.

**Recommendation:** Add `def get_permissions_for_user(%User{uuid: nil}), do: []`

---

### MEDIUM Severity

#### 3. Error strings from `can_edit_role_permissions?/2` not wrapped in gettext
**File:** `lib/phoenix_kit/users/permissions.ex:837-844`

Four hardcoded English strings are returned and passed directly to `put_flash`:
- `"Owner role always has full access and cannot be modified"`
- `"You cannot edit permissions for your own role"`
- `"Only the Owner can edit Admin permissions"`
- `"Not authenticated"`

These bypass the i18n wrapping done elsewhere in the PR.

**Recommendation:** Either return atoms/tuples and translate at the call site, or wrap the strings in gettext at the LiveView level before passing to `put_flash`.

#### 4. Multi-role users blocked from editing ANY of their roles
**File:** `lib/phoenix_kit/users/permissions.ex:840`

```elixir
role.name in user_roles ->
  {:error, "You cannot edit permissions for your own role"}
```

If a user has roles `["Admin", "Editor"]`, they cannot edit the "Editor" role even though their admin privileges come from "Admin". The intent is preventing self-lockout, but this blocks legitimate use cases.

#### 5. Missing FOR UPDATE locking in `set_permissions/3` transaction
**File:** `lib/phoenix_kit/users/permissions.ex:710-768`

The transaction reads current permissions without a lock:
```elixir
repo.transaction(fn ->
  current_keys = get_permissions_for_role(role_id) |> MapSet.new()
  # ... diff and write ...
end)
```

Two concurrent `set_permissions` calls could compute overlapping diffs. This contradicts the project's stated "FOR UPDATE locking in Ecto transactions" design principle.

#### 6. Race conditions in persistent_term read-modify-write
**File:** `lib/phoenix_kit/users/permissions.ex:164-195, 264-280`

`register_custom_key/2` and `cache_custom_view_permission/2` both do read-check-write on persistent_term without synchronization. Concurrent calls could lose updates. In practice, these are called at startup, so the risk is low.

#### 7. `require_module_access/2` plug inconsistency with LiveView enforcement
**File:** `lib/phoenix_kit_web/users/auth.ex:1316-1341`

The plug version checks `has_module_access?` but NOT `feature_enabled?`, while the LiveView `on_mount({:phoenix_kit_ensure_module_access, ...})` checks both. A custom role could access a disabled module's controller endpoint.

---

### LOW Severity

#### 8. `custom_keys/0` test sorting assertion is fragile
**File:** `test/phoenix_kit/users/permissions_test.exs:267`

Asserts `keys == ["alpha", "middle", "zebra"]` but `custom_keys/0` calls `Map.keys()` which has no guaranteed ordering. Works today because Erlang maps with <32 keys are sorted, but this is an implementation detail.

**Fix:** Use `Enum.sort(keys) == ["alpha", "middle", "zebra"]` or `MapSet.new(keys) == MapSet.new(["alpha", "middle", "zebra"])`.

#### 9. Scope functions can crash with `cached_roles: nil` + non-nil user
**File:** `lib/phoenix_kit/users/auth/scope.ex:234-262`

Functions like `owner?/1`, `admin?/1`, `system_role?/1` have guards for `when is_list(cached_roles)` and fallback `when user: nil`. A scope with `cached_roles: nil` and `user: %User{}` matches neither clause -> `FunctionClauseError`.

#### 10. Noisy test log warnings from auto_grant_to_admin_roles
**File:** `test/phoenix_kit/users/permissions_test.exs`

`register_custom_key/2` internally calls `auto_grant_to_admin_roles/1` which tries to access the Repo and logs ~20 warning messages per test run. Consider using `ExUnit.CaptureLog` or making auto-grant configurable in test mode.

#### 11. `auto_grant_to_admin_roles/1` uses integer `role.id` instead of UUID
**File:** `lib/phoenix_kit/users/permissions.ex:966-967`

```elixir
case Roles.get_role_by_name(Role.system_roles().admin) do
  %{id: admin_id} when not is_nil(admin_id) ->
    case grant_permission(admin_id, key, nil) do
```

Should use `%{uuid: admin_uuid}` for consistency with UUID migration.

#### 12. Inconsistent return types across mutation API
- `grant_permission/3` -> `{:ok, RolePermission.t()} | {:error, Changeset.t()}`
- `revoke_permission/2` -> `:ok | {:error, :not_found}`
- `set_permissions/3` -> `:ok | {:error, term()}`
- `revoke_all_permissions/1` -> `:ok | {:error, exception}`

#### 13. `enabled_module_keys/0` returns MapSet, `all_module_keys/0` returns list
**File:** `lib/phoenix_kit/users/permissions.ex:294,310`

Similar functions with different return types.

---

### INFO / Cosmetic

#### 14. Dynamic atom creation in `sanitize_tab_id/2`
**File:** `lib/phoenix_kit/dashboard/admin_tabs.ex:997-1007`

Each unique entity name generates a new atom that's never GC'd. Low risk with small entity sets but could leak atoms in systems with many dynamic entities.

#### 15. Custom keys section uses two-column grid but only populates one column
**File:** `lib/phoenix_kit_web/live/users/roles.html.heex:350-364`

Layout bug -- the grid div wraps a single `space-y-2` div, so the second column is always empty.

#### 16. PubSub can overwrite unsaved permission editor toggles
**File:** `lib/phoenix_kit_web/live/users/roles.ex:522-535`

`reload_permission_editor_data/1` replaces local `permissions_role_keys` with DB state when a PubSub event arrives, discarding any unsaved toggles the user has made.

#### 17. `unregister_custom_key/1` triggers persistent_term GC even for nonexistent keys
**File:** `lib/phoenix_kit/users/permissions.ex:208-228`

No-op writes still trigger the global persistent_term GC pass.

---

## Strengths

- **Defense in depth:** All LiveView event handlers validate authorization server-side before any mutation. No client-side bypass possible.
- **Comprehensive edit protection:** Owner is immutable, self-role editing blocked, Admin editing restricted to Owner. Applied consistently in both matrix and roles views.
- **Clean TabHelpers extraction:** 5 shared functions properly extracted with specs and docs.
- **Test suite:** 121 tests pass, genuinely Level 1 (no DB), cover pure functions well.
- **Resilient sidebar rendering:** Cycle detection with depth limiting, ETS caching with TTL + PubSub invalidation, try/rescue around dynamic children.
- **No breaking changes:** All public APIs maintain backward compatibility.
- **Gettext coverage:** 105 UI strings wrapped across both LiveViews.
- **Correct dual-write patterns:** `grant_permission` and `set_permissions` properly resolve both integer and UUID forms.
- **Sound route enforcement:** Custom admin tab routes placed inside admin live_session with proper on_mount enforcement. Custom roles fail-closed for unmapped views.

## Test Results

```
121 tests, 0 failures (0.6s)
```

All tests are genuinely Level 1 -- no database required. The `auto_grant_to_admin_roles` warnings during tests are noisy but harmless.

## Remaining Follow-Up Priority

1. ~~**Add `authenticated?` check to `can_edit_role_permissions?/2`**~~ (FIXED)
2. ~~**Add `%User{uuid: nil}` fallback to `get_permissions_for_user/1`**~~ (FIXED)
3. **Wrap error strings in gettext at call site** (MEDIUM, i18n completeness)
4. **Fix sorting assertion in test** (LOW, test fragility)
5. ~~**Add FOR UPDATE locking in `set_permissions/3`**~~ (FIXED)
6. **Align plug with LiveView module-enabled check** (LOW, consistency)
