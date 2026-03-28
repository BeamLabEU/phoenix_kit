# PR #458 Review: Remove Legal module from core (extracted to phoenix_kit_legal)

**Reviewer**: ZAI
**Date**: 2026-03-28
**PR**: https://github.com/BeamLabEU/phoenix_kit/pull/458
**Branch**: `legal-cookie-consent-fix` -> `dev`
**Author**: @timujinne
**Stats**: 45 files, +4,384 / -10,156 (net -5,772 lines)

---

## Summary

Extracts the Legal module (cookie consent, legal page templates, consent logging) from PhoenixKit core into a standalone `phoenix_kit_legal` package. Also fixes duplicate LayoutWrapper in admin templates and adds conditional billing profile routes.

---

## Commits

| Hash | Description | Scope |
|------|-------------|-------|
| `4ba7386` | Remove LayoutWrapper from 16 admin .heex + 1 .ex | Bug fix |
| `95670f1` | Add billing profile dashboard routes (guarded) | Feature |
| `1147313` | Delete Legal module from core, add guards | Extraction |
| `cb8028e` | Fix 4 remaining storage/maintenance templates | Bug fix (follow-up) |
| `bebc2d17` | Merge upstream/dev (resolve delete conflicts) | Integration |

---

## Architecture Review

### Extraction approach

The extraction follows PhoenixKit's established pattern for optional packages:

1. Delete module files from core
2. Add `Code.ensure_loaded?` guards at all integration points
3. Add `@compile {:no_warn_undefined}` to suppress compiler warnings
4. Update `.dialyzer_ignore.exs` with targeted entries

This is the correct pattern for a library that must compile with or without the optional dependency. The namespace `PhoenixKit.Modules.Legal.*` is preserved in the external package, which means the `Code.ensure_loaded?` guards will seamlessly detect it.

### Guard locations (7 total)

| File | Guard purpose |
|------|---------------|
| `integration.ex:266` | `/api/consent-config` route |
| `integration.ex:443` | `/admin/settings/legal` LiveView route |
| `layout_wrapper.ex:685` | Consent JS script tag (admin-only layout) |
| `layout_wrapper.ex:698` | Cookie consent widget component (admin-only layout) |
| `root.html.heex:55` | Consent JS script tag (public layout) |
| `root.html.heex:182` | Cookie consent widget component (public layout) |
| `dashboard.html.heex:158` | Consent JS script tag (user dashboard) |

The double-guard pattern (`ensure_loaded? AND consent_widget_enabled?()`) at widget render sites is correct: the first check prevents compilation errors, the second gates on runtime configuration.

---

## Issues Found

### 1. (MEDIUM) Cookie consent widget missing from dashboard layout

**File**: `lib/phoenix_kit_web/components/layouts/dashboard.html.heex`

The dashboard layout loads `phoenix_kit_consent.js` at line 158 but never renders the `<PhoenixKit.Modules.Legal.CookieConsent.cookie_consent>` component. Both `root.html.heex` (lines 182-195) and `layout_wrapper.ex` (lines 698-711) correctly render the widget after loading the JS. Since `dashboard.html.heex` is a standalone HTML document (has its own `<html>`/`<body>` tags), users on `/dashboard/*` pages would get the JS loaded but never see a consent banner.

**Recommendation**: Add the consent widget block before `</body>` in `dashboard.html.heex`, matching the pattern in `root.html.heex`.

### 2. (LOW) Inconsistent cookie consent attribute order

**Files**: `layout_wrapper.ex` vs `root.html.heex` vs `dashboard.html.heex`

The cookie consent component call has different attribute ordering across files:

- `layout_wrapper.ex:701-710`: `google_consent_mode` is last
- `root.html.heex:185-195`: `google_consent_mode` is after `privacy_policy_url`
- (If added to dashboard.html.heex, it should follow one pattern)

This is cosmetic but makes it harder to verify all three sites pass the same config. Consider extracting a shared helper or establishing a canonical attribute order.

### 3. (LOW) `ConsentConfigController` namespace coupling

**File**: `integration.ex:11`, `integration.ex:267`

The `@compile {:no_warn_undefined}` list includes `PhoenixKitWeb.Controllers.ConsentConfigController`, and the route at line 267 is guarded by `Code.ensure_loaded?(PhoenixKit.Modules.Legal)`. However, the guard checks the Legal *module*, while the route calls the *controller* under `PhoenixKitWeb.Controllers.*` namespace. If the `phoenix_kit_legal` package provides the controller under a different namespace, the route would match but 404 at runtime.

**Recommendation**: Either guard on `ConsentConfigController` directly (`Code.ensure_loaded?(PhoenixKitWeb.Controllers.ConsentConfigController)`), or document the namespace contract with the external package.

### 4. (LOW) Stale reference in `auth.ex` @compile directive

**File**: `lib/phoenix_kit_web/users/auth.ex:3`

```elixir
@compile {:no_warn_undefined,
          [PhoenixKit.Modules.Shop, PhoenixKitWeb.Live.Modules.Legal.Settings]}
```

`PhoenixKitWeb.Live.Modules.Legal.Settings` is still listed here even though the Legal admin settings LiveView was removed from core in this PR. The `@compile` directive suppresses warnings for a module that no longer exists in core. If the external `phoenix_kit_legal` package provides it under the same namespace, this is harmless. But it's an implicit dependency that should be documented.

### 5. (INFO) Three concerns in one PR

This PR bundles:
1. Legal module extraction (main work, ~3,500 net lines removed)
2. LayoutWrapper duplicate removal (bug fix, ~20 templates changed)
3. Billing profile user routes (new feature, 1 file, ~30 lines)

The LayoutWrapper fix was likely discovered during extraction testing. The billing routes are small. Neither is risky, but separating them would make bisecting and reverts cleaner.

### 6. (INFO) LayoutWrapper removal: reformatting noise

The LayoutWrapper removal commits show large diffs because the inner content was re-indented after removing the wrapper. The actual change is just removing the opening/closing `<PhoenixKitWeb.Components.LayoutWrapper.app_layout ...>` tags, but the diff shows every line changed due to indentation shifts. This is unavoidable with HEEX templates but makes the commit harder to review.

---

## Positive Observations

1. **Clean guard consistency**: All 7 `Code.ensure_loaded?` sites follow the same pattern. The double-check (`ensure_loaded? AND runtime_check`) for the consent widget is correct.

2. **Namespace preservation**: The external package keeps `PhoenixKit.Modules.Legal.*`, so no import/alias changes needed in core. The guards just work when the package is installed.

3. **Dialyzer improvements**: Switched from broad regex patterns to targeted `{file, :unknown_function}` tuples. This won't accidentally suppress real future warnings.

4. **Thorough LayoutWrapper fix**: The follow-up commit (`cb8028e`) catching 4 missed templates shows proper review of the initial cleanup.

5. **Billing route pattern**: Follows the established `Code.ensure_loaded?` pattern used for Shop routes, maintaining consistency.

6. **No orphaned imports**: `CookieConsent` import removed from `phoenix_kit_web.ex`, Legal removed from `module_registry.ex` internal_modules, consent.js removed from `assets_controller.ex` static map. Clean extraction.

---

## Summary

| # | Issue | Severity | Status |
|---|-------|----------|--------|
| 1 | Dashboard layout missing consent widget | Medium | Needs fix |
| 2 | Inconsistent consent component attribute order | Low | Cosmetic |
| 3 | Guard checks Legal module, route calls different controller | Low | Verify package contract |
| 4 | Stale `@compile` reference in auth.ex | Low | Document or remove |
| 5 | Three concerns in one PR | Info | Noted |
| 6 | Reformatting noise in LayoutWrapper removal | Info | Unavoidable |

**Overall**: The extraction is well-executed. The guard pattern is consistent and the cleanup is thorough. The main actionable item is issue #1 (dashboard consent widget) — it's a functional gap where users on `/dashboard/*` pages won't see the consent banner even with the Legal package installed.
