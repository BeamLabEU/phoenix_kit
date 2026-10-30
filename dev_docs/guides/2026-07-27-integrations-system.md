# Integrations System

Moved from `AGENTS.md` 2026-07-27 — a short operational summary stayed
there; this is the full reference. Design doc:
`dev_docs/plans/integrations-system.md`.

Centralized OAuth / API key / bot token / credential management.

**Files:**
- `lib/phoenix_kit/integrations/integrations.ex` — main context (CRUD, OAuth, validation)
- `lib/phoenix_kit/integrations/providers.ex` — provider registry (built-ins: Google, Microsoft; the AI providers OpenAI, Anthropic, OpenRouter, Mistral, DeepSeek, xAI, Z.ai, Amazon Bedrock; ElevenLabs, AWS SES, object storage, SMTP, Brevo, Telegram, GitHub, DataForSEO, SerpApi)
- `lib/phoenix_kit/integrations/oauth.ex` — generic OAuth 2.0 with CSRF state
- `lib/phoenix_kit/integrations/events.ex` — PubSub events (owner-routed)
- `lib/phoenix_kit/integrations/telegram.ex` — Telegram bot client (send + one-shot getUpdates)
- `lib/phoenix_kit/integrations/telegram/linking.ex` + `site_bot.ex` — the website bot for user notifications: deep-link chat linking and the admin's choice of bot (one bot — one site; see the notifications guide)
- `lib/phoenix_kit_web/live/settings/integrations.ex` + `integration_form.ex` — website-wide (system) UI
- `lib/phoenix_kit_web/live/integrations/my_integrations.ex` + `my_integration_form.ex` — personal (per-user) UI
- `lib/phoenix_kit_web/components/core/integration_picker.ex` — reusable picker
- `lib/phoenix_kit_web/components/core/integrations_ui.ex` — shared setup UI (picker / status card / field / instructions)

**Storage:** `phoenix_kit_settings` JSONB. Each row key is its UUID; provider and name live in JSONB. **Consumers reference connections by storage row uuid** — stable across renames.

**Auth types:** `:oauth2`, `:api_key`, `:key_secret`, `:bot_token`, `:credentials`.

**Named connections:** Multiple per provider. `add_connection/3`, `remove_connection/2`, `rename_connection/3`, `list_connections/1`. `"default"` is not privileged. Names are non-empty user labels and may contain spaces.

**API shape (uuid-strict).** Storage-key construction (`"integration:{provider}:{name}"`) happens only in `add_connection/3` and module `migrate_legacy/0` migrators. All other public API takes a uuid:

- Mutating: `save_setup`, `disconnect`, `remove_connection`, `rename_connection`, `record_validation` — all `(uuid, ...)`
- OAuth: `authorization_url`, `exchange_code`, `refresh_access_token` — all `(uuid, ...)`
- HTTP: `authenticated_request(uuid, ...)`, `validate_connection(uuid, actor)`
- Read shims (uuid OR `provider:name` string): `get_integration/1`, `get_credentials/1`, `connected?/1`
- Migration primitive: `find_uuid_by_provider_name/1`

A corrupted JSONB `provider`/`name` cannot leak into a new key — no public write API derives keys from JSONB.

**Consumer pattern:** modules store the uuid on their own records (`phoenix_kit_ai_endpoints.integration_uuid`, `document_creator_settings.google_connection`). Lookups via `get_integration_by_uuid/1` or `get_credentials/1`. The system does **not** silently fall back to "any connected row of this provider" — consumers specify which.

**Storage dependencies and edits:** `usage(uuid, owner: …)` returns storage usage only
for a connection in the caller's owner scope. Lists and edit pages show libraries,
buckets and roles, including disabled storage and trashed libraries. System views
anonymize private user-library names. Any referenced bucket blocks removal and
disconnection (`{:error, {:in_use, usage}}`). The row lock in `ConnectionLock` is
shared by mutations and normal bucket writers, which recheck live ownership and
credentials before inserting or repointing a bucket.

An object storage connection's service is fixed after setup. While referenced,
its destination is fixed too. `save_setup/4` probes candidate key rotations on
all dependent buckets before persisting, then rechecks fingerprints under the
lock; concurrent dependency changes return `:storage_changed`. Candidates are
never published temporarily. `update_connection/5` commits name and setup together
so a failed rotation does not partially rename the connection. Edit forms keep
network validation asynchronous and disable removal while usage is present.

**Validation:** `validate_connection/2` calls userinfo (OAuth) or validation endpoint (api_key/bot_token). Success flips `status` → `"connected"` and rewrites `connected_at`. `last_validated_at` is rewritten on every attempt.

**Key check (api_key/bot_token):** one authenticated `GET` to `validation.url`, the key sent in `validation.auth_header` behind `validation.auth_prefix` (`Authorization` / `Bearer ` for most). `200` passes, `401` is "Invalid credentials", `403` "Access denied". A service that needs more than that one header adds `validation.extra_headers` — `{name, value}` pairs sent along with the auth header, unchanged; leaving it out sends the auth header alone. A check that is not a plain `GET` declares `validation.strategy` instead. A provider that another module contributes (`integration_providers/0`) cannot add a named strategy, so it declares `validation: %{strategy: :module, module: Mod}` and `Mod` implements `PhoenixKit.Integrations.Validator` (`validate_connection/1`, or `/2` receiving trusted `owner:` context for endpoint policies, answering like any other check; it runs through `Probe`, and is handed the data only once the provider's required setup fields are filled in). Types: `t:PhoenixKit.Integrations.Providers.validation/0`.

**Anthropic** (`anthropic`, `:ai_completions`, site-wide and personal): `base_url` is `https://api.anthropic.com/v1` — Anthropic's OpenAI SDK compatibility layer, so AI consumers reach `POST <base_url>/chat/completions` with the same `Authorization: Bearer <key>` they send everywhere. The key *check* uses the native API instead: `GET /v1/models` with `x-api-key` and `extra_headers: [{"anthropic-version", "2023-06-01"}]`. Anthropic documents `Authorization: Bearer` as the main header and `x-api-key` as a legacy fallback that is still supported; `anthropic-version` is required on the native API, which is why the check needs `extra_headers`. A key that is not scoped to one workspace needs an `anthropic-workspace-id` header on every request and is refused with a 400 without it, so the setup instructions have the admin scope the key to a single workspace. The compatibility layer is documented by Anthropic as meant for testing and comparison: prompt caching, extended-thinking output and structured outputs need the native Messages API.

**Z.ai** (`zai`, `:ai_completions`, site-wide and personal): `base_url` is `https://api.z.ai/api/paas/v4` — Z.ai's general, OpenAI-compatible API, so AI consumers reach `POST <base_url>/chat/completions` with `Authorization: Bearer <key>`. The key check is the plain generic one: `GET https://api.z.ai/api/paas/v4/models` with the same Bearer header, no `extra_headers`. `GET /models` is not in Z.ai's published API reference; it is expected to answer an OpenAI-style model list, as on other OpenAI-compatible APIs, and must be confirmed with a real key: without a key Z.ai answers 401 on every path, so a 401 does not prove the route exists, and an unknown path with a valid key is a 400 with code 1222. The general API bills the account balance (no credit → 429 with code 1113); the GLM Coding Plan endpoint `https://api.z.ai/api/coding/paas/v4` is **not** used, and an existing key of an account that has had a GLM Coding Plan (a "Compatible" key, created before 16 October 2026) is billed on the general API from the account balance or usage bundles, not from the plan quota.

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
