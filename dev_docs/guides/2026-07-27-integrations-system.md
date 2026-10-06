# Integrations System

Moved from `AGENTS.md` 2026-07-27 — a short operational summary stayed
there; this is the full reference. Design doc:
`dev_docs/plans/integrations-system.md`.

Centralized OAuth / API key / bot token / credential management.

**Files:**
- `lib/phoenix_kit/integrations/integrations.ex` — main context (CRUD, OAuth, validation)
- `lib/phoenix_kit/integrations/providers.ex` — provider registry (Google, OpenRouter built-in)
- `lib/phoenix_kit/integrations/oauth.ex` — generic OAuth 2.0 with CSRF state
- `lib/phoenix_kit/integrations/events.ex` — PubSub events (owner-routed)
- `lib/phoenix_kit/integrations/telegram.ex` — Telegram bot client (send + one-shot getUpdates)
- `lib/phoenix_kit_web/live/settings/integrations.ex` + `integration_form.ex` — website-wide (system) UI
- `lib/phoenix_kit_web/live/integrations/my_integrations.ex` + `my_integration_form.ex` — personal (per-user) UI
- `lib/phoenix_kit_web/components/core/integration_picker.ex` — reusable picker
- `lib/phoenix_kit_web/components/core/integrations_ui.ex` — shared setup UI (picker / status card / field / instructions)

**Storage:** `phoenix_kit_settings` JSONB. Keys: `integration:{provider}:{name}` (e.g. `integration:google:default`). **Consumers reference connections by storage row uuid** — stable across renames.

**Auth types:** `:oauth2`, `:api_key`, `:key_secret`, `:bot_token`, `:credentials`.

**Named connections:** Multiple per provider. `add_connection/3`, `remove_connection/2`, `rename_connection/3`, `list_connections/1`. `"default"` is not privileged. Names match `[a-zA-Z0-9][a-zA-Z0-9\-_]*`.

**API shape (uuid-strict).** Storage-key construction (`"integration:{provider}:{name}"`) happens only in `add_connection/3` and module `migrate_legacy/0` migrators. All other public API takes a uuid:

- Mutating: `save_setup`, `disconnect`, `remove_connection`, `rename_connection`, `record_validation` — all `(uuid, ...)`
- OAuth: `authorization_url`, `exchange_code`, `refresh_access_token` — all `(uuid, ...)`
- HTTP: `authenticated_request(uuid, ...)`, `validate_connection(uuid, actor)`
- Read shims (uuid OR `provider:name` string): `get_integration/1`, `get_credentials/1`, `connected?/1`
- Migration primitive: `find_uuid_by_provider_name/1`

A corrupted JSONB `provider`/`name` cannot leak into a new key — no public write API derives keys from JSONB.

**Consumer pattern:** modules store the uuid on their own records (`phoenix_kit_ai_endpoints.integration_uuid`, `document_creator_settings.google_connection`). Lookups via `get_integration_by_uuid/1` or `get_credentials/1`. The system does **not** silently fall back to "any connected row of this provider" — consumers specify which.

**Validation:** `validate_connection/2` calls userinfo (OAuth) or validation endpoint (api_key/bot_token). Success flips `status` → `"connected"` and rewrites `connected_at`. `last_validated_at` is rewritten on every attempt.

**Events (PubSub):** topic `"phoenix_kit:integrations"`. Events: `integration_setup_saved`, `integration_connected`, `integration_disconnected`, `integration_validated`, `integration_connection_added/removed/renamed`.

**Module callbacks:** `required_integrations/0` (declare needed providers), `integration_providers/0` (contribute custom providers).

**Legacy migration:** modules implement optional `migrate_legacy/0` on `PhoenixKit.Module`. `PhoenixKit.boot/1` (piped from the host's `Application.start/2`) calls `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`; a host may also call it directly. Idempotent per module; errors are caught and logged. It does nothing with `update_mode` on (`mix phoenix_kit.update` / `doctor`), where settings reads answer nil. The pre-uuid `Integrations.run_legacy_migrations/0` is now a deprecated shim.

## Owner scopes: website-wide + personal (per-user)

Connections carry an **owner** — `:system | :any | {type, id}` (typed owners:
`{:user, uuid}`, `{:dashboard, uuid}`, …) — stored in the **existing JSONB** as
`owner_type` + `owner_uuid` (**no column, no migration**; owner-less / pre-typed
rows read as `:user`). Two independent admin surfaces share the storage + the
`integrations_ui.ex` markup:

- **Personal** (`/profile/settings/integrations`, `Live.Integrations.MyIntegrations`
  / `MyIntegrationForm`) — owner `{:user, current_uuid}`, gated by the
  `integrations` permission key, checked by each LiveView in `mount/3` (no
  admin gate). The owner uuid comes ONLY from the request scope, never params;
  every context call passes `owner:` explicitly (a forgotten owner on
  `add_connection` would silently birth a SYSTEM row).
- **Website-wide** (`/admin/settings/integrations`,
  `Live.Settings.Integrations` / `IntegrationForm`) — owner `:system`, gated by
  `integrations_system`.

Owner threading in `integrations.ex`: reads/mutations take an `:owner` opt,
**default `:system`** (fail-safe — a personal row never leaks into a system
workflow). `resolve_uuid/2` enforces owner on every uuid-strict mutation;
`get_integration_by_uuid/2` is owner-scoped on the form edit-load path and fails
closed on mismatch (never puts cross-owner decrypted creds in assigns).
`owner_uuid` is **write-once** — set at birth by `add_connection`, preserved by
`save_setup`/`disconnect`, and dropped from incoming attrs. SQL filter:
`->>'owner_uuid' IS NULL` (system) / `= ?` + `COALESCE(->>'owner_type','user') = ?`
(typed). **Do NOT encrypt `owner_uuid`** — the `->>` filter needs it plaintext.

**Provider `scopes`** (`providers.ex`, `Providers.scopes_of/1` / `for_scope/1`):
`[:system]` (default) / `[:personal]` / `[:system, :personal]`. Self-owned-secret
providers (api_key / smtp / ses) are personal-capable; OAuth2 (Google/Microsoft)
are `[:system]`-only. `add_connection` enforces the requested scope, so a crafted
event can't birth a personal Google row. Personal picker uses `personal_offered/0`.

**Events are owner-routed:** `Events.subscribe/1` + `topic_for_user/1` give a
per-user topic (personal LV subscribes to its own; system LV keeps `subscribe/0`).
Broadcast payloads carry only `uuid`/`provider`/`status` — never decrypted creds
(`@sensitive_fields` redaction, which includes `oauth_state`).
