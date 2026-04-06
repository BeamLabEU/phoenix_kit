# PR #476 — Review Follow-up

**Date:** 2026-04-06
**Scope:** Fixes for issues identified in CLAUDE_REVIEW, KIMI_REVIEW, MISTRAL_REVIEW, PINCER_REVIEW, and a comprehensive 7-area deep-dive audit (documentation, security, error handling, translations, tests, code organization, database).

---

## Pass 1 — PR Review Fixes

### BUG: `disconnect/1` inconsistent for `key_secret` (Claude review)
`key_secret` disconnect was keeping credentials. Fixed to remove them like `api_key`/`bot_token`.

### BUG: `connected?/1` redundant DB calls (Claude review)
Simplified to delegate to `get_credentials/1` which already handles the fallback.

### BUG: `save_and_redirect` not skipping empty password fields (Claude review)
Fixed to skip empty password fields to preserve existing credentials.

### DESIGN: Validation logic duplicated across LiveViews (Claude + Pincer)
Consolidated into `Integrations.validate_connection/1`. Hardcoded Telegram URL removed — bot token providers now use provider-configurable `:validation` endpoint.

### SECURITY: XSS via `render_markdown_inline` with `raw()` (Claude review)
Variable values now HTML-escaped via `Phoenix.HTML.html_escape/1` before substitution.

### SECURITY: Missing OAuth `state` parameter (Kimi + Pincer)
Added CSRF protection: `OAuth.generate_state/0` generates token, stored before redirect, verified on callback.

### QUALITY: `build_redirect_uri` silent localhost fallback (Claude review)
Added `Logger.warning` when `site_url` is missing.

---

## Pass 2 — Deep-Dive Audit Fixes

### ERROR HANDLING: HTTP timeouts added
**Files:** `oauth.ex`, `integrations.ex`

All HTTP calls (`Req.get`, `Req.post`, `Req.request`) now have `receive_timeout: 15_000` to prevent hanging LiveView handlers on slow/unresponsive external APIs.

### ERROR HANDLING: OAuth error params handled
**File:** `integration_form.ex`

When user denies OAuth permission, the provider returns `?error=access_denied` — now handled with a user-friendly flash message instead of silently ignoring.

### ERROR HANDLING: Refresh token rotation preserved
**File:** `oauth.ex`

`refresh_access_token/2` now captures a new `refresh_token` from the response body if the provider rotates tokens. Previously, rotated refresh tokens were silently lost.

### ERROR HANDLING: Catch-all `handle_info` added
**Files:** `integrations.ex` (list page), `integration_form.ex`

Both LiveViews now have `def handle_info(_msg, socket), do: {:noreply, socket}` to prevent crashes from unexpected PubSub messages.

### ERROR HANDLING: `apply_action` catch-all for `:edit`
**File:** `integration_form.ex`

Missing `provider`/`name` URL params no longer crash the LiveView — redirects to list page with error flash.

### ERROR HANDLING: `build_redirect_uri` guards non-string `site_url`
**File:** `integration_form.ex`

Added `is_binary(base)` guard to prevent crash if `site_url` setting is corrupted.

### TRANSLATIONS: Validation errors wrapped in gettext
**File:** `integrations.ex`

Added `use Gettext, backend: PhoenixKitWeb.Gettext` and wrapped all user-visible validation error messages in `gettext()`.

### TRANSLATIONS: Hardcoded "Google" in template made dynamic
**File:** `integration_form.html.heex`

Changed `"Connect Google Account"` → `gettext("Connect %{provider} Account", provider: @provider.name)` and similar for the description text.

### CODE QUALITY: Duplicate code in `save_and_redirect` extracted
**File:** `integration_form.ex`

`save_and_redirect/4` and `save_setup_fields/4` shared 90% identical code. Extracted `extract_setup_attrs/2` helper. Also fixed `save_and_redirect` silently ignoring save errors — now shows error flash.

### SECURITY: Connection name validation
**File:** `integrations.ex`

`add_connection/2` now validates names against `^[a-zA-Z0-9][a-zA-Z0-9\-_]*$`. Returns `{:error, :invalid_name}` for names with special characters.

### DOCUMENTATION: AGENTS.md integrations section updated
**File:** `CLAUDE.md` (symlinked from AGENTS.md)

Added: auth types, named connections (with validation pattern), validation API, events (topic + all 6 event types), legacy migration, picker component.

---

## Test Updates (cumulative)

### Pass 1
- Updated `disconnect/1 key_secret` test (credentials removed, not preserved)
- Added `validate_connection/1` tests (unconfigured, unknown provider, missing access token)
- Added `connected?/1` simplified behavior tests
- Added `OAuth.generate_state/0` tests (non-empty, uniqueness)
- Added `authorization_url/5` state parameter tests

### Pass 2
- Added Events module tests (7 tests: subscribe + all 6 broadcast types)
- Added `OAuth.exchange_code/4` validation tests (missing client_id, missing secret, empty credentials)
- Added `OAuth.refresh_access_token/2` validation tests (missing refresh_token, empty, missing client credentials)
- Added connection name validation tests (special chars rejected, hyphens/underscores accepted)

**Test count:** 299 unit tests, 0 failures (up from 279)

---

## Pass 3 — Future Work Items (all completed)

### SECURITY: Encrypt credentials at rest ✅
**File:** `lib/phoenix_kit/integrations/encryption.ex` (new)

Created `PhoenixKit.Integrations.Encryption` module using AES-256-GCM via Erlang `:crypto`. Derives a dedicated 32-byte key from the app's `secret_key_base`. Encrypts on save (`save_integration`), decrypts on read (`get_integration`, `get_credentials`, `list_connections`). Backwards-compatible — plaintext data from before encryption was enabled passes through unchanged. Encrypted values use `enc:v1:` prefix to avoid double-encryption. Configurable via `config :phoenix_kit, integration_encryption_enabled: false`.

### DESIGN: Legacy migration out of hot path ✅
**File:** `lib/phoenix_kit/integrations/integrations.ex`

Removed `maybe_migrate_legacy/1` from `get_integration/1` hot path. Added public `run_legacy_migrations/0` for boot-time execution. Safe to call multiple times — skips providers that already have data under the new key format.

### PERFORMANCE: N+1 queries + prefix index ✅
**Files:** `lib/phoenix_kit/migrations/postgres/v93.ex` (new), `lib/phoenix_kit/settings/queries.ex`, `lib/phoenix_kit/settings/settings.ex`, `lib/phoenix_kit/integrations/integrations.ex`

- Added v93 migration with `text_pattern_ops` B-tree index on `phoenix_kit_settings.key` for efficient `LIKE 'prefix%'` queries
- Added `Queries.list_settings_by_key_prefixes/1` for batch loading multiple prefixes in one query
- Added `Settings.get_json_settings_by_prefixes_with_uuid/1` wrapper
- Added `Integrations.load_all_connections/1` that loads all providers' connections in a single query
- Updated `list_integrations/0` and the LiveView `load_connections/1` to use batch loading
- Page load reduced from 1 + (2 × N providers) queries to 2 queries

### TRANSLATIONS: Provider metadata ✅
**File:** `lib/phoenix_kit/integrations/providers.ex`

Added `use Gettext` and wrapped all user-visible strings in `gettext()`: provider names, descriptions, setup field labels/help/placeholders, and all setup instruction titles and steps.

### DESIGN: IntegrationPicker search ✅
**Files:** `lib/phoenix_kit_web/components/core/integration_picker.ex`, `priv/static/assets/phoenix_kit.js`

Replaced broken `phx-keyup="integration_picker_search"` server event (no parent handled it) with `IntegrationPickerSearch` JS hook for instant client-side filtering via `data-search-text` attributes. No parent handler needed.

---

### PERFORMANCE: `Providers.all/0` cached with `persistent_term` ✅
**File:** `lib/phoenix_kit/integrations/providers.ex`

Both `all/0` and `used_by_modules/0` now cache their results in `persistent_term` after the first call. Added `clear_cache/0` to invalidate when modules change at runtime.

---

## Remaining — Future Work

### TESTS: HTTP-dependent tests
**Priority:** Low — Tests audit found this.

`authenticated_request/4`, `exchange_code` HTTP flow, and `refresh_access_token` HTTP flow have no mocked HTTP tests. Would require Bypass or Req test adapter setup.
