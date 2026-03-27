# PR #453: Fix cookie consent, extract billing/shop modules - Review

**Author**: @timujinne
**Reviewer**: Claude (Anthropic)
**Status**: Merged
**Date**: 2026-03-27
**Stats**: 197 files changed, +26,444 / -68,671 (net -42,227 lines)

## Overview

Massive PR combining four concerns: cookie consent UX fixes, billing module extraction to `phoenix_kit_billing`, shop module extraction to `phoenix_kit_ecommerce`, and language additions. Also includes upstream merge resolution (11 conflicts).

## Credo Analysis

`mix credo --strict` passes with **zero issues** across 483 source files.

---

## Issues Found and Fixed

### 1. FIXED (CRITICAL): Unguarded `Shop.Cart` reference in user deletion

**File**: `lib/phoenix_kit/users/auth.ex:2324-2327`

`delete_user_shop_carts/1` referenced `PhoenixKit.Modules.Shop.Cart` directly without a `Code.ensure_loaded?` guard, but Shop has been extracted to an external package. The sibling function `delete_user_billing_profiles/1` (line 2315) correctly uses the guard pattern.

**Impact**: User deletion (`delete_cascade_data/1`, line 2299) would crash at runtime for any installation without `phoenix_kit_ecommerce`.

**Fix applied**: Wrapped the query in `if Code.ensure_loaded?(PhoenixKit.Modules.Shop.Cart)` to match the Billing guard pattern.

### 2. FIXED (HIGH): Missing attributes in `root.html.heex` cookie consent call

**File**: `lib/phoenix_kit_web/components/layouts/root.html.heex:179-191`

Cookie consent component call was missing `legal_links` and `legal_index_url` attributes that were added to the component. `layout_wrapper.ex` (lines 690-707) correctly passes them, but `root.html.heex` did not.

**Impact**: Non-LiveView pages got default fallback values instead of dynamic legal links.

**Fix applied**: Added `legal_links={config.legal_links}` and `legal_index_url={config.legal_index_url}` to the component call.

### 3. FIXED (MEDIUM): Glass opacity mismatch between Elixir component and JavaScript

**Files**:
- `lib/phoenix_kit_web/components/core/cookie_consent.ex:183` - `oklch(var(--b1) / 0.98)`
- `priv/static/assets/phoenix_kit_consent.js:316` - was `oklch(var(--b1)/0.95)`

**Also fixed**: Modal backdrop colors diverged. Elixir component used `bg-base-100/70` (`--b1` at 70%), JS used `oklch(var(--bc)/0.4)` (`--bc` is text color, wrong base). Synced JS to use `--b1` at 70% to match Elixir.

**Fix applied**: Updated JS `.pk-glass` opacity from 0.95 to 0.98, and backdrop from `oklch(var(--bc)/0.4)` to `oklch(var(--b1)/0.7)`.

### 4. FIXED (MEDIUM): `legal_links` attribute declared but never rendered

**File**: `lib/phoenix_kit_web/components/core/cookie_consent.ex:79-81`

The `legal_links` attribute was defined with documentation and passed from `LayoutWrapper.ex`, but the component template never iterated over or rendered the links. The modal footer only showed a single static "Legal" link.

**Fix applied**: Added `:for` iteration over `@legal_links` in the modal footer, rendering each published legal page as a separate link with separator.

### 5. FIXED (MEDIUM): Variable name `@top_10_languages` was stale

**File**: `lib/modules/languages/languages.ex:123`

The list contained **13 languages** after adding Estonian, but variable was still called `@top_10_languages`. Comments at lines 428, 449 said "top 12".

**Fix applied**: Renamed `@top_10_languages` to `@default_languages`, updated all references (3 total) and all stale comments/docs.

---

## Remaining Issues (Not Fixed)

### 6. Non-translatable strings in JavaScript consent widget

**File**: `priv/static/assets/phoenix_kit_consent.js` (lines 346-415)

All UI text in the auto-injected JavaScript widget is hardcoded in English: "We value your privacy", "Accept All", "Reject", category names, descriptions. The Elixir component correctly uses `gettext()` for i18n. The JS-injected variant has no multi-language support.

**Why not fixed**: This is a design decision requiring a config-driven approach (pass translated strings via data attributes or API). Out of scope for a post-merge cleanup.

### 7. Charlist workaround in CountryData may be too broad

**File**: `lib/phoenix_kit/utils/country_data.ex:596`

```elixir
defp charlist_single_digit?([n]) when is_integer(n) and n >= 0 and n <= 127, do: true
```

Matches any single-element list with integer 0-127, which could incorrectly identify legitimate single-rate VAT lists (e.g., `[5]` for 5% VAT) as YAML-parser charlists. The workaround handles a real upstream bug but detection could be more precise.

**Why not fixed**: Requires understanding the upstream YAML parser behavior and testing against real country data. Best addressed when upstream `BeamLabCountries` fixes the charlist issue.

### 8. Double event listener accumulation in JS

**File**: `priv/static/assets/phoenix_kit_consent.js:677-680`

Escape key handler added globally on every initialization without cleanup in `destroyed` hook. Multiple initializations accumulate listeners.

**Why not fixed**: Edge case requiring JS refactor. Low impact since the widget typically initializes once per page load.

### 9. `.pk-glass` CSS defined in two places

Both the Elixir component (line 182-188) and JavaScript file (line 316) define `.pk-glass`. Now synced to same values (0.98 opacity) but still a maintenance burden.

**Why not fixed**: The duplication is architectural - the JS file must be self-contained for the auto-inject use case (no server-rendered component). A shared CSS file approach would require build pipeline changes.

---

## What's Done Well

- **`safe_route_call/3` implementation** (`integration.ex:883-901`): Correctly uses `Code.ensure_compiled/1` for compile-time macro context, properly checks `function_exported?/3`, handles all error cases gracefully.
- **`Code.ensure_loaded?` guards** are consistently applied across `integration.ex` for Shop pipeline and route generation (lines 178, 332, 540, 576, 993, 1046).
- **CountryData utility** (`utils/country_data.ex`): Well-documented, comprehensive guard clauses, proper nil handling, good separation of IBAN/SWIFT validation.
- **Chinese language code fix** (`zh-CN` to `zh`): Correct alignment with ISO 639-1.
- **Module registry cleanup**: Billing and Shop properly removed from `internal_modules`.
- **Dialyzer ignores** are targeted and correct for the extraction scenario.
- **daisyUI toggle replacement** in cookie consent: Reduces 26 lines of custom CSS to native component.
- **Dynamic legal links infrastructure** in `Legal.get_consent_widget_config()`: Clean implementation using `Routes.path()` to prevent double-slash bugs.

## Scope Concern

This PR bundles four distinct concerns (cookie consent UX, billing extraction, shop extraction, language changes) into 197 changed files. While the changes are individually clean, the size makes review difficult and increases merge risk. Future extractions would benefit from being separate PRs.

---

## Summary

| # | Issue | Severity | Status |
|---|-------|----------|--------|
| 1 | Unguarded `Shop.Cart` in user deletion | **CRITICAL** | FIXED |
| 2 | Missing attrs in `root.html.heex` consent | **HIGH** | FIXED |
| 3 | Glass opacity mismatch (Elixir vs JS) | Medium | FIXED |
| 4 | `legal_links` attr declared but unused | Medium | FIXED |
| 5 | `@top_10_languages` name stale (now 13) | Medium | FIXED |
| 6 | JS widget not translatable | Medium | Deferred |
| 7 | Charlist detection too broad | Low | Deferred |
| 8 | JS event listener accumulation | Low | Deferred |
| 9 | Duplicate `.pk-glass` CSS definitions | Low | Noted |

**5 of 9 issues fixed. 4 deferred with rationale.**

## Files Changed in Post-Review Fixes

| File | Change |
|------|--------|
| `lib/phoenix_kit/users/auth.ex` | Added `Code.ensure_loaded?` guard to `delete_user_shop_carts/1` |
| `lib/phoenix_kit_web/components/layouts/root.html.heex` | Added `legal_links` and `legal_index_url` attrs to consent component |
| `lib/phoenix_kit_web/components/core/cookie_consent.ex` | Render `legal_links` in modal footer with separator styling |
| `lib/modules/languages/languages.ex` | Rename `@top_10_languages` to `@default_languages`, update docs |
| `priv/static/assets/phoenix_kit_consent.js` | Sync glass opacity to 0.98, fix backdrop to use `--b1` at 70% |
