# PR #351 - Fix comments admin display and admin language switcher

## What

Two bug fixes shipped together:

1. **Comments admin page**: Built-in comment resource handlers (e.g., Posts) were not auto-registered, so comments displayed incorrectly in parent apps unless `comment_resource_handlers` was manually configured. Also replaced misleading "(deleted)" label with a truncated resource UUID when a resource can't be resolved.

2. **Admin language switcher**: Locale was disappearing from admin URLs on sidebar navigation. Root cause: `Routes.path/2` treats `/admin` as a reserved path and strips locale prefixes, but admin sidebar/tab links need locale in the URL for the `/:locale/admin/*` route scope.

## Why

- Parent apps using the Comments module saw broken comment displays out of the box because the Posts handler wasn't registered by default.
- Switching languages in the admin dashboard caused navigation to lose the locale, falling back to the default language.

## How

### Comments fix
- Added `resource_handlers/0` that merges built-in defaults (`%{"post" => Posts}`) with user-configured handlers via `Map.merge/2`.
- Changed "(deleted)" text to show first 8 chars of resource UUID for better debugging context.

### Locale fix
- `layout_wrapper.ex`: Derives `current_locale_base` from `current_locale` via `DialectMapper.extract_base/1` instead of reading a non-existent assign.
- `sidebar.ex` and `tab_item.ex`: Bypass `Routes.path/2` for admin paths, building locale-prefixed URLs directly to avoid the reserved-path locale stripping.
- `admin_nav.ex`: Changed language switcher from `<a href>` to `<button phx-click>` using the existing `phoenix_kit_set_locale` LiveView event, and builds URLs directly for the same reason.
- `auth.ex`: Added `locale_allowed?/1` fallback that checks both `language_enabled?/1` (Languages module) and `admin_language_enabled?/1` (admin config), fixing locale validation when only admin languages are configured.

## Files Changed (7)

| File | Changes |
|------|---------|
| `lib/modules/comments/comments.ex` | Auto-register built-in resource handlers |
| `lib/modules/comments/web/index.html.heex` | Show truncated UUID instead of "(deleted)" |
| `lib/phoenix_kit_web/components/admin_nav.ex` | Language switcher: `<a>` to `<button phx-click>`, direct URL building |
| `lib/phoenix_kit_web/components/dashboard/sidebar.ex` | Bypass Routes.path for admin locale paths |
| `lib/phoenix_kit_web/components/dashboard/tab_item.ex` | Bypass Routes.path for admin locale paths |
| `lib/phoenix_kit_web/components/layout_wrapper.ex` | Derive `current_locale_base` properly |
| `lib/phoenix_kit_web/users/auth.ex` | Add `locale_allowed?/1` combining both language sources |
