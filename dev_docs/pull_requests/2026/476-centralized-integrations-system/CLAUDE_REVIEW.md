# PR #476 Review — Centralized Integrations System

**Reviewer:** Claude (claude-sonnet-4-6)
**Date:** 2026-04-06
**PR:** BeamLabEU/phoenix_kit#476
**Branch:** dev ← mdon/dev
**Scope:** ~9,300 lines added, 72 files

---

## Summary

Adds a centralized system for managing external service credentials (OAuth tokens, API keys, bot tokens) in phoenix_kit core. Previously each module managed its own connection flow; now there is a shared `PhoenixKit.Integrations` context, a Settings-backed store, an admin UI at `/admin/settings/integrations`, and a reusable `IntegrationPicker` component. The PR also migrates the document creator's Google OAuth and the AI module's OpenRouter key into this system.

The PR is bundled with unrelated features (LLM text module, user invitations, organization settings), making it harder to review and reverting/bisecting individual features more difficult. That is a process issue, not a code issue, but worth noting.

---

## Architecture Assessment

The design is sound. Using the existing `phoenix_kit_settings` JSONB table instead of a new schema was the right call — storage is already proven, caching is inherited, and the key-prefix convention (`integration:provider:name`) is clean. The separation into `Integrations`, `Providers`, `OAuth`, and `Events` modules is logical. The two new `PhoenixKit.Module` callbacks (`required_integrations/0`, `integration_providers/0`) are minimal and non-breaking.

The `{provider_key}:{name}` multi-connection design is a notable strength — it allows a single provider type to have multiple independent connections ("google:personal", "google:work"), which is common in real deployments.

---

## What Works Well

- **`OAuth` module** is clean and generic. Token exchange, refresh, and userinfo fetch are all correctly isolated with no provider-specific logic leaking in.
- **Legacy migration** for `document_creator_google_oauth` is defensive and handles failure gracefully (falls back to `:not_configured` without crashing).
- **`Events` module** is minimal and correct. Silenced exceptions in `broadcast/1` are acceptable for PubSub — a failed broadcast should not crash the calling process.
- **`IntegrationPicker` component** handles deleted integrations well (shows a warning card rather than crashing or silently ignoring them). Auto-select when only one connection exists is a good touch.
- **`has_credentials?` / `maybe_set_status`** logic correctly distinguishes connected/configured/disconnected states.
- **Type specs** are present throughout the context module, which is good for maintainability.

---

## Issues and Concerns

### BUG - HIGH: Password fields are silently cleared on edit

`integration_form.ex:432-436`:

```elixir
# For password fields, skip empty values to keep the existing credential
Map.put(acc, field.key, value)
```

The comment says "skip empty values" but the implementation does the opposite — it unconditionally `Map.put`s the trimmed value, which will be `""` if the field was left blank. When an admin opens the edit form for an existing integration (e.g., to update the client_id), submitting without filling in the password field will overwrite `client_secret` or `api_key` with an empty string. The existing credential is silently wiped. The fix:

```elixir
if field.type == :password and value == "" do
  acc  # skip empty password fields
else
  Map.put(acc, field.key, value)
end
```

The same issue exists in `save_and_redirect/4` (line 322-328), which also does not skip empty password values.

### BUG - MEDIUM: Duplicate `external_account_name` assignment

`integrations.ex:525-526`:

```elixir
|> maybe_put("external_account_name", userinfo["name"])
|> maybe_put("external_account_name", userinfo["name"])  # duplicate
```

The second call is a no-op since `maybe_put` only sets if the key is absent (it's not — the first call just set it). This is harmless but indicates a copy-paste error.

### BUG - MEDIUM: `disconnect/1` is inconsistent for `key_secret`

`integrations.ex:264-267`:

```elixir
"key_secret" ->
  data
  |> Map.take(["provider", "auth_type", "access_key", "secret_key"])
  |> Map.put("status", "disconnected")
```

For OAuth, "disconnect" removes tokens but keeps the app credentials (client_id/secret). For `api_key` and `bot_token`, disconnecting removes the key entirely. For `key_secret`, the current code *keeps* both `access_key` and `secret_key` after disconnect — but these are the credentials, not setup config. There is no "setup vs runtime" split for key_secret the way there is for OAuth. The behavior should match `api_key`: remove the keys and set status `disconnected`.

### BUG - LOW: `connected?/1` makes redundant DB calls

`integrations.ex:121-138`:

When `get_credentials/1` returns an error for a bare provider key (no name), `connected?/1` then calls `list_connections/1` to check if any connection is connected. But `get_credentials/1` already falls through to `find_first_connected/1` in this case, which also calls `list_connections/1`. The result is that the happy path can hit the database twice for the same data. Not a correctness bug, but a performance issue on a function likely called frequently.

### SECURITY: Credentials stored in plaintext

The plan acknowledges this explicitly as "future work," but it should be elevated as a known risk. `client_secret`, `access_token`, `refresh_token`, `api_key`, and `bot_token` are all stored as plaintext JSON in the `phoenix_kit_settings` table. Anyone with read access to the database (or Settings query access) can extract live OAuth tokens and API keys. This is acceptable as a v1 trade-off but should have a tracking issue.

### SECURITY: XSS via `render_markdown_inline` with `raw()`

`integration_form.html.heex:279-289` uses `Phoenix.HTML.raw(render_markdown_inline(...))`. The `render_markdown_inline/2` function substitutes `{redirect_uri}` into the provider's instruction text. The `redirect_uri` is derived from `URI.parse(url)` where `url` is the LiveView's mounted URL. In a real browser this is safe because special characters are percent-encoded by the browser. However, the function does no sanitization, and if `redirect_uri` could ever contain `<`, `>`, or `"` characters (e.g., from a non-browser client, a test environment, or a future code path), the output would be injected into the DOM as raw HTML. The function should HTML-escape the `vars` values before substitution, or the template should pass individual parts to HEEx for automatic escaping.

### DESIGN - HIGH: Core module hardcodes knowledge of `document_creator`

`integrations.ex:632-767` hardcodes `"google" => "document_creator_google_oauth"` and calls `Settings.update_json_setting_with_module("document_creator_folders", ..., "document_creator")`. The core `Integrations` module now has an explicit dependency on `document_creator`'s internal settings key structure. When the document_creator module is dropped or renamed, this migration code will leave orphaned logic in core. The migration should have been run as a one-time script or a versioned migration, not baked permanently into the hot path of `get_integration/1`.

### DESIGN - MEDIUM: Validation logic is duplicated

`do_validate_connection/1` in `integrations.ex` (settings list LiveView) and `run_connection_test/2` in `integration_form.ex` implement the same validation logic independently. Both handle `oauth2`, `api_key`, and `bot_token` types. If a provider is added, both need to be updated. This should live in the `Integrations` context (e.g., `Integrations.validate/1`).

### DESIGN - MEDIUM: Telegram hardcoded in generic validation

`integrations.ex:221-228` (settings LiveView):

```elixir
defp validate_by_auth_type(%{auth_type: :bot_token}, data) do
  token = data["bot_token"] || ""
  case Req.get("https://api.telegram.org/bot#{token}/getMe") do
```

The same is in `integration_form.ex:378`. `bot_token` is defined as a generic auth type (could be Discord, Slack, etc.) but the validation hardcodes Telegram's API endpoint. Provider-specific validation URLs should be in the provider definition (like `openrouter`'s `:validation` map), not in generic auth-type dispatch.

### DESIGN - MEDIUM: `IntegrationPicker` search event undocumented

The search input fires `phx-keyup="integration_picker_search"` on the parent LiveView, but the component's `@doc` does not document this requirement. Any LiveView using this component must implement `handle_event("integration_picker_search", %{"value" => query, "picker-id" => id}, socket)` or the search input silently does nothing. The component's documentation only mentions `on_select`. Additionally, having a fixed event name means two pickers in the same LiveView could conflict.

### DESIGN - LOW: `Providers.all()` iterates all modules on every call

`providers.ex:45-64`: `all/0` calls `external_providers/0` which iterates `ModuleRegistry.all_modules()`, checking `function_exported?` and calling `integration_providers/0` for each module. This runs on every call to `list_integrations/0`, `list_providers/0`, `load_connections/1`, and `used_by_modules/0`. In a system with many modules, this could be expensive on every page load of the integrations settings page. A compile-time or startup-time cache would be appropriate.

---

## Code Quality Observations

- The `maybe_put/3` helper is clean and used consistently.
- `parse_provider_name/1` handles both `"google"` and `"google:personal"` correctly throughout.
- The `@uuid_pattern` regex for UUID detection is a code smell — mixing UUID lookups and provider-key lookups in `get_integration/1` adds complexity. The calling code should know which kind of identifier it has.
- In `integration_form.ex`, the `# Private` section comment appears twice (lines 280 and 315), suggesting copy-paste during development.
- `build_redirect_uri/3` falls back to `"http://localhost:4000"` if `site_url` is not set. In staging/production this would generate an incorrect redirect URI. It should raise or return an error rather than silently using a localhost URL.

---

## Verdict

**Merge condition met with known debt.** The architecture is well-designed and the core OAuth flow is solid. The centralization goal is achieved. However, two issues need immediate follow-up:

1. **Fix the password field overwrite bug** before this reaches users who edit existing integrations — it will silently wipe credentials.
2. **Track the plaintext credential storage** as a security issue with a concrete plan (Cloak/AES encryption in a future migration).

The document_creator legacy key hardcoded in core is the biggest architectural wart and should be extracted to a one-time migration task or an explicit boot-time migration rather than living in the hot path permanently.
