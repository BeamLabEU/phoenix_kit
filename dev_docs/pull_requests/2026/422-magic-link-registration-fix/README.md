# PR #422 — Fix Magic Link registration respecting allow_registration

**Author:** Tim (timujinne)
**Date:** 2026-03-17
**Branch:** dev
**Status:** Merged

## What

Three changes bundled in this PR:

1. **Magic Link registration bypass fix** — The Magic Link registration page (`/users/register/magic-link`) ignored the `allow_registration` setting, allowing users to register via direct URL even when registration was disabled.

2. **Authorization settings UI improvement** — The Magic Link registration checkbox in admin settings now auto-disables when `allow_registration` is off, with a visual "(registration disabled)" hint.

3. **Modules page refactor** — Replaced the hardcoded Newsletters card with generic external module rendering. External modules now show "Requires X" badges for unmet dependencies and action link buttons from `admin_tabs/0`.

4. **Sitemap fix** — Excluded `/newsletters/unsubscribe` from sitemap router discovery (functional page requiring a token).

## Why

The Magic Link registration path was a security gap — admins could disable registration globally, but users could still register via the magic link URL. The modules page had a hardcoded Newsletters card that caused double-rendering when the `phoenix_kit_newsletters` package was installed alongside the generic external module discovery.

## How

- Added `Settings.get_boolean_setting("allow_registration", true)` check in `MagicLinkRegistrationRequest.mount/3` — redirects to login with flash error if disabled
- Authorization settings template conditionally disables the checkbox via `disabled` attribute and forces `checked` to false
- `load_external_modules/1` now enriches external modules with `required_modules` and `admin_links`
- New `extract_admin_links/1` helper reads `admin_tabs/0` from external modules
