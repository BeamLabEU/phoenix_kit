# PR #468: Unify language systems and add continent-grouped language switcher

**Author**: @mdon (Max Don)
**Status**: Merged
**Branch**: `mdon/dev` -> `dev`
**Date**: 2026-03-31

## Goal

Eliminate the dual language system (`admin_languages` setting vs `languages_config`) by unifying both admin and frontend language selection under the Languages module. Add continent-based grouping to the language switcher for projects with many enabled languages.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/modules/languages/languages.ex` | Add `normalize_language_settings/0`, `get_enabled_languages_by_continent/0` |
| `lib/modules/languages/README.md` | Update docs: remove admin_languages references, add Language struct/continent docs |
| `lib/modules/sitemap/sources/publishing.ex` | Use `Languages.get_default_language()` instead of `admin_languages` setting |
| `lib/phoenix_kit/settings/events.ex` | Remove `broadcast_admin_languages_changed/1` |
| `lib/phoenix_kit/settings/setting.ex` | Remove `admin_languages` field from schema/changeset |
| `lib/phoenix_kit/settings/settings.ex` | Remove `admin_languages` from defaults |
| `lib/phoenix_kit/supervisor.ex` | Add startup Task to run `normalize_language_settings/0` |
| `lib/phoenix_kit/utils/multilang.ex` | Add rescue blocks to `enabled?/0`, `enabled_language_codes/0`, `default_language_code/0` |
| `lib/phoenix_kit/utils/routes.ex` | Replace `admin_languages` JSON parsing with `Languages.get_default_language()` |
| `lib/phoenix_kit_web/components/admin_nav.ex` | Use `Languages.get_display_languages()` instead of `admin_languages` JSON |
| `lib/phoenix_kit_web/components/core/language_switcher.ex` | Add continent grouping, `group_by_continent`/`continent_threshold` attrs, refactor into helper functions |
| `lib/phoenix_kit_web/components/layout_wrapper.ex` | Replace `admin_language_dropdown` with `language_switcher_dropdown` in admin layout |
| `lib/phoenix_kit_web/integration.ex` | Remove `/admin/settings/languages/backend` route |
| `lib/phoenix_kit_web/live/modules/languages.ex` | Remove Backend tab logic, admin_languages sync, all backend event handlers |
| `lib/phoenix_kit_web/live/modules/languages.html.heex` | Remove Frontend/Backend tab UI, flatten to single-page layout |
| `lib/phoenix_kit_web/users/auth.ex` | Replace `admin_language_enabled?/1` with unified `language_enabled?/1`, use `Routes.get_default_admin_locale/0` |

### New Files

| File | Purpose |
|------|---------|
| `test/integration/languages/crud_test.exs` | 28 integration tests for language CRUD operations |
| `test/integration/languages/normalize_test.exs` | 10 integration tests for legacy migration normalization |
| `test/phoenix_kit/languages/dialect_mapper_test.exs` | 20 unit tests for DialectMapper |
| `test/phoenix_kit/utils/multilang_test.exs` | 25 unit tests for Multilang utilities |

### Breaking Changes

- **Route removed**: `/admin/settings/languages/backend` no longer exists
- **Setting removed**: `admin_languages` key deleted from Settings schema and defaults
- **Event removed**: `broadcast_admin_languages_changed/1` no longer available
- **Admin layout**: `admin_language_dropdown` replaced with `language_switcher_dropdown` component

### Component API Changes

| Component | Change |
|-----------|--------|
| `language_switcher_dropdown/1` | New attrs: `group_by_continent` (bool, default: true), `continent_threshold` (int, default: 7) |

## Implementation Details

- **Legacy migration**: `normalize_language_settings/0` runs as a startup Task in the supervisor, after settings cache is warmed. Reads `admin_languages` JSON, adds missing codes to unified config, clears the old setting. Idempotent.
- **Continent grouping**: Uses `get_enabled_languages_by_continent/0` which filters the existing continent data to only include enabled languages. Two-step UI (continent -> language) implemented with `Phoenix.LiveView.JS` commands — no extra LiveView round-trips.
- **Inline JS search**: Language search within continent panels uses inline `oninput` handlers instead of a LiveView hook — simpler, no BEAM round-trip for filtering.
- **Error hardening**: Added `rescue` blocks throughout multilang/routes/language_switcher to prevent crashes during startup or when Languages module isn't fully initialized.

## Related

- Consumer: Admin language dropdown, frontend language switcher, auth locale resolution
- Previous: Dual admin_languages/languages_config system (now unified)
- Tests: 87 new tests across 4 files
