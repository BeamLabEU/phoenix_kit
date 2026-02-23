# PR #351 Review - Fix comments admin display and admin language switcher

**Reviewer:** Claude
**Status:** MERGED
**Verdict:** Approve with observations

---

## Summary

Two focused bug fixes: (1) auto-register built-in comment resource handlers so parent apps work out of the box, and (2) fix locale disappearing from admin URLs during sidebar navigation. Both fixes are well-targeted and solve real user-facing issues.

---

## Detailed Review

### 1. Comments: Auto-register built-in handlers

**`lib/modules/comments/comments.ex`**

Good approach. `Map.merge(default_resource_handlers(), configured)` gives user config precedence over defaults, which is the correct merge order.

**Minor concern:** The `default_resource_handlers/0` function hardcodes `PhoenixKit.Modules.Posts` as a dependency. This creates a compile-time coupling between the Comments and Posts modules. If Posts isn't loaded (e.g., the parent app doesn't use Posts), the atom still exists but `Code.ensure_loaded?/1` at line 420 handles this gracefully by returning `%{}`. So this is safe at runtime, but it's a soft coupling worth noting.

**`lib/modules/comments/web/index.html.heex`**

Changing `(deleted)` to `String.slice(to_string(comment.resource_id), 0..7)` is a UX improvement. The old label was misleading -- an unresolvable resource isn't necessarily deleted; the handler may just not be configured. Showing the truncated ID gives admins actionable debugging information.

### 2. Locale: Bypassing Routes.path for admin paths

This is the core of the PR. The root issue is an architectural tension:

- `Routes.path/2` intentionally strips locale from reserved paths (including `/admin`) to prevent crossing `live_session` boundaries.
- But the admin dashboard uses a `/:locale/admin/*` route scope that *needs* locale in the URL.

The fix bypasses `Routes.path/2` for admin paths in three locations, building URLs directly with `"#{base_prefix}/#{locale}#{path}"`.

#### Observations

**~~Code duplication across 3 files~~ (RESOLVED).** The same URL-building pattern appeared in `sidebar.ex`, `tab_item.ex`, and `admin_nav.ex`. This has been extracted into `Routes.admin_path/2` in `lib/phoenix_kit/utils/routes.ex`. All 3 callers now use the shared helper. The `admin_path/2` function also handles the `nil` locale case by falling back to `path/1`, eliminating the `locale != nil` guard that callers had to check individually.

### 3. Layout Wrapper: `current_locale_base`

**`lib/phoenix_kit_web/components/layout_wrapper.ex`**

Clean fix. Previously `current_locale_base` was read from `assigns` where it was never set (always nil). Now it's derived from `current_locale` using `DialectMapper.extract_base/1` with a nil guard. The `&&` short-circuit is idiomatic Elixir.

### 4. Language Switcher: `<a>` to `<button phx-click>`

**`lib/phoenix_kit_web/components/admin_nav.ex`**

Good change. Using `phx-click="phoenix_kit_set_locale"` instead of a plain `<a href>` ensures the locale switch goes through the LiveView event handler, which:
1. Persists the user's locale preference via `save_user_locale_preference/2`
2. Performs a proper LiveView redirect

The previous `<a href>` approach was a full page navigation that wouldn't save the user's preference.

### 5. Auth: `locale_allowed?/1`

**`lib/phoenix_kit_web/users/auth.ex`**

Previously `language_enabled?/1` only checked the Languages module's enabled list. If a language was configured as an admin language but not enabled in the Languages module, it would be rejected. The new `locale_allowed?/1` checks both sources with `or`, which is the correct inclusive behavior.

---

## Risk Assessment

| Area | Risk | Notes |
|------|------|-------|
| Comments auto-registration | Low | Graceful fallback via `Code.ensure_loaded?` |
| Admin URL bypass | Low | Centralized in `Routes.admin_path/2` after post-merge cleanup |
| Language switcher mechanism | Low | Uses existing, tested `phoenix_kit_set_locale` event handler |
| `locale_allowed?` | Low | Strictly additive -- allows more locales, never fewer |

---

## Suggestions for Follow-up

1. ~~**Extract shared admin path builder.**~~ **DONE** -- Extracted to `Routes.admin_path/2` in a post-merge commit.

2. **Comment resource handler extensibility.** As more built-in modules add comment support, `default_resource_handlers/0` will grow. Consider a registry pattern (similar to admin tab registration) where modules register themselves as comment resource handlers, rather than maintaining a hardcoded map.
