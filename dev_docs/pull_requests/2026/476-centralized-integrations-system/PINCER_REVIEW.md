# PR #476 Review — Add centralized Integrations system

**Reviewer:** Pincer 🦀
**Date:** 2026-04-06
**Verdict:** Approve with Follow-ups

---

## Summary

Adds a centralized Integrations system to phoenix_kit core for managing external service connections (OAuth 2.0, API keys, bot tokens, key pairs, custom credentials). Reuses the existing `phoenix_kit_settings` table with JSONB storage under `integration:{provider}:{name}` keys.

**Scale:** 72 files, ~9300 lines added. Note: this PR also bundled unrelated changes (LLM text module, user invitations, organization settings refactor, nav tabs component).

### New components:
- `PhoenixKit.Integrations` — Core context (CRUD, OAuth flow, auto-refresh)
- `PhoenixKit.Integrations.Providers` — Provider registry (Google, OpenRouter built-in, extensible)
- `PhoenixKit.Integrations.OAuth` — Generic OAuth 2.0 implementation
- `PhoenixKit.Integrations.Events` — PubSub for real-time UI updates
- `PhoenixKit.Module` — Two new callbacks: `required_integrations/0`, `integration_providers/0`
- Admin settings LiveViews (list + form)
- `IntegrationPicker` reusable component
- Legacy migration from `document_creator_google_oauth`

---

## What Works Well

1. **Storage design** — Reusing `phoenix_kit_settings` with JSONB is smart. No migration needed, consistent with the rest of PhoenixKit.
2. **Multi-connection support** — Named connections (`google:default`, `google:work`) allow multiple accounts per provider. Good forward-thinking.
3. **Auto-refresh on 401** — `authenticated_request/4` transparently refreshes expired OAuth tokens. Nice DX for consuming modules.
4. **Extensibility** — Module callbacks let external packages declare integration needs and contribute providers without touching core.
5. **Legacy migration** — Automatic one-time migration from old `document_creator_google_oauth` key. Non-breaking.
6. **UUID lookups** — Connections can be referenced by settings row UUID, stable across key changes.
7. **Provider instructions** — Step-by-step setup guides for Google and OpenRouter. Great UX.

---

## Issues Found

### 1. BUG — HIGH: Password fields silently overwritten
**File:** `lib/phoenix_kit_web/live/settings/integration_form.ex:432`

When editing an existing integration, if the admin doesn't re-enter password fields, they're overwritten with `""`. The comment says "skip empty values" but the implementation doesn't filter them. This will wipe `client_secret` and `api_key`.

### 2. BUG — LOW: Duplicate line
**File:** `lib/phoenix_kit/integrations/integrations.ex:525-526`

```elixir
|> maybe_put("external_account_name", userinfo["name"])
|> maybe_put("external_account_name", userinfo["name"])  # duplicate
```

### 3. DESIGN — HIGH: Legacy migration in hot path
**File:** `lib/phoenix_kit/integrations/integrations.ex`

`maybe_migrate_legacy/1` runs on every `get_integration/1` call when data is not found. It also hardcodes `document_creator`'s internal settings keys (`"document_creator_google_oauth"`, `"document_creator_folders"`). This should be a one-time migration task, not permanently in the hot path.

### 4. SECURITY: No encryption at rest
OAuth tokens, API keys, and client secrets stored as plain JSONB. Acknowledged as future work — needs a tracking issue.

### 5. SECURITY: Missing OAuth `state` parameter
**File:** `lib/phoenix_kit/integrations/oauth.ex`

No CSRF protection via `state` parameter in the OAuth flow. Standard security best practice.

### 6. DESIGN — MEDIUM: Dead code
**File:** `lib/phoenix_kit_web/live/settings/integration_form.ex`

`has_setup_credentials?/2` is defined but never called.

### 7. DESIGN — MEDIUM: Validation logic duplicated
Validation logic duplicated between the two LiveViews (`integrations.ex` and `integration_form.ex`). Should live in the `Integrations` context.

---

## Aggregated Findings (3 Reviewers)

| Issue | Pincer | Claude | Kimi |
|-------|--------|--------|------|
| Password field overwrite bug | ✅ | ✅ | — |
| Duplicate line in maybe_set_userinfo | ✅ | ✅ | ✅ |
| Legacy migration in hot path | ✅ | ✅ | — |
| No encryption at rest | ✅ | ✅ | ✅ |
| Missing OAuth state parameter | ✅ | — | ✅ |
| Dead code (has_setup_credentials?) | ✅ | — | ✅ |
| Validation logic duplication | ✅ | ✅ | — |
| No proactive token expiration check | — | — | ✅ |
| No rate limiting on validation | — | — | ✅ |
| Telegram URL hardcoded | — | ✅ | ✅ |

---

## Recommendations

**Must fix (post-merge):**
1. ~~Fix password field overwrite bug — credentials will be wiped on edit~~ ✅ **Fixed** — empty password fields now skipped in `save_setup_fields`
2. ~~Remove duplicate line in `maybe_set_userinfo/2`~~ ✅ **Fixed**

**Should fix:**
3. Move legacy migration to a one-time task
4. Add OAuth `state` parameter for CSRF protection
5. ~~Remove dead code~~ ❌ **Not dead** — `has_setup_credentials?/2` is used in the HEEx template. Reviewers were wrong.
6. Create tracking issue for encryption at rest

**Nice to have:**
7. Extract validation logic to context module
8. Add proactive `expires_at` check before requests

---

## Post-Review Changes (2026-04-06)

- Fixed password overwrite bug in `integration_form.ex` — password fields now preserve existing values when left empty
- Removed duplicate `external_account_name` line in `integrations.ex`
- Removed pre-existing TODO tag in `table_row_menu.ex` to clear credo --strict
- Added dialyzer ignores for false positives in integration LiveViews
