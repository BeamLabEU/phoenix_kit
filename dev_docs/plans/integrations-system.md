# PhoenixKit Integrations System — Implementation Plan

**Created:** 2026-04-01
**Status:** Phases 1-4 implemented (2026-04-02). uuid-everywhere migration landed (2026-04-30) — see Addendum below.
**Scope:** phoenix_kit (core), phoenix_kit_document_creator, phoenix_kit_ai

---

## Addendum (2026-04-30): uuid-everywhere model

The original plan referenced connections by `provider:name` strings
(or bare provider keys with a "default" fallback). After the system
hit its first multi-account use case, the implicit-default behavior
became a source of confusion: a `default` name meant nothing to
operators but couldn't be removed or renamed; the resolver guessed
which row to use when callers passed bare provider keys; consumer
modules had no stable handle when a connection was renamed.

The follow-up landed a simpler model:

- **Names are pure user-chosen labels.** `"default"` is no longer
  privileged — it can be renamed or removed like any other name.
  `cannot_rename_default` / `cannot_remove_default` guards removed.
- **Consumers reference connections by UUID.** AI endpoints store
  `integration_uuid` (added in V107 with backfill from legacy
  `provider` strings). Document creator stores the uuid in its
  `google_connection` setting (auto-migrates legacy values on first
  read).
- **The resolver no longer guesses.** `find_first_connected/1` and
  the bare-provider→default fallback chain in `get_credentials/1`
  are deleted. Bare-provider lookups that miss return
  `:not_configured`; uuid lookups that miss return `:deleted`.
- **Renames preserve the storage row's uuid.** `rename_connection/4`
  updates the row's `key` column in place rather than copy+delete.
  Consumer references survive renames.
- **Edit URL is uuid-based** (`/admin/settings/integrations/:uuid`).
  Renaming a connection doesn't change the route.

The "Used by" column on the integrations list page was also dropped
— it was a static map of "which modules *declare* they use this
provider" (from `required_integrations/0`), not an actual usage
graph. Misleading on a freshly-created row that no module had ever
called.

Test coverage for the new shape lives in:
- `test/integration/integrations_test.exs` (rename, get_integration_by_uuid, simplified get_credentials)
- `test/integration/phoenix_kit_web/live/settings/integrations_test.exs` (LV smoke for /new, rename, list page, uuid URL)
- `test/phoenix_kit/migrations/v107_test.exs` (backfill correctness)
- `test/phoenix_kit/integrations/events_test.exs` (broadcast_connection_renamed)
- AI module: `test/phoenix_kit_ai/endpoint_test.exs`, `openrouter_client_test.exs`, `web/endpoint_form_test.exs`
- document_creator: `test/integration/active_integration_test.exs`

---

## Problem

External service connections (OAuth accounts, API keys) are currently owned by individual modules. The document creator manages its own Google OAuth flow, token storage, and refresh logic. The AI module stores API keys per-endpoint in its own DB table.

If a new module also needs Google (e.g., Google Calendar, Google Sheets), it would have to duplicate the entire OAuth flow. If a new module needs OpenRouter or another AI provider, it can't share the API key already configured in the AI module.

## Solution

A centralized **Integrations** system in phoenix_kit core that:

1. Stores service credentials (OAuth tokens, API keys) using the existing Settings system (`value_json` JSONB column)
2. Provides a shared OAuth flow (authorize, callback, token refresh) that any module can use
3. Provides an "Integrations" tab in Admin Settings where admins connect/disconnect services
4. Exposes a simple API (`PhoenixKit.Integrations`) for modules to read credentials

## Design Decision: Settings, Not a New Table

The existing `phoenix_kit_settings` table already supports this:

- **`value_json` (JSONB)** — stores any shape of credentials as a map, no size limit
- **`key` (string, unique)** — e.g., `"integration:google"`, `"integration:openrouter"`
- **`module` (string)** — tag as `"integrations"` for organization
- **Caching** — `get_json_setting_cached/2` with automatic invalidation on writes
- **Already proven** — document creator already stores OAuth tokens this way

**Why not a new table:**
- Settings already does exactly what we need (key-value JSON with caching)
- No migration needed for the storage layer
- Consistent with how the rest of PhoenixKit stores configuration
- The data shape varies wildly per provider (OAuth vs API key vs key+secret) — JSONB handles this naturally

**Key convention:** All integration settings keys are prefixed with `"integration:"` (e.g., `"integration:google"`, `"integration:openrouter"`, `"integration:stripe"`).

---

## Data Shape Per Integration

Every integration is a single JSON blob stored under a settings key. The shape varies by auth type, but all share common fields:

### Common Fields (all integrations)

```elixir
%{
  # Identity
  "provider" => "google",                          # Provider slug
  "auth_type" => "oauth2",                         # "oauth2" | "api_key" | "key_secret" | "bot_token" | "credentials"
  "label" => "Google Workspace",                   # Display name (set by admin or auto)

  # Status
  "status" => "connected",                         # "connected" | "disconnected" | "error"
  "connected_at" => "2026-03-15T10:30:00Z",        # ISO8601
  "connected_by" => "user-uuid-here",              # Admin who connected it

  # Connection identity (from the external service)
  "external_account_id" => "user@company.com",     # Email, team ID, account ID, etc.
  "external_account_name" => "Company Workspace",  # Human-readable name

  # Service-specific metadata (varies per provider)
  "metadata" => %{...}
}
```

### OAuth 2.0 Integrations (Google, Microsoft, Slack, etc.)

```elixir
%{
  # ... common fields ...
  "auth_type" => "oauth2",

  # App credentials (entered by admin in settings)
  "client_id" => "123456.apps.googleusercontent.com",
  "client_secret" => "GOCSPX-...",

  # Tokens (obtained via OAuth flow)
  "access_token" => "ya29.a0AfH6SMBx...",
  "refresh_token" => "1//0gqUP8...",
  "token_type" => "Bearer",
  "expires_at" => "2026-03-15T11:30:00Z",          # Absolute expiry (computed from expires_in)
  "token_obtained_at" => "2026-03-15T10:30:00Z",

  # Scopes
  "scopes" => "https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/documents",

  # Provider-specific metadata
  "metadata" => %{
    "connected_email" => "user@gmail.com"
  }
}
```

### API Key Integrations (OpenRouter, Stripe, SendGrid, etc.)

```elixir
%{
  # ... common fields ...
  "auth_type" => "api_key",

  # The key itself
  "api_key" => "sk-or-v1-abc123...",

  # Optional provider-specific fields
  "metadata" => %{
    "organization_id" => "org-xxx",       # OpenAI org
    "http_referer" => "https://myapp.com", # OpenRouter
    "x_title" => "My App"                  # OpenRouter
  }
}
```

### Key Pair Integrations (AWS, Twilio, etc.)

```elixir
%{
  # ... common fields ...
  "auth_type" => "key_secret",

  "access_key" => "AKIA...",
  "secret_key" => "wJalr...",

  "metadata" => %{
    "region" => "us-east-1",
    "account_id" => "123456789"
  }
}
```

### Bot Token Integrations (Telegram, Discord, etc.)

```elixir
%{
  # ... common fields ...
  "auth_type" => "bot_token",

  # The bot token
  "bot_token" => "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11",

  # Connection identity (populated after validation)
  "external_account_id" => "123456",
  "external_account_name" => "MyCompanyBot",

  "metadata" => %{
    "bot_username" => "@my_company_bot",
    "webhook_url" => "https://myapp.com/webhooks/telegram"  # if using webhooks
  }
}
```

Telegram bots authenticate with a single token from BotFather. The token never expires (unless revoked). Validation is done by calling `getMe` on the Telegram Bot API. Discord bots follow a similar pattern with a bot token.

### Custom Credentials (SMTP, databases, etc.)

```elixir
%{
  # ... common fields ...
  "auth_type" => "credentials",

  # Freeform — shape defined by the provider definition
  "credentials" => %{
    "host" => "smtp.gmail.com",
    "port" => 587,
    "username" => "noreply@company.com",
    "password" => "app-specific-password",
    "encryption" => "starttls"
  }
}
```

---

## Provider Definitions

Providers are defined in code (not DB) as a registry of known integration types. This tells the UI what fields to show and how to handle auth.

```elixir
# lib/phoenix_kit/integrations/providers.ex

# Each provider definition contains:
%{
  key: "google",
  name: "Google Workspace",
  description: "Google Docs, Drive, Calendar, Sheets, Gmail",
  icon: "hero-cloud",                    # or a custom SVG/image path
  auth_type: :oauth2,
  oauth_config: %{
    auth_url: "https://accounts.google.com/o/oauth2/v2/auth",
    token_url: "https://oauth2.googleapis.com/token",
    userinfo_url: "https://www.googleapis.com/oauth2/v2/userinfo",
    default_scopes: "https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/documents",
    auth_params: %{access_type: "offline", prompt: "consent"}
  },
  setup_fields: [
    %{key: "client_id", label: "Client ID", type: :text, required: true,
      placeholder: "xxxxx.apps.googleusercontent.com",
      help: "From Google Cloud Console → APIs & Services → Credentials"},
    %{key: "client_secret", label: "Client Secret", type: :password, required: true,
      placeholder: "GOCSPX-..."}
  ],
  # Which modules can use this integration
  capabilities: [:google_docs, :google_drive, :google_calendar, :google_sheets]
}
```

The provider registry is extensible — external modules can register additional providers via a callback in `PhoenixKit.Module`:

```elixir
# In a module like PhoenixKitDocumentCreator:
@impl PhoenixKit.Module
def integration_providers do
  [
    %{key: "google", ...}   # Can contribute provider definitions
  ]
end
```

Or more likely, core ships with common providers and modules just declare which ones they need. New providers are added to the registry as needed.

**Example bot token provider:**

```elixir
%{
  key: "telegram",
  name: "Telegram Bot",
  description: "Telegram Bot API for messaging, notifications, and commands",
  icon: "hero-chat-bubble-left-right",
  auth_type: :bot_token,
  setup_fields: [
    %{key: "bot_token", label: "Bot Token", type: :password, required: true,
      placeholder: "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11",
      help: "From @BotFather on Telegram"}
  ],
  validation: %{
    url: "https://api.telegram.org/bot{bot_token}/getMe",
    method: :get,
    success_path: ["ok"]   # check response.ok == true
  },
  capabilities: [:telegram_messaging, :telegram_webhooks]
}
```

---

## Context Module API

### `PhoenixKit.Integrations`

```elixir
# === Reading credentials (used by consuming modules) ===

# Get full integration data for a provider
get_integration("google")
# => {:ok, %{"provider" => "google", "access_token" => "ya29...", ...}}
# => {:error, :not_configured}

# Get just the credentials needed for API calls (provider-aware)
get_credentials("google")
# => {:ok, %{access_token: "ya29...", token_type: "Bearer"}}
# => {:error, :not_configured}

# Check if an integration is connected and has valid credentials
connected?("google")
# => true | false

# === OAuth flow (used by the Integrations settings UI) ===

# Build authorization URL for OAuth providers
authorization_url("google", redirect_uri)
# => {:ok, "https://accounts.google.com/o/oauth2/v2/auth?..."}

# Exchange authorization code for tokens
exchange_code("google", code, redirect_uri)
# => {:ok, %{"access_token" => ..., "refresh_token" => ...}}

# Refresh an expired access token
refresh_access_token("google")
# => {:ok, "new-access-token"}

# Disconnect (remove tokens, keep client_id/secret)
disconnect("google")
# => :ok

# === Setup (used by the Integrations settings UI) ===

# Save app-level credentials (client_id/secret for OAuth, api_key for key-based)
save_setup("google", %{"client_id" => "...", "client_secret" => "..."})
save_setup("openrouter", %{"api_key" => "sk-or-..."})

# === HTTP helper (used by consuming modules) ===

# Make an authenticated request with automatic token refresh on 401
authenticated_request("google", :get, url, opts)
# => {:ok, %Req.Response{...}}
# Automatically adds Bearer token, retries with refreshed token on 401

# === Provider registry ===

# List all known providers
list_providers()
# => [%{key: "google", name: "Google Workspace", ...}, ...]

# List all configured integrations (connected or just setup)
list_integrations()
# => [%{"provider" => "google", "status" => "connected", ...}, ...]
```

---

## Admin UI

### New Settings Tab: "Integrations"

Added as a core settings subtab in `admin_tabs.ex`, priority ~915 (after Organization, before Users or after Users):

```
Settings
├── General
├── Authorization
├── Organization
├── Users
├── Integrations    ← NEW
├── Media
├── [module tabs...]
```

### Integrations Page Layout

The page shows a card for each **known provider** (from the registry). Each card shows:

**Disconnected state:**
```
┌─────────────────────────────────────────────┐
│ 🔗 Google Workspace                         │
│ Google Docs, Drive, Calendar, Sheets, Gmail  │
│                                              │
│ Client ID:     [________________________]    │
│ Client Secret: [________________________]    │
│                                              │
│ [Save]                                       │
│                                              │
│ Status: Not connected                        │
└─────────────────────────────────────────────┘
```

**After saving client credentials:**
```
┌─────────────────────────────────────────────┐
│ 🔗 Google Workspace                         │
│                                              │
│ Client ID:     123456.apps.googleusercontent │
│ Client Secret: ••••••••••••                  │
│                                              │
│ [Connect Google Account]                     │
│                                              │
│ Status: Credentials saved, not connected     │
└─────────────────────────────────────────────┘
```

**Connected:**
```
┌─────────────────────────────────────────────┐
│ ✓ Google Workspace                          │
│ Connected as user@gmail.com                  │
│ Connected on 2026-03-15                      │
│                                              │
│ Used by: Document Creator                    │
│                                              │
│ [Disconnect]  [Reconnect]                    │
└─────────────────────────────────────────────┘
```

**API key providers (simpler):**
```
┌─────────────────────────────────────────────┐
│ 🔗 OpenRouter                               │
│ AI model access (100+ models)                │
│                                              │
│ API Key: [_______________________________]   │
│                                              │
│ [Save & Validate]                            │
│                                              │
│ Status: ✓ Connected (validated)              │
│ Used by: AI                                  │
└─────────────────────────────────────────────┘
```

### Which Providers Appear

Only providers that are **relevant** to the current installation should appear. Options:

- **Option A:** Show all providers from the registry (simple, but cluttered)
- **Option B (preferred):** Show providers that at least one enabled module declares it needs, plus any already-configured providers

Modules declare their integration needs via a new optional callback:

```elixir
@impl PhoenixKit.Module
def required_integrations, do: ["google"]   # or ["openrouter"]
```

---

## Scope of Module Changes

### Changes to `PhoenixKit.Module` Behaviour

Add two new optional callbacks (with defaults):

```elixir
@callback required_integrations() :: [String.t()]
# Which integration providers this module needs. Used to show relevant
# providers on the Integrations settings page.
# Default: []

@callback integration_providers() :: [map()]
# Additional provider definitions this module contributes.
# Most modules won't need this — core ships with common providers.
# Default: []
```

### Migration: `phoenix_kit_document_creator`

**Before:** Module manages its own Google OAuth flow in `GoogleDocsClient`, stores everything under `"document_creator_google_oauth"` settings key.

**After:** Module reads Google credentials from `PhoenixKit.Integrations.get_credentials("google")` and uses `PhoenixKit.Integrations.authenticated_request("google", ...)` for API calls.

**What moves to core:**
- OAuth authorization URL generation
- Code-to-token exchange
- Token refresh logic
- Token storage (now under `"integration:google"`)
- The settings UI for client_id/secret + connect/disconnect

**What stays in document_creator:**
- Google Docs API calls (create, copy, replace text, etc.)
- Google Drive API calls (list files, create folders, export PDF, etc.)
- Folder configuration (folder paths/names — these are document-creator-specific, stored in their own settings key)
- Variable substitution logic
- All business logic

**Specific file changes:**

1. **`google_docs_client.ex`** — Remove:
   - `@settings_key`, `settings_key/0`
   - `get_credentials/0`, `save_credentials/1`
   - `authorization_url/1`, `exchange_code/2`, `refresh_access_token/0`
   - `get_client_credentials/0`
   - `authenticated_request/3`, `retry_with_refreshed_token/3`

   Replace with calls to:
   - `PhoenixKit.Integrations.get_credentials("google")` for reading tokens
   - `PhoenixKit.Integrations.authenticated_request("google", method, url, opts)` for API calls with auto-refresh

   Keep folder config in a separate document-creator-specific settings key (e.g., `"document_creator_folders"`).

2. **`google_oauth_settings_live.ex`** — Significant simplification:
   - Remove all OAuth flow handling (connect, disconnect, credential saving)
   - The settings page becomes **folder configuration only**
   - OAuth connection moves to the core Integrations settings page
   - Could add a link/notice: "Connect your Google account in Settings → Integrations"

3. **`phoenix_kit_document_creator.ex`** — Add:
   ```elixir
   @impl PhoenixKit.Module
   def required_integrations, do: ["google"]
   ```

### Migration: `phoenix_kit_ai`

The endpoints themselves stay as-is — they define model, temperature, max_tokens, etc. What changes is where the **API key** comes from. Instead of each endpoint storing its own `api_key`, there's one OpenRouter API key configured in Settings → Integrations, and all endpoints use it.

**Approach: Remove per-endpoint API key, use shared integration**

1. **`endpoint.ex`** — Remove `api_key` field (or deprecate/ignore it):
   - Remove `field(:api_key, :string)`
   - Remove `validate_api_key_format/1` validation
   - The `provider` field stays (still useful to know which provider an endpoint targets)
   - `provider_settings` stays (http_referer, x_title are per-endpoint config, not credentials)

2. **`openrouter_client.ex`** — Update credential resolution:
   ```elixir
   # Before: build_headers_from_endpoint(%{api_key: api_key, ...})
   # After:
   def build_headers_for_provider(provider, provider_settings) do
     {:ok, %{"api_key" => api_key}} = PhoenixKit.Integrations.get_credentials(provider)
     settings = provider_settings || %{}

     opts =
       []
       |> maybe_add_opt(:http_referer, settings["http_referer"])
       |> maybe_add_opt(:x_title, settings["x_title"])

     build_headers(api_key, opts)
   end
   ```

3. **`completion.ex`** — Update `chat_completion/3` and `embeddings/3`:
   - Replace `OpenRouterClient.build_headers_from_endpoint(endpoint)` with
     `OpenRouterClient.build_headers_for_provider(endpoint.provider, endpoint.provider_settings)`

4. **`endpoint_form.ex`** — Remove the API key input field and validation UI:
   - Remove the "API Key" text input
   - Remove the "Validate API Key" button and async validation logic
   - Model fetching uses `PhoenixKit.Integrations.get_credentials("openrouter")` for the key
   - Add a notice/link: "Configure your OpenRouter API key in Settings → Integrations"
   - If no integration is connected, show a warning instead of the form

5. **`validate_api_key/1` in `openrouter_client.ex`** — Still exists but takes the key from integration:
   ```elixir
   # Used by the Integrations settings page during "Save & Validate"
   def validate_api_key(api_key) when is_binary(api_key) do
     # ... same validation logic, just called from a different place
   end
   ```

6. **`phoenix_kit_ai.ex`** — Add:
   ```elixir
   @impl PhoenixKit.Module
   def required_integrations, do: ["openrouter"]
   ```

7. **`validate_endpoint/1`** — Update to check integration instead of endpoint.api_key:
   ```elixir
   defp validate_endpoint(endpoint) do
     cond do
       endpoint.model == nil or endpoint.model == "" ->
         {:error, "Endpoint has no model configured"}
       not PhoenixKit.Integrations.connected?(endpoint.provider) ->
         {:error, "No #{endpoint.provider} integration configured"}
       endpoint.enabled == false ->
         {:error, "Endpoint is disabled"}
       true ->
         {:ok, endpoint}
     end
   end
   ```

8. **DB migration** — Remove `api_key` column from `phoenix_kit_ai_endpoints` (or leave it and stop reading it, to avoid breaking existing data). No new columns needed.

**What stays unchanged in the AI module:**
- Endpoint CRUD (create, list, update, delete)
- All generation parameters (temperature, max_tokens, top_p, etc.)
- Model selection per endpoint
- Provider settings (http_referer, x_title) per endpoint
- Request logging and usage tracking
- Prompt templates and variable substitution
- The playground, usage dashboard, and all other admin pages

---

## Implementation Order

### Phase 1: Core Foundation

1. **`lib/phoenix_kit/integrations/integrations.ex`** — Context module with Settings-backed CRUD
2. **`lib/phoenix_kit/integrations/providers.ex`** — Provider registry (start with Google + OpenRouter)
3. **`lib/phoenix_kit/integrations/oauth.ex`** — Generic OAuth 2.0 flow (authorize, exchange, refresh)
4. **Update `PhoenixKit.Module`** — Add `required_integrations/0` and `integration_providers/0` optional callbacks
5. **`lib/phoenix_kit_web/live/settings/integrations.ex`** — Admin settings LiveView
6. **Update `admin_tabs.ex`** — Register the Integrations subtab

### Phase 2: Migrate Document Creator

7. **Update `google_docs_client.ex`** — Replace OAuth/credential code with `PhoenixKit.Integrations` calls
8. **Simplify `google_oauth_settings_live.ex`** — Remove OAuth UI, keep folder config only
9. **Data migration** — Move existing `"document_creator_google_oauth"` credentials to `"integration:google"` (can be done in a mix task or on first access)
10. **Update module definition** — Add `required_integrations/0`

### Phase 3: Migrate AI Module

11. **Remove `api_key` from endpoint schema** — Stop reading it; optionally drop column in migration
12. **Update `openrouter_client.ex`** — Resolve API key from `PhoenixKit.Integrations.get_credentials("openrouter")`
13. **Update `endpoint_form.ex`** — Remove API key input, add link to Integrations settings
14. **Update `validate_endpoint/1`** — Check integration connection instead of endpoint.api_key
15. **Update module definition** — Add `required_integrations/0`

### Phase 4: Polish

16. **"Used by" tracking** — Show which modules use each integration on the settings page (computed from `required_integrations/0`, no storage needed)
17. **Connection health checks** — Periodic validation that tokens/keys still work (result stored in the integration's JSON blob as `last_validated_at` / `validation_status`)

### Phase 5: Usage Logging (Future)

18. **New table: `phoenix_kit_integration_logs`** — Track which module called which integration, when, success/failure, for audit and debugging
19. **Usage dashboard** — UI showing integration activity over time

---

## File Structure

```
lib/phoenix_kit/integrations/
├── integrations.ex          # Context module (public API)
├── providers.ex             # Provider registry & definitions
└── oauth.ex                 # Generic OAuth 2.0 flow

lib/phoenix_kit_web/live/settings/
├── integrations.ex          # LiveView for the Integrations settings tab
└── integrations.html.heex   # Template
```

---

## Settings Keys Used

| Key | Content | Module |
|-----|---------|--------|
| `"integration:google"` | OAuth creds, tokens, metadata | `"integrations"` |
| `"integration:openrouter"` | API key, metadata | `"integrations"` |
| `"integration:anthropic"` | API key, metadata | `"integrations"` |
| `"integration:openai"` | API key, metadata | `"integrations"` |
| `"integration:stripe"` | API keys (test+live), metadata | `"integrations"` |
| `"integration:aws"` | Access key + secret, region | `"integrations"` |
| etc. | | |

Old key `"document_creator_google_oauth"` is deprecated and migrated to `"integration:google"`.

---

## Security Note

Currently, **all settings (including OAuth tokens and API keys) are stored as plaintext** in the database. This is an existing condition — the document creator already stores Google OAuth tokens this way, and user-login OAuth credentials (google client_id/secret) are stored as plaintext string settings.

Adding encryption is out of scope for this plan but is a natural follow-up. The Integrations API provides a clean abstraction boundary — if encryption is added later, it only needs to change inside `PhoenixKit.Integrations` (encrypt on write, decrypt on read) without affecting any consuming modules.

---

## Research Summary

### How Integration Platforms Do It

Every major platform (n8n, Nango, Zapier) uses the **encrypted JSON blob** pattern:
- One storage record per integration, credentials as JSON
- Auth type discriminator tells the app how to interpret the blob
- Application code defines field shapes, not the DB schema
- Token refresh tracking in application layer

Our approach matches this — we just use the existing Settings table instead of a dedicated credentials table, which is appropriate for our scale (app-wide integrations, not thousands of per-user connections).

### Service Requirements That Informed the Design

From researching 17+ services:
- **OAuth tokens expire differently** (30min for HubSpot, 1hr for Google, never for Slack bots) → store `expires_at` and always handle refresh
- **Some services need a per-connection base URL** (Salesforce `instance_url`, Mailgun region) → store in `metadata`
- **Some return multiple tokens** (Slack: bot + user) → JSON blob handles arbitrary shapes
- **API key services vary** (some need org_id, some need domain, some need region) → `metadata` map
- **Setup credentials vs runtime credentials** are distinct (client_id/secret vs access_token) → both in same blob, distinguished by field names
- **GitHub Apps use JWT, not refresh tokens** → `auth_type` field allows different refresh strategies

All of these are handled by the flexible JSON blob approach without schema changes.
