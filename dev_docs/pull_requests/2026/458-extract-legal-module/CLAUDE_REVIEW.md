# PR #458: Remove Legal module from core (extracted to phoenix_kit_legal) - Review

**Author**: @timujinne
**Reviewer**: Claude (Anthropic)
**Status**: Merged
**Date**: 2026-03-28
**Branch**: `legal-cookie-consent-fix` -> `dev`
**Stats**: 45 files changed, +4,384 / -10,156 (net -5,772 lines)

## Overview

This PR completes the extraction of the Legal module from PhoenixKit core into the standalone `phoenix_kit_legal` package (repo: BeamLabEU/phoenix_kit_legal). It also includes two supplementary changes: removing duplicate `LayoutWrapper` wrappers from admin module templates (which caused double sidebar rendering), and adding conditional billing profile routes for the dashboard.

This is a follow-up to PR #453, which began the extraction process and bundled cookie consent UX fixes, billing extraction, and shop extraction.

---

## Commits

| Commit | Description |
|--------|-------------|
| `4ba7386` | Remove duplicate LayoutWrapper from 16 admin module `.heex` templates + 1 `.ex` file |
| `95670f1` | Add user dashboard routes for billing profiles (conditional on `phoenix_kit_billing`) |
| `1147313` | **Main commit**: Remove Legal module from core (8 module files, component, controller, JS, 7 templates) |
| `cb8028e` | Fix: Remove LayoutWrapper from 4 remaining storage/maintenance templates missed in first pass |
| `bebc2d1` | Merge upstream/dev, resolve delete conflicts |

---

## Change Analysis

### 1. Legal Module Deletion (core change)

**Deleted files (moved to `phoenix_kit_legal` package):**

| File | Lines | Purpose |
|------|-------|---------|
| `lib/modules/legal/legal.ex` | ~1,107 | Main context: framework management, consent config, page generation |
| `lib/modules/legal/legal_framework.ex` | ~52 | Framework struct (GDPR, CCPA, LGPD, etc.) |
| `lib/modules/legal/page_type.ex` | ~35 | Page type struct |
| `lib/modules/legal/schemas/consent_log.ex` | ~294 | Ecto schema for consent logging |
| `lib/modules/legal/services/template_generator.ex` | ~220 | EEx template rendering service |
| `lib/modules/legal/web/settings.ex` | ~378 | LiveView settings UI |
| `lib/modules/legal/web/settings.html.heex` | - | Settings template |
| `lib/modules/legal/README.md` | - | Module documentation |
| `lib/phoenix_kit_web/components/core/cookie_consent.ex` | ~438 | Cookie consent Phoenix component |
| `lib/phoenix_kit_web/controllers/consent_config_controller.ex` | ~79 | `/api/consent-config` API endpoint |
| `priv/legal_templates/*.eex` (7 files) | - | Privacy policy, terms, cookie policy, CCPA, etc. |
| `priv/static/assets/phoenix_kit_consent.js` | - | Auto-injected consent widget JS |

### 2. Conditional Loading Guards (integration seams)

All references to Legal modules in core are now wrapped with `Code.ensure_loaded?` guards so the core compiles cleanly without the Legal package installed.

**Guard locations:**

| File | Line(s) | What's guarded |
|------|---------|----------------|
| `integration.ex` | 266 | `/api/consent-config` route |
| `integration.ex` | 443 | `/admin/settings/legal` LiveView route |
| `layout_wrapper.ex` | 685 | `phoenix_kit_consent.js` script tag |
| `layout_wrapper.ex` | 698-711 | Cookie consent widget component |
| `root.html.heex` | 55 | `phoenix_kit_consent.js` script tag |
| `root.html.heex` | 182-195 | Cookie consent widget component |
| `dashboard.html.heex` | 158 | `phoenix_kit_consent.js` script tag |

**Compile-time suppressions (`@compile {:no_warn_undefined}`):**

| File | Suppressed modules |
|------|--------------------|
| `layout_wrapper.ex` | `PhoenixKit.Modules.Legal`, `PhoenixKit.Modules.Legal.CookieConsent` |
| `layouts.ex` | `PhoenixKit.Modules.Legal`, `PhoenixKit.Modules.Legal.CookieConsent` |
| `integration.ex` | `PhoenixKitWeb.Live.Modules.Legal.Settings`, `PhoenixKitWeb.Controllers.ConsentConfigController` |
| `auth.ex` | `PhoenixKitWeb.Live.Modules.Legal.Settings` |

**Dialyzer ignores updated** (`.dialyzer_ignore.exs`):
- Removed old Legal module regex patterns (pattern_match, invalid_contract, no_return, call)
- Added targeted `{file, :unknown_function}` tuples for `layout_wrapper.ex` and `root.html.heex`

### 3. Other Core Cleanups

| File | Change |
|------|--------|
| `phoenix_kit_web.ex` | Removed `import PhoenixKitWeb.Components.Core.CookieConsent` from `core_components` |
| `module_registry.ex` | Removed `PhoenixKit.Modules.Legal` from `internal_modules` list |
| `assets_controller.ex` | Removed `"phoenix_kit_consent.js"` from `@valid_assets` map |
| `auth.ex` | Removed `Legal.Settings => "legal"` from sidebar settings tab mapping |

### 4. LayoutWrapper Removal from Admin Templates

**Root cause**: Admin module templates were wrapped in `LayoutWrapper.app_layout`, but they render inside an admin `live_session` that already applies the admin layout. This caused double sidebar rendering.

**Fix**: Removed the redundant `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>` wrapper from 20 admin templates, leaving only the inner content `<div>`.

**Affected modules** (all under `lib/modules/`):
- `customer_service/web/` — details, edit, list, settings (4 templates)
- `db/web/` — activity, index, show (3 templates)
- `referrals/web/` — form, list, settings (3 templates)
- `sitemap/web/` — settings (1 template)
- `storage/web/` — bucket_form, dimension_form, dimensions, settings (4 templates)
- `maintenance/` — settings.ex (1 module) + settings.html.heex (1 template)

### 5. Billing Profile User Routes

Added conditional routes for `/dashboard/billing-profiles` (index, new, edit) in both localized and non-localized variants, guarded by `Code.ensure_loaded?(PhoenixKit.Modules.Billing)`. Follows the same pattern used for shop user routes.

---

## Quality Assessment

### What's Done Well

1. **Consistent guard pattern**: All 7 `Code.ensure_loaded?` guard sites follow the same pattern. The double-check pattern (`ensure_loaded? AND function_call?()`) for the cookie consent widget is correct — it gates both the script tag (needs the JS file) and the component render (needs the module + runtime config check).

2. **Namespace preservation**: The extracted package keeps the `PhoenixKit.Modules.Legal.*` namespace, meaning the `Code.ensure_loaded?` guards in core will seamlessly detect the package when installed. No import/alias changes needed in core.

3. **Clean dialyzer handling**: Switched from broad regex patterns (which could mask real issues) to targeted `{file, :unknown_function}` tuples. This is more precise and won't accidentally suppress future warnings in those files for different reasons.

4. **LayoutWrapper fix is correct**: The admin `live_session` already applies the admin layout via `on_mount`. The wrapper in templates was redundant and caused visual bugs (double sidebar). Removing it is the right fix.

5. **Two-commit approach for LayoutWrapper**: The follow-up commit (`cb8028e`) catching 4 missed templates shows thoroughness rather than leaving them broken.

### Issues Found

#### 1. (LOW) `ConsentConfigController` still in `@compile {:no_warn_undefined}` in `integration.ex`

**File**: `lib/phoenix_kit_web/integration.ex:11`

The controller module `PhoenixKitWeb.Controllers.ConsentConfigController` is listed in the `@compile {:no_warn_undefined}` directive, and its route is guarded by `Code.ensure_loaded?`. However, the controller file itself (`consent_config_controller.ex`) was deleted from core in this PR. This means the controller must be provided by the `phoenix_kit_legal` package under the same namespace for the route to work at runtime.

**Impact**: None if the package provides the controller. But if the package uses a different controller namespace, the guarded route at line 267 would match but 404 at runtime. This is an integration contract that should be verified.

**Recommendation**: Confirm the `phoenix_kit_legal` package exports `PhoenixKitWeb.Controllers.ConsentConfigController` at the expected path.

#### 2. FIXED (LOW): `dashboard.html.heex` loaded consent JS but never rendered the widget

**File**: `lib/phoenix_kit_web/components/layouts/dashboard.html.heex:158`

The dashboard layout guarded the `phoenix_kit_consent.js` script tag with `Code.ensure_loaded?` (line 158), but never rendered the cookie consent widget component. Both `root.html.heex` and `layout_wrapper.ex` correctly render the widget after loading the JS. The dashboard layout is a standalone layout (own `<html>`/`<body>` tags), not nested inside root or layout_wrapper, so users on `/dashboard/*` pages would never see the consent banner.

**Fix applied**: Added the cookie consent widget block before `</body>` in `dashboard.html.heex`, matching the exact pattern used in `root.html.heex` (lines 182-195).

#### 3. (INFO) Three concerns in one PR

This PR bundles three logically separate changes:
- Legal module extraction (the main work)
- LayoutWrapper duplicate removal (a rendering bug fix)
- Billing profile routes (a new feature)

The LayoutWrapper fix was likely discovered during testing of the Legal extraction. The billing routes are small. Neither introduces risk, but for future reference, separating these would make the git history more navigable.

---

## Comparison with PR #453

PR #453 started the extraction journey (billing + shop + legal consent fixes, 197 files, net -42,227 lines). This PR #458 completes it for Legal specifically:

| Aspect | PR #453 | PR #458 |
|--------|---------|---------|
| Scope | Billing + Shop + Legal fixes + languages | Legal extraction only + LayoutWrapper fix |
| Size | 197 files, -42k lines | 45 files, -5.7k lines |
| Guard pattern | Established `Code.ensure_loaded?` | Extended to all Legal integration points |
| Issues found | 5 fixed, 4 deferred | 2 low-severity notes |

The deferred issues from PR #453 review (JS i18n, event listener accumulation, duplicate `.pk-glass` CSS) are now the responsibility of the `phoenix_kit_legal` package, since all affected files were moved there.

---

## Summary

| # | Item | Severity | Status |
|---|------|----------|--------|
| 1 | Controller namespace contract with package | Low | Noted |
| 2 | Dashboard missing consent widget | Low | **FIXED** |
| 3 | Three concerns bundled in one PR | Info | Noted |

**1 of 3 issues fixed.** The extraction is clean, guards are consistent, and the LayoutWrapper fix resolves a real visual bug. The PR correctly completes the Legal module extraction started in #453.

## Files Changed Summary

| Category | Files | Lines |
|----------|-------|-------|
| Legal module deleted | 12 files | -2,603 |
| Legal templates deleted | 7 `.eex` files | -6,850 |
| Consent JS deleted | 1 file | -703 |
| Core guard modifications | 8 files | +55 |
| LayoutWrapper removals | 17 templates + 1 module | +4,329 / -552 (reformatting) |
| Billing routes | 1 file | +12 |
| Dialyzer config | 1 file | +3 / -7 |
