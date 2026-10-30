# Machine API (admin and public)

The shared core of the machine API: a registry of tools that modules declare, API keys that belong to users, one request pipeline, a REST transport, and the Settings -> API page. Modules (catalogue, warehouse, e-commerce and so on) add the actual tools; core adds `system.get_identity` and everything around it. Core knows no module: the API is split by audience (`/api/admin/v1`, `/api/public/v1`), and the tools a module declares carry its own namespace.

This guide describes what exists in core: REST, MCP and the generated OpenAPI documents. The dangerous-operation flow (previews, confirmation codes, approvals, idempotency) is described in the last section.

## Parts

| Part | Module | Does |
|---|---|---|
| Tool | `PhoenixKit.API.Tool` | One callable tool: name, audience, scope, permission, schemas, handler |
| Registry | `PhoenixKit.API.Registry` | Tools of enabled modules (`api_tools/0`) plus core's `system.*`, minus `api_disabled_tools` and the tools of modules in `api_disabled_modules` |
| Keys | `PhoenixKit.API.Keys` | Create, verify, revoke, rotate; effective scopes; 60 s row cache |
| Service users | `PhoenixKit.API.ServiceUsers` | Accounts for programs (`api_only`), roles limited to the creator's own |
| Config | `PhoenixKit.API.Config` | Switches, limits, lists, all from Settings, failing closed |
| Rate limits | `PhoenixKit.API.RateLimit` | Hammer buckets: pre-auth failures per IP, per key, public per client token and per IP, and the shared new-rows quota |
| Validator | `PhoenixKit.API.Validator` | The JSON Schema subset the tools use |
| Auth, Executor, REST | `PhoenixKit.API.Auth`, `.Executor`, `.REST` | The request flow, `forward`ed by `phoenix_kit_routes/0` |
| MCP | `PhoenixKit.API.MCP` | The Model Context Protocol transport: `/mcp/admin`, `/mcp/public` |
| OpenAPI | `PhoenixKit.API.OpenAPI` | The generated OpenAPI 3.1 documents |
| Public discovery | `PhoenixKit.API.PublicDiscovery` | The public guide `GET /mcp`, `/.well-known/api-catalog`, `Link` headers, the `/llms.txt` section |
| Paths | `PhoenixKit.API.Paths` | The one table of API paths; the router and the body guard both read it |
| Legacy | `PhoenixKit.API.Legacy` | Every deprecated name (paths, settings keys, error codes), deleted in 3.0.0; see "Deprecated aliases" |
| Body guard | `PhoenixKit.API.BodyGuard` | Endpoint plug before `Plug.Parsers`: 2 MB limit, JSON errors as problem+json (JSON-RPC parse errors on `/mcp/*`) |
| Admin page | `PhoenixKitWeb.Live.Settings.Api` | Four tabs held in the URL (`?tab=access\|keys\|approvals\|guide`): switches and modules, keys and service users, approvals and limits, the guide (route `/admin/settings/api`) |
| Admin guide | `PhoenixKitWeb.Live.Settings.ApiGuidePanel` | Read-only "how to connect" tab (`/admin/settings/api?tab=guide`, permission `api`), built when the tab is opened from the registry: endpoints, client snippets, tools by module, errors. `ApiGuide` is only the redirect of the retired `/admin/settings/api/guide` |

## Switching it on

Both sides are **off by default** and fail closed: a Settings read error counts as off.

| Setting | Default | Side |
|---|---|---|
| `api_admin_enabled` | `false` | `/api/admin/v1/*` |
| `api_public_enabled` | `false` | `/api/public/v1/*` |

While a side is off, every path of it answers `404` after one cached settings read. Flip them on Settings -> API (permission `api`); the change lands in the Settings history with the admin as actor.

Limits and lists are settings too (`api_admin_rate_per_min`, `api_admin_preauth_fail_per_min`, `api_public_token_rate_per_min`, `api_public_ip_rate_per_min`, `api_public_new_rows_per_ip_hour`, `api_public_new_rows_global_hour`, `api_disabled_tools`, `api_mcp_allowed_origins`). Lists are stored as newline-separated strings (`PhoenixKit.API.Config.parse_list/1` and `encode_list/1`). They are edited in the "Limits and advanced" card of Settings -> API: the whole form is validated first, one invalid field saves nothing, and every changed value is a permanent `setting.changed` entry in the Activity log with the admin as actor.

### Switching a module's API off

`api_disabled_modules` is a newline-separated list of module keys (`module_key/0`). A module in the list has its API switched off: `PhoenixKit.API.Registry` withholds all its tools exactly like tools in `api_disabled_tools`. Its tools are left out of the REST list, MCP `tools/list` and the OpenAPI document, and a call to one (REST, MCP `tools/call`, the executor) answers `404 not_found`, as does an approval or a confirmation code issued before the switch. A scope of such a module grants nothing until it is switched back on, but it stays on the keys that hold it. A module that is not listed is on, so existing installs keep working; core's own `system.*` tools belong to no module and cannot be switched off. The list is read through the same cached settings path as `api_disabled_tools` and fails closed the same way. The settings cache is per node (5 minutes), so on an install with several web nodes a change reaches the other nodes within that time, not on their next request.

Each module that declares tools (`PhoenixKit.ModuleRegistry.api_modules/0`) has a switch in the "Modules" card of Settings -> API (event `set_module_api`, checked on the server like every other event of the page). The event reads the stored list from the database under a row lock (`PhoenixKit.Settings.modify_setting_with_module/4`), not from the cache, so two admins, or a node with a stale cache, cannot undo each other's change. The change is a `setting.changed` entry in the Activity log with the admin as actor.

### Writes of a person's live session

An in-app assistant calls the tools in process for the signed-in person (`PhoenixKit.API.Executor.visible_for/3` and `execute_as/5`, actor `kind: :user`). It reads by default (`allow: :read`). With `allow: :all` it may also propose the writes of the modules listed in `api_session_write_modules` (newline-separated module keys, empty by default; a list that cannot be read opens none), which the "Agent may act" box beside a module's switch sets (event `set_module_session_write`; shown only for a module with admin write tools; while the module's API is off it cannot be turned on, but a ticked box can be taken off; a `setting.changed` entry like the switch). A write of another module answers `403 module_write_disabled`. API keys never read the list.

A write of a session never runs on its first call, dangerous or not: the answer is the preview with `"status": "confirmation_required"`, a `confirmation_id` and `expires_at` (`api_user_confirm_ttl_seconds`), and no code. Once the person confirms, the caller passes that id with the same tool and arguments to `Executor.redeem_as/6`, which goes through the whole request path again with the rights of the confirming session, checks the row (the person's, the same tool and arguments, still waiting), takes a fresh dry run and spends the row with one atomic update, so a double click runs once. Values that changed since the preview give a new row with a fresh preview (`"reason": "changed"`) and the old one expires; another person's id and an unknown one get the same `409 confirm_token_invalid` (`invalid`). `PhoenixKit.API.Confirm.get_for_user/2` reads the row for the page (`{:error, :forbidden}`, without the preview, once the session may no longer write with its tool), `reject_for_user/2` turns it down, and `<.operation_preview>` (`PhoenixKitWeb.Components.Core.OperationPreview`, opt-in) draws its preview. Every charged write of a session is an `api.request` Activity entry with `resource_type: "user"` and `metadata.via` (the `:via` option, `"session"` by default, which the handler also reads as `ctx.via`), never with the input, the preview or the result. The core does not tell an impersonated session from the person's own: a caller of `execute_as/5` with `allow: :all`, `redeem_as/6`, `get_for_user/2` or `reject_for_user/2` must refuse a session that `PhoenixKitWeb.Users.MultiSession.impersonated?/1` marks.

On the Modules page every such module that has a card carries a badge that links to the "Modules" card of Settings -> API: "API off" when its switch is off, "API idle" when its switch is on but nothing can call it now (the module is disabled, or every audience its tools serve, admin or public, is switched off in the two switches at the top of the page), and "API on" when it can be called. The badge looks at the switches and the module only: while the website password gate is on, the public side also answers `404` to every client that is not on the gate's allow-list, and the badge does not show that.

## Who may manage keys

The `api` permission gates Settings -> API.

- The Owner always has it.
- It is **opt-in for Admin**: `api` is in `Permissions.opt_in_admin_keys/0`, so upgrading core does not hand every Admin the power to mint bearer keys. An Owner grants it on the permissions matrix.
- The Owner sees and manages every key. Anyone else who holds `api` sees and manages only the keys and service users they created.
- **Revoke is not manage.** `Keys.can_revoke?/2` is `can_manage?/2` plus, for a personal key, an Owner: an Owner may revoke anyone's personal key and remove scopes from it, but never rotate it. `Keys.revoke/2` authorizes nothing, so call `can_revoke?/2` first.

## Keys

- A key belongs to a **user**. The creator owns it themselves or gives it to a **service user** they created on the same page.
- A key has **scopes** (`<module>.<resource>:<action>`), optional allowed addresses (IPs or CIDR blocks) and an optional expiry date.
- Token format `pk_<8 hex>_<43 base64url>`. It is shown **once**, in a dialog on the page, and only a SHA-256 of the secret is stored.
- **Effective rights on every request** are the key's scopes filtered by the owner's permissions **right now** (`Scope.for_user(user, narrow: false)` and `Scope.can?/2`). Removing a role from the owner, blocking or deleting the owner, or clearing a human owner's email confirmation while `require_email_confirmation` is on, takes effect on the next request, whatever the cached key row says. Service users do not require email confirmation. Owner rights are never cached.
- **Rotation** makes a new key with the same settings; the old key keeps working for a grace period of 0 to 24 whole hours, then stops.
- **Editing scopes** (`Keys.update_scopes/3`, "Edit scopes" in the key's menu): a key's scopes can be changed to any subset of what its owner may use now. Scopes the owner cannot use right now (the module is switched off, the tool is hidden by `api_disabled_tools`) are listed as inactive and stay on the key when it is saved. Only the key's creator or an Owner may edit, a revoked key cannot be edited, and the change takes effect on the next request (the cache entry is invalidated like for a revoke).
- Create, rotate, revoke, scope edits (`api.key_scopes_updated`, with the old and the new list) and service-user creation are written to `PhoenixKit.Activity` with module `api` and `permanent: true`. Read them in the Activity log (Admin -> Activity, module `api`); the Settings -> API page has no history card of its own.

### Personal keys

A person's own key, made on the **My API keys** page (`/profile/settings/api-keys`, a tab of the profile settings) or in the `:api_keys` section of `PhoenixKitWeb.Live.Components.UserSettings`. The section is opt-in and takes two assigns, both required: `scope` (the session's scope) and `impersonated` (`MultiSession.impersonated?(session)` from the host page's mount, never a constant); without them it shows an explanation and the component refuses every event.

- **Permission `api_personal_keys`:** a flat core key, opt-in for Admin (never auto-granted). It lets a person keep keys that act as themselves, with their own rights. It does not open Settings -> API, Approvals or service users (those stay `api`). A user with only this key passes `Scope.can_access_admin_area?/1`, like a holder of `integrations`. A holder of `api` may keep personal keys too.
- **The `personal` column** (V226) is set only by `Keys.create_personal_key/3`. `create_key/3` never sets it, so every key made on Settings -> API, and every key from before V226, behaves as described under "Keys".
- **Limits:** a personal key must expire, no later than the end of the UTC day `api_personal_key_max_days` days from today (`PersonalKeysConfig.latest_expiry/0`; a rotation gives the new key that expiry); it cannot need approval; a person never has more than `api_personal_key_max_count` live keys, counting a key in the grace period of a rotation: a creation, and a rotation with a grace period (`grace_hours > 0`), are refused with `:personal_key_limit` while the person is at the limit, checked under one advisory lock per person. A rotation with grace 0 replaces the key one for one and is always allowed; the pages offer grace 0 as the default at the limit. Both settings are on Settings -> API.
- **The permission is checked on every path.** It is one private owner check that `Keys.active_owner/1` and `verify/2` both use (so `active?/1` and `Confirm.live_actor/1` too), and it is part of `actor/3` and `effective_scopes/1`. Taking `api_personal_keys` (and `api`) from the role stops the key on the next request, whatever the cached row says; giving it back revives the key. Do not build an actor from a key anywhere that bypasses this check.
- **Owner rules:** an Owner can revoke someone's personal key and remove scopes from it (`update_scopes/3` refuses anything that is not narrowing with `:scopes_not_narrowing`); an Owner cannot rotate it. A new token acting as a person goes to that person alone.
- **A borrowed session:** `create_personal_key/3` and `rotate/4` take `impersonated: boolean` with no default, read from the session. Without it they answer `:impersonation_unknown`, in an impersonated session `:impersonated`. Nobody mints a token in the name of the person they are impersonating.
- **Residual risk:** someone who signs in as the person directly (not as a second account in the same session, which is a borrowed session for this purpose) with the person's own password (for example after an administrator reset it) can create a key. The key stops with the permission, is revoked by the person or an Owner, and expires within `api_personal_key_max_days`.
- Create, rotate, revoke and scope edits are in the Activity log like any other key.

### Service users

A service user is a `phoenix_kit_users` row with `api_only: true`, an address `api-<uuid>@service.invalid` and a random password hash nobody knows. It holds roles the creator chose, limited to roles whose permissions are a subset of the creator's own (never Owner). **Every web authentication door refuses `api_only` users** (password login, magic link, password reset, OAuth, QR login, registration confirmation, impersonation, and any existing session token).

## Calling the API

The request body is always read as JSON, whatever its `Content-Type` says (`BodyGuard`). Send the key only in the `Authorization` header. A key in a URL is refused with `400 token_in_url`, as is any query parameter named `api_key`, `apikey`, `api-key`, `authorization`, `bearer`, `access_token`, `token`, `secret` or `confirm_token`, or any name that ends in `_token` such as `session_token` (any case), or any value starting with `pk_` (`PhoenixKit.API.Auth.token_in_url?/1`; the rule is `Auth.credential_name?/1`, shared with the redaction of stored answers).

```bash
# who am I, and what may I do
curl -s -X POST https://example.com/api/admin/v1/system.get_identity \
  -H "Authorization: Bearer pk_0123abcd_..." \
  -H "Content-Type: application/json" -d '{}'

# which tools can this key call
curl -s https://example.com/api/admin/v1/ -H "Authorization: Bearer pk_0123abcd_..."
```

With a URL prefix other than `/`, the paths sit under it (`/phoenix_kit/api/admin/v1/...`). Read it from `PhoenixKit.Utils.Routes.prefix_base/0`.

Errors are `application/problem+json` with a stable `code`:

```json
{"type": "https://phoenixkit.dev/api/errors/forbidden", "title": "Forbidden", "status": 403,
 "code": "forbidden", "detail": "This key lacks catalogue.categories:write.",
 "context": {"required_scope": "catalogue.categories:write"}, "request_id": "..."}
```

| code | HTTP | When |
|---|---|---|
| `unauthorized` | 401 | no, malformed, unknown, revoked or expired key; blocked or deleted owner |
| `forbidden` | 403 | the key lacks the scope, or its owner lacks the permission |
| `ip_not_allowed` | 403 | the key has allowed addresses and the caller is outside them |
| `token_in_url` | 400 | a credential in the query string |
| `invalid_json` / `payload_too_large` | 400 / 413 | body is not JSON / over 2 MB (`BodyGuard`) |
| `not_found` / `module_disabled` | 404 | unknown tool, API off / the tool's module is disabled |
| `validation_failed` | 422 | input does not match the tool's schema; `context.errors` lists paths |
| `rate_limited` | 429 | with `Retry-After`; successful calls carry `RateLimit-*` headers |

The full list of codes and statuses is `PhoenixKit.API.Problem.statuses/0`: core's own codes plus the ones enabled modules declare (see "Error codes of a module"). `detail` is always English; the codes are the contract.

### Rate limits

Hammer's ETS backend is per node. Failed authentications are counted per client IP; when that bucket is full only requests that fail authentication get `429`, so a valid key from the same address still passes. The client IP is the last `X-Forwarded-For` hop only when the direct peer is a loopback or private address; behind a proxy on a public address every client shares the proxy's IP. A private peer address alone does not establish trust: the proxy must overwrite `X-Forwarded-For` or append the actual client address on every request, and the application port must be reachable only through that proxy. A Docker-published port reachable directly, or nginx forwarding a client-supplied XFF while setting only `X-Real-IP`, lets the client forge the address used for `allowed_ips` and rotate failed-authentication buckets. Set `config :phoenix_kit, :trusted_proxies` to the proxy's CIDR block(s) to believe those headers only from it, public address included (see `guides/integration.md`). Strip incoming forwarding headers at the trusted edge; `X-Real-IP` is only a fallback when the final XFF entry is absent or invalid.

A write tool costs more than one unit when it takes a long list: `max(1, ceil(rows / 50))`, with the rows counted up to the tool's `max_items` (up to 1000 when it declares none), so a refused oversized batch is charged as a full one.

The public audience has two buckets per call: one per client token (when the tool declares one, see "Client token of a public tool") and one per client network. The call pays 1 unit of the network bucket **before** the tool is looked up (so a flood of unknown names ends in `429` without a registry walk), and after the lookup its full `cost` to the token bucket and `cost - 1` to the network bucket. A call that the token bucket refuses has therefore already spent 1 unit of the network bucket.

A module that creates rows for a caller without a key charges a shared quota: `PhoenixKit.API.RateLimit.check_new_rows/1` (`:ok` or `{:error, retry_after_seconds}`) counts a new row against `api_public_new_rows_per_ip_hour` (per client network) and `api_public_new_rows_global_hour` (all clients). The module calls it when it creates the row; core never does. The quota is one for every module, not one per module.

A call that is refused before the limiter (an unknown, hidden, forbidden or disabled-module admin tool) costs one unit, over REST and MCP alike, and answers the same refusal (`404` or `403`), or `429` once the key's budget is spent; it writes no audit entry. A key therefore cannot loop on invented tool names for free.

## Declaring tools (module authors)

Add the optional callback `api_tools/0` to your `use PhoenixKit.Module` module:

```elixir
@impl PhoenixKit.Module
def api_tools do
  [
    PhoenixKit.API.Tool.new!(
      name: "catalogue.list_categories",
      audience: :admin,
      scope: "catalogue.categories:read",   # <module>.<resource>:<action>
      permission: "catalogue",              # the role permission the key's owner must hold
      title: "List categories",
      description: "Written for a person and for an agent.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: {MyApp.API, :list_categories}  # called as apply(MyApp.API, :list_categories, [input, ctx])
    )
  ]
end
```

The handler returns `{:ok, map}`, `{:ok, map, effects}` or `{:error, code, message, context}` (`code` from `PhoenixKit.API.Problem.statuses/0` or declared by the module, see "Error codes of a module"). Core does validation, permission checks, rate limits and the request log; the module logs its own domain changes with the key's owner as actor.

Rules that the registry enforces: tool names match `<namespace>.<verb>_<noun>`; a scope has exactly one `permission`; public tools have neither; a scope of a disabled module stays on the key but grants nothing. The input names `dry_run`, `confirm_token` and `idempotency_key` are reserved for the executor and rejected in a tool's schema. A public tool declares `language` and `currency` itself, and, when it needs to tell its anonymous callers apart, `client_token` (below).

When a handler fails, the executor logs the exception module always, the exception message only for the two kinds whose message is fixed text (`ArithmeticError`, `FunctionClauseError`), and a stacktrace with argument lists replaced by their length. All other messages can embed the failing input and never reach the log: `KeyError`, `MatchError` and Ecto errors print their arguments, and the standard library raises `ArgumentError`, `RuntimeError` and `UndefinedFunctionError` with the value it failed on (`Date.from_iso8601!/1`, `Module.concat/1`), so a client token or personal data would reach the log. Code that logs a request-derived term follows the same rule. Processes a handler spawns log their own crashes, so never put request data in their messages. The text kept for those two kinds is the text of the exception class, not of the instance, and an atom is logged as "an atom" (except `nil`, booleans, `:ok` and `:error`), since one can be made from input.

A tool that hands out a public page URL (a published post, a catalogue page) builds it with `PhoenixKit.Utils.Routes.canonical_absolute/2` (a path that is already built; `canonical_absolute_or_nil/2` answers `nil` instead of the site base when the language has no host, in the same single resolver call, for a presenter with a base of its own) or `canonical_url/2` (a canonical path; it uses the language's base code as the segment, so a dialect served under its own `/en-gb` segment goes through `canonical_absolute/2` with a built path), passing the language of the page as stored (a dialect code such as `en-GB` included). A multi-domain host serves each language from its own host through `config :phoenix_kit, :canonical_host_resolver, {mod, fun}`; these helpers ask it with that code (safely, `canonical_host/1`; it maps dialects itself and answers `nil` for one without a domain) and, on the host found, leave out the language segment when it is the language's base code (`/de`, `/en`; a dialect segment such as `/en-gb` stays, on the dialect's own host too), and fall back to the site's base URL with the segment otherwise. The scheme is that of the explicit `site_url` setting (`http` or `https`), and `https` when it is unset. The resolver is called once per URL: keep it cheap. Do not prefix the request's `Host` header or `site_url` yourself, and do not call the resolver yourself, nor probe with `canonical_origin/1` before these helpers.

### Client token of a public tool

A public tool has no key, so it has no caller identity. A tool that needs one (to rate-limit a caller, to scope an `idempotency_key`, to bind a confirmation code) names the input field that carries its anonymous client's token:

```elixir
PhoenixKit.API.Tool.new!(
  name: "booking.hold_slot",
  audience: :public,
  client_token: "session_token",   # a string property of input_schema
  ...
)
```

After the tool is looked up, the executor hashes the value (sha256, url-safe base64; the clear value goes to the handler and is never kept) into `PhoenixKit.API.Actor.client_token_hash` and uses the hash as the caller's identity: the per-token rate-limit bucket (`api_public_token_rate_per_min`), the scope of the `idempotency_key`, and the binding of a confirmation code. A public tool with a `danger:` must declare `client_token` and list the field in `required`; a call that reaches the confirmation flow without a token is `422 validation_failed` ("A client token is required for this operation.", `path` the declared field). An admin tool may not declare one. `ToolLint` checks all of this. Name the field `*_token`: the field is a credential like a key (see below), and core recognises a name as a credential only when it is on the list or ends in `_token`.

The field is newer than core 2.63.x, where `Tool.new/1` answers `unknown field(s)`. A module that must also run there sets it only when `Map.has_key?(PhoenixKit.API.Tool.__struct__(), :client_token)`. Until 3.0.0 core reads the field `cart_token` of a public tool that declares none (see "Deprecated aliases").

### Credentials in answers

A field in an answer that carries a secret must be recognizable, or the answer is stored for replay and shown in an approval. The rule of core (`PhoenixKit.API.Auth.credential_name?/1`) is: a name on the list (`confirm_token api_key apikey api-key authorization bearer access_token token secret`) or any name that ends in `_token`, in any case, plus a string value that starts with `pk_`. A secret that is not named `*_token` (a link with a claim code in it, say) is declared in `Tool.credentials`, a list of **output** field names:

```elixir
credentials: ["url"]   # `url` carries the secret; the answer is never stored for replay
```

The tool's `client_token` counts as a credential without being listed. `credentials:` is newer than core 2.63.x (feature-detect it like `client_token`).

### Error codes of a module

Core's error codes are a closed table. A module adds its own with the optional callback `api_problems/0`, which returns `%{code_atom => %{status: 400..599, title: String.t(), advice: String.t() | nil}}`:

```elixir
@impl PhoenixKit.Module
def api_problems do
  %{slot_taken: %{status: 409, title: "Slot taken", advice: "Pick another slot and try again."}}
end
```

Enabled modules are asked only when an error is answered. `Problem.status/1`, the problem `title` and the MCP advice (`[code] message - advice`) read the declarations. A declaration cannot replace a code of core (it is dropped with a warning, like an invalid entry or a code another module declared first). The `code`, `status` and `title` are a contract with clients: change them like an API. A code that nothing declares answers `500` and is logged. A module that must also compile against an older core defines `api_problems/0` without `@impl`.

Module cron jobs are declared with the optional `oban_crons/0` callback (one `{cron, worker_module}` per worker); `mix phoenix_kit.update` writes them into the host's Oban config.

### Tools of the host application

A host application declares tools for its own code the same way: one module in the host with `use PhoenixKit.Module` and `api_tools/0`. Discovery scans every application whose `.app` lists `:phoenix_kit`, the host included, so a module that only declares tools needs no config line (`config :phoenix_kit, modules: [...]` matters for a host module with routes or tabs, which the router must see on a cold build). A running node picks the module up after a restart or `PhoenixKit.ModuleRegistry.rescan/0`.

```elixir
defmodule MyApp.API.Tools do
  use PhoenixKit.Module

  @impl PhoenixKit.Module
  def module_key, do: "orders_api"     # the key in api_disabled_modules

  @impl PhoenixKit.Module
  def module_name, do: "Orders"        # its row in Settings -> API, its tool group in the guide

  # Always on; its API can still be switched off in the "Modules" card of Settings -> API.
  @impl PhoenixKit.Module
  def enabled?, do: true

  @impl PhoenixKit.Module
  def enable_system, do: {:error, :always_on}

  @impl PhoenixKit.Module
  def disable_system, do: {:error, :always_on}

  @impl PhoenixKit.Module
  def api_tools do
    [
      PhoenixKit.API.Tool.new!(
        name: "orders.list_orders",
        # ...the other required fields (audience, scope, permission, ...) as in "Declaring tools" above
        handler: handler("Orders", :list_orders)
      )
    ]
  end

  # Built at run time: a literal {MyApp.API.Tools.Orders, :list_orders} would tie the
  # router to the handler and to everything the handler calls.
  defp handler(name, fun), do: {Module.concat(__MODULE__, name), fun}
end
```

- `module_name/0` is what admins read: name it after what the tools do.
- Without `permission_metadata/0` the module has no card on the Modules page and no permission key of its own. A tool uses a key the host already has, or one it registers at start with `PhoenixKit.Users.Permissions.register_custom_key/2`; pass `auto_grant_admin: false` unless every Admin should get it.
- A handler reads and writes only what `ctx.scope` may reach, and answers nothing without one.
- The router depends at compile time on this module and on every module it names, so a change in any of them recompiles the router: keep the module to declarations and name handlers as above.
- REST and MCP serve the admin tools to keys that hold their scopes; an in-app assistant acting for a signed-in person (`PhoenixKit.API.Executor.visible_for/3`) gets the read tools that person may call, and with `allow: :all` the write tools of the modules an admin let it act in ("Writes of a person's live session"). Check the tools with the lint below.

## Installing and upgrading a host

1. `mix phoenix_kit.update` runs the V219 migration (`phoenix_kit_users.api_only`, `phoenix_kit_api_keys`) and the V220 migration (`phoenix_kit_api_confirmations`, `phoenix_kit_api_idempotency`), inserts `plug PhoenixKit.API.BodyGuard` into the host endpoint before `Plug.Parsers`, and writes the three core cron entries and the module cron entries (the entries are listed under "Upgrading a host" in the last section). A host that skips the update has the 8 MB parser limit and no JSON problem answers on `/api`.
2. `PhoenixKit.boot/1` hardens `:phoenix, :filter_parameters` for `password`, `token`, `secret`, `api_key`, `idempotency_key` and every name `PhoenixKit.API.Auth.credential_params/0` refuses in a URL, so a mistaken `?api_key=pk_...` request does not print the key in Phoenix's `Parameters:` log line. If a host replaces that list, keep those names in it.
3. **Run production at log level `:info` or above.** Phoenix prints a request's query parameters at `:debug` before any plug of the API runs, so a key sent as `?foo=pk_...` is refused (`400 token_in_url`) but still shows in that debug line.
4. The Admin role does not get `api`. An Owner grants it when wanted.
5. If the host endpoint is not laid out in the conventional way, `mix phoenix_kit.update` prints a warning instead of patching it: add `plug PhoenixKit.API.BodyGuard` immediately before `plug Plug.Parsers` by hand.
6. Configure a trusted proxy to overwrite or append the real client address in `X-Forwarded-For` and prevent direct access to the application port (see Rate limits). Set `config :phoenix_kit, :trusted_proxies` to the proxy's address (`guides/integration.md`); a private peer alone is insufficient; a public proxy address without host-side real-IP handling makes clients share its address and rate-limit buckets.
7. `phoenix_kit_routes()` claims four paths in every host router: `/api/admin/v1`, `/api/public/v1`, `/mcp/admin` and `/mcp/public` (under the PhoenixKit `url_prefix` when it is not `/`), and, until 3.0.0, the two deprecated aliases `/api/shop/v1` and `/mcp/shop`, and, beside `/llms.txt`, `GET /mcp` (the public guide, under the prefix and at the site root) and `/.well-known/api-catalog` (site root only). While the API is off they answer `404`, and a host that already serves something at one of them after `phoenix_kit_routes()` is shadowed by them. Check the host router before you upgrade.

## MCP

Two endpoints speak the Model Context Protocol (Streamable HTTP, tools only) over the same tools and the same checks as REST:

| Endpoint | Audience | Auth | Switch |
|---|---|---|---|
| `POST /mcp/admin` | admin tools | `Authorization: Bearer pk_...` | `api_admin_enabled` |
| `POST /mcp/public` | public tools | none | `api_public_enabled` |

Under a non-root `url_prefix` they live under it, like everything else. While a switch is off its endpoint answers `404`; while the website password gate is on, `/mcp/public` answers `404` too.

What a client gets:

- `initialize` negotiates the protocol revision (`2025-11-25`, `2025-06-18` or `2025-03-26`, see [Protocol revisions](#protocol-revisions); no `MCP-Protocol-Version` header means `2025-03-26`) and announces the `tools` capability. `ping`, `tools/list` and `tools/call` work; `notifications/*` are answered `202` with no body and run nothing. Batches are not supported. Revision `2026-07-28` (the handshake-less protocol) is not spoken: a client that speaks only that revision is not served, and an unsupported `MCP-Protocol-Version` is always the `400` with JSON-RPC code `-32600`, never a code of that revision.
- There is no session and no event stream: every request carries its own key, `GET` and `DELETE` are `405`, answers are always JSON. The `Accept` header must allow `application/json` (a missing one is fine).
- Tool names use `_` for `.` (`catalogue_list_categories`); `tools/call` accepts both forms.
- A tool that fails comes back as a result with `isError: true` (HTTP 200): the first text item is `[code] message - what to do next`, the second the full problem document as JSON. Only a rate limit is an HTTP `429` with `Retry-After`, and an unknown tool name (also one hidden by `api_disabled_tools`, or of the other audience) is the JSON-RPC error `-32602` `Unknown tool: <name>` with HTTP `200`, as the MCP specification prescribes for every revision this server speaks; a client that treated that case as an `isError` result must now read the `error` member. Everything that happens before a tool runs is an HTTP status: `404` switch off, `400` credential in the URL, `401`/`403` key, `403` foreign `Origin`, `405`, `406`, `400` bad body.
- From revision `2025-06-18` a successful result also carries `structuredContent`, and each tool has `title` and `outputSchema`. A write tool's `outputSchema` allows either the success shape or a preview (`executed: false`); it is written with `anyOf`.
- The control fields of a write tool (`dry_run`, `confirm_token`, `idempotency_key`; see the last section) are ordinary arguments of `tools/call`: `tools/list` lists them in `inputSchema`, and an MCP client cannot set a header for a single call, so the key goes in the arguments. A preview, a request for a confirmation code (`status: confirmation_required`) and a queued approval (`status: pending_approval`) are normal results with `isError: false` and the answer in `structuredContent`; only a refused code, a reused key and the other failures are `isError`. Every answer with `executed: false` means the operation did **not** run: an agent must follow it up (repeat the call without `dry_run`, repeat it with the `confirm_token`, or poll `system.get_approval`), and the `outputSchema` of a write tool says so. Over MCP the key is the `idempotency_key` argument only: an `Idempotency-Key` header on the transport request is ignored.
- `initialize`, `ping`, notifications and unknown methods cost one rate-limit unit each; `tools/list` costs one; `tools/call` costs what the tool costs over REST (a tool may declare its own price with `cost:`, see below), and a call to an unknown, hidden or forbidden admin tool, refused before the limiter, costs one unit. The public endpoint charges one unit of the network bucket before it resolves the name or looks the tool up, so a flood of unknown names ends in 429 without a registry walk. Over MCP a name with an underscore (`catalogue_list_categories`) is mapped back to its dotted name after that charge, so an admin call over MCP does a little more registry work than the same call over REST.

### Protocol revisions

The server speaks `2025-11-25`, `2025-06-18` and `2025-03-26`. They differ only in what a result carries: `2025-06-18` and `2025-11-25` add `structuredContent`, a tool's `title` and `outputSchema`, and the `title` of `serverInfo`; `2025-03-26` gets text only. `2026-07-28` has a different wire format and is not spoken: that header is an HTTP `400` with JSON-RPC code `-32600`, and `initialize` asked for it answers the most preferred revision the server does speak.

The revisions are one table, `PhoenixKit.API.MCP.Versions`: each row is a revision and its feature flags (`structured_content`, `output_schema`, `tool_title`, `server_title`). Nothing else compares revision strings; the code asks for the flag.

Which of the known revisions are served is configuration, read at call time:

```elixir
config :phoenix_kit, :mcp_protocol_versions, ["2025-06-18", "2025-03-26"]
```

The list restricts the set and gives the preference order (the first entry is what `initialize` answers when the client asks for something the server does not speak). Unset means every known revision. An entry that is not in the table is ignored, and a list that leaves nothing falls back to every known revision; each is logged once per node as a warning that names the key and not the value. A revision left out answers `400` on the header and is negotiated down on `initialize`. If `2025-03-26` is left out, a request with no header is `400` too (`initialize` excepted).

- **Retire a revision, or keep serving an older one after a new one is added:** list the revisions to serve in `:mcp_protocol_versions`. No code change.
- **Add a revision:** one entry in the table of `PhoenixKit.API.MCP.Versions` with its flags. That is enough only when its wire format is one the code already produces (the same envelope and handshake, the same result and descriptor shapes, differing at most in the flags above). A host can add such a row without a core change with `config :phoenix_kit, :mcp_extra_revisions, [{"2027-01-01", %{structured_content: true}}]`; flags left out are off.
- **A revision with another wire format** (a different handshake, new required fields, other message shapes, as `2026-07-28` has) **cannot be added by data**. It needs code in the places that read the flags (`PhoenixKit.API.MCP`, `PhoenixKit.API.MCP.Shape`, `PhoenixKit.API.MCP.Rpc`), and a new flag wherever that code has to branch.

### Origin

A request without an `Origin` header (every client that is not a browser) passes. A request with one must name a host this install knows, else it is `403 origin_not_allowed`, before any key is looked at. Known: the host of `site_url` (or, without it, of the endpoint URL), the hosts that a `config :phoenix_kit, :api_request_context, {Module, :function}` hook **explicitly returns under `:hosts`**, and the entries of `api_mcp_allowed_origins` (Settings -> API: one full origin per line; `https://client.example` matches scheme, host and port). The request's own `Host` header is deliberately never trusted: a DNS-rebinding page sends its own `Host` and the same `Origin`. For that reason a hook that returns only a language and a currency, or one that fails, adds no host. A multi-domain install must make its hook return `:hosts` or list its other domains as full origins.

### Connecting a client

An MCP client that lets you set a request header for a remote server takes the key as `Authorization: Bearer <key>` and the endpoint URL `https://<host>/mcp/admin` (or `/mcp/public` without a key). Settings -> API -> API guide tab (`/admin/settings/api?tab=guide`) shows the ready-made lines for this site, with the placeholder `<your key>`:

```sh
claude mcp add --transport http <name>-admin 'https://<host>/mcp/admin' --header 'Authorization: Bearer <your key>'
```

`--header` takes any number of values, so it comes after the URL. The line uses Claude Code's default `local` scope, which keeps the key out of the shared project file. Cursor takes `{"mcpServers": {"<name>-admin": {"url": "...", "headers": {"Authorization": "Bearer <your key>"}}}}` in `~/.cursor/mcp.json` (the user file), VS Code a `servers` entry in `.vscode/mcp.json` whose header is `Bearer ${input:<name>-admin-key}` with an `inputs` prompt of `"password": true`, so the key is asked for and not written down. `<name>` is the slug of the project title; `-admin` keeps it apart from the public server of the same site. Claude's desktop and web connectors cannot send a fixed Bearer header and are not covered. For the public server the site publishes the commands itself: see [Public discovery](#public-discovery) (`GET /mcp`).

Clients that support only OAuth for remote servers are not supported yet. Put the key in the client's secret store, never in the URL: a URL with `?token=...` is refused.

If a CDN or WAF in front of the site challenges bots, exempt `/api` and `/mcp`: an agent cannot pass an HTML challenge, and the API has its own rate limits.

## OpenAPI

`GET /api/admin/v1/openapi.json` (needs a key) and `GET /api/public/v1/openapi.json` (public, CORS `*`) return an OpenAPI 3.1 document built from the registry: one `POST /<tool>` per tool, `operationId` is the dotted tool name, tags are the namespaces, the request body schema is the schema the validator enforces, the `200` schema is the one MCP calls `outputSchema`, errors are the `application/problem+json` document defined once. Each operation has `x-agent-safety` (`read`, `write` or `destructive`), `x-idempotent` and, for admin tools, `x-required-scope`. A write operation also lists the optional `Idempotency-Key` header parameter, the `Idempotent-Replayed` response header and a `409` response (`confirm_token_invalid`, `idempotency_key_reused`, `idempotency_in_progress`); a tool with `replay: false` lists neither the parameter nor the header, and the `409` only when the tool can be dangerous (it has a `danger:`, or it is an admin tool). The admin document lists only the tools the key's effective scopes unlock; a module that is switched off is absent. It costs one rate-limit unit.

## Public discovery

Four things tell a person or an agent how to connect, without a key. All are generated from the public tools in the registry (`Registry.visible_tools(:public, :all)`) on every request, nothing is cached in core, so a switched-off module or a tool hidden in Settings -> API disappears at once.

| What | Where |
|---|---|
| The guide | `GET /mcp` at the site root and under the kit `url_prefix`: HTML by default, Markdown with `?format=md` or an `Accept` that prefers `text/markdown`. Every other method is a `405` that names `/mcp/public`; an `Accept` of `text/event-stream` alone (an MCP client given the guide URL) is a `406` that does the same |
| The API catalog | `GET /.well-known/api-catalog` at the site root only (RFC 9727, `application/linkset+json`, CORS `*`) |
| `Link` headers | `rel="api-catalog"` on `/mcp` and `/llms.txt`; `rel="service-desc"` and `rel="service-doc"` on `GET /api/public/v1` (when it answers `200` and the guide is published) and `rel="service-doc"` on the `405` of `GET /mcp/public` |
| `/llms.txt` | A `## Public API and MCP` section after the operator's text (`LlmsTxt.build(api_section: ...)`, `build_for/2` is unchanged); the Crawlers settings preview shows it while the public API is on |

**One predicate** (`PublicDiscovery.check/1`): the public API switch is on, the website password gate does not hide the site from this client, and at least one public tool is visible. When it is false `/mcp` and the catalog answer the same `404` problem document as the public API, `/llms.txt` has no section and no `Link`. The order on `/mcp` is visibility (`404`), method (`405`), representation (`406`), then `200`.

**Which host the documents name.** Never the `Host` header by itself: it is used only when it is a well-formed hostname and one of `MCP.Origin.known_hosts/1` (the canonical host from `site_url` or the endpoint URL, plus the hosts the `:api_request_context` hook returns under `:hosts`). Any other host gets `MCP.Origin.canonical_origin/0`. The scheme and port are always the canonical origin's, never the request's (`PublicDiscovery.origin/1`). A multi-domain install makes its hook return `:hosts` first-domain-first so each domain advertises itself; the same list widens the MCP `Origin` allow-list. The page language is the `:language` of that hook for the request, reduced to a catalogue core has (else English).

**Cache headers.** `public, max-age=300` while the website gate is off; `private, no-store` while it is on (the answer then depends on the client address); every `404`/`405`/`406` carries plain `no-store`. `/llms.txt` keeps its one hour unless the gate is on and the section is present. No rate-limit unit is charged: these are not API calls.

**Nothing here names the admin API, and only the canonical public paths.** The deprecated aliases are never advertised. The public documents never contain an admin path, tool name, scope, permission, `Bearer` or "approval". `OutputShape.for_tool/1` gives a public write tool a preview shape without approvals for that reason. The leak test (`PhoenixKitWeb.APIDiscoveryTest`) builds its banned list from the admin registry and scans every public body and header.

**Translations.** The guide's headings and fixed sentences are gettext (`default.pot` and the nine `.po` files, added by hand); tool titles and descriptions, command lines and JSON stay as declared. `PhoenixKit.API.PublicDiscoveryTranslationsTest` fails when a msgid is missing from a catalogue.

## Writing tools: the lint

`PhoenixKit.API.ToolLint` checks tools in a module's own tests:

```elixir
test "the API tools are well formed" do
  assert :ok = PhoenixKit.API.ToolLint.check_tools(MyModule.api_tools())
end
```

It rejects every keyword outside the supported subset in an input schema (a whitelist: `oneOf`, `const`, `nullable`, `uniqueItems` and anything else the validator does not enforce; the annotations the validator accepts and ignores, such as `title`, `description`, `default`, `examples`, `format` and `x-*` keys, are fine), `$ref` anywhere, a `required` name that is not declared, a non-object root, an empty description, a public tool with a `danger:` that does not declare a `client_token` and list it in `required`, a `client_token` that is not a string property of the input schema, an admin tool that declares a `client_token`, two tools with one name and two tools whose MCP names collide (`a.b_c` and `a_b.c`).

### Pricing a call

A call costs one rate-limit unit, except a non-read-only admin tool, which costs `max(1, ceil(rows / 50))` (see Rate limits). A tool that needs another price says so: `cost: 5` (a fixed price up to 1000) or `cost: {MyModule.API, :batch_cost}`, a function that gets the raw, unvalidated input and returns a positive integer, for example one unit per query of a batch read. The function runs before validation and its result is clamped only at 1000, not by `max_items`, so it must bound itself. A function that raises or answers anything else is logged (without the input) and the default rule applies. REST and MCP both use it. On the public side the first unit is charged to the network bucket before the tool is looked up; after it the token bucket pays the full price and the network bucket the rest (`cost - 1`).

## Testing

- Use `async: false`: tests register a fake module in the global `PhoenixKit.ModuleRegistry` and the rate-limit counters are shared.
- Give each request its own client address through `X-Forwarded-For` (believed because the test peer is loopback), so no test shares a bucket.
- `PhoenixKit.API.KeyTestSupport` registers a fake module with tools on core permissions and builds users and keys. `test/integration/api/public_api_end_to_end_test.exs` shows every guarantee over HTTP.
- To prove a secret never reaches a log, raise the primary Logger level for real (`Logger.configure(level: :debug)`) around `ExUnit.CaptureLog.with_log/2`; `config/test.exs` sets it to `:warning`, and a `refute log =~ secret` at that level looks at nothing.

## Dangerous operations, approvals and idempotency

The executor adds three fields to the input of **every write tool** (a tool whose annotations do not say `read_only: true`) that can replay, and two to a write tool with `replay: false` (see step 4): `dry_run` (boolean), `confirm_token` (string) and `idempotency_key` (16 to 128 characters of `[A-Za-z0-9_-]`; REST clients may send it as the `Idempotency-Key` header instead). Modules never declare them and the handler never sees them. A read tool has none of them, and a request that sends one gets `422`.

### What a module author must do

1. **Answer a dry run.** The handler is called with `ctx.dry_run? == true` when the caller asked for a preview, and also by the executor to build the preview of a dangerous call (and of every write of a key with `requires_approval`) and to re-check the values at confirmation or approval time. It must **write nothing** (no database write, no download, no notification, no log entry of a domain change) and answer `{:preview, preview, fingerprint}`:

   * `preview` is a map for a person to read. Write it in the common shape and the Approvals page shows it as a table with no code from your module: `"rows"`, a list of maps each with a `"name"`, `"ref"` or `"id"` to call the item by (shown in that order of preference), optionally `"action"`, `"warnings"` (a list of sentences), `"error"` (a sentence, or a map with a `"message"` and optionally a `"code"` and a `"context"`, as the first-party tools write a failed row; the page shows the code and the message) and `"changes"`, a map of field name to `%{"from" => ..., "to" => ...}` (numbers or numeric strings also get a percentage change); `"totals"`, a map of plain values, shown as one sentence (`"rows"` in it is the row count shown next to the title); `"warnings"`, a list of sentences for the whole operation. Anything else is not lost: the page keeps the whole preview under a collapsed "Technical details (JSON)" block. The page cuts the rows at 25 and says so, so put what matters most first. The card is headed by the tool's `title`, so write it for a person ("Change prices").
   * `fingerprint` is a string, a hash of the **current values** the operation would touch (not `updated_at`). A confirmation code and an approval are valid only while the fingerprint is unchanged. Hash the touched rows' values in a stable order; two calls that see the same data must answer the same fingerprint.

   A handler that answers anything else to a dry run is a bug: the executor answers `500 internal_error` and logs it. An error answered to a dry run (`{:error, code, message, context}`) is passed on.
2. **Declare what is dangerous** with `danger:` on the tool: `nil` (never by itself), `:always`, or `{Module, :function}`. Any other value (a typo such as `:allways`) is refused when the tool is built (`Tool.new/1` returns an error), and a hand-built struct that carries one is treated as dangerous. The function is called as `Module.function(input, ctx)` with `ctx.dry_run? == true`, must not write, and returns `true` when the call is dangerous (for example, when a value moves by more than a threshold setting the module owns). A function that raises counts as dangerous. Independently of `danger:`, an **admin** write tool whose longest top-level list holds more than `api_confirm_batch_over` rows (default 50) is dangerous. Public tools never use the row threshold. A **public** tool with a `danger:` flag must declare a `client_token` and list that field in the `required` of its input schema: the gate answers a `dry_run` before it looks for a client token, so without `required` a dry run without one reaches the handler, while the same call without `dry_run` is refused as `validation_failed`.
3. **Use the context.** `ctx.approved_by_uuid` is the person who approved the operation (`nil` unless it runs from the approval queue): put it in the metadata of your change log next to the key's owner, who is `ctx.actor.user_uuid`. `ctx.confirmation_uuid` is the code or approval row the call runs under. `ctx.progress.(partial)` records the partial results of a long batch on an approval (a map or a list); if the process dies, the failed approval keeps them.
4. **Keep credentials out of stored answers.** A `200` answer to a call with an `Idempotency-Key` is stored and replayed. An answer is **not** stored when any object key, at any depth, is a credential name (`api_key`, `confirm_token`, `access_token`, `token`, `secret`, any name that ends in `_token`; any case), is the tool's `client_token` or one of its `credentials`, or when any string value starts with `pk_`. A field that carries a secret must be named `*_token` or be listed in the tool's `credentials`. Approval results, error contexts and progress are stored with those credential fields and recognized credential strings replaced by `[REDACTED]`; polling returns the redacted result. Tools that mint credentials need a separate secure delivery path when run through approvals. A write tool whose answer always carries a credential (a tool that mints a client token) declares `replay: false` (`PhoenixKit.API.Tool`): it then takes no `idempotency_key`, the schemas, MCP and OpenAPI do not offer one (a body that sends it is a `422`; the `Idempotency-Key` header is ignored), and its description says that a repeated call is a new call. Replaying a stored credential is not an option for a tool that anyone can call without a key: the `Idempotency-Key` header is not a secret, so whoever guessed or saw it on the same network would be handed the first caller's credential. `replay:` is newer than core 2.63.0, where `Tool.new/1` answers `unknown field(s): :replay`, `Tool.new!/1` raises and a `%Tool{replay: ...}` literal does not compile. A module that must also run on that core builds the tool with the field only when `Code.ensure_loaded?(PhoenixKit.API.ControlFields) and function_exported?(PhoenixKit.API.ControlFields, :replay_tool?, 1)` is true; a module whose minimum core has it passes `replay: false` unconditionally.
5. **Make stock writes idempotent by themselves** (`external_ref`): a request that committed and died before its answer was stored runs again after its lease (`api_idempotency_lease_seconds`) has run out.
6. **Do not log request-derived values.** The log of the flow follows `PhoenixKit.API.LogSafe` (see the AGENTS.md section): no confirmation code, idempotency key, tool input or approval preview in a log line.

### The flow

| Situation | Answer |
|---|---|
| `dry_run: true` | `200 {"executed": false, "dry_run": true, "preview": ...}`; no code, no approval; nothing ran, send the call again without `dry_run` |
| a dangerous call, no code, an ordinary key | `200 {"executed": false, "status": "confirmation_required", "preview": ..., "confirm_token": "ct_...", "expires_at": ..., "expires_in_seconds": ...}` |
| the same call with `confirm_token` | the handler runs; the code is spent |
| a write call from a key with `requires_approval`, dangerous or not (not a `dry_run`) | `200 {"executed": false, "status": "pending_approval", "approval_id": ..., "preview": ..., "expires_at": ..., "expires_in_seconds": ...}`; the agent follows it with `system.get_approval` |
| a code that is not valid | `409 confirm_token_invalid`, `context.reason` one of `invalid`, `other_arguments`, `used`, `expired`, `changed`, `approval_required`, and `context.preview` is the preview as it is now |
| too many approvals waiting for the key | `429 rate_limited` |
| the same `Idempotency-Key` and request | the first answer, header `Idempotent-Replayed: true` (a pending-approval answer is not stored; see the next row) |
| the same call again while its approval is still pending (with or without a key) | the same `approval_id`, header `Idempotent-Replayed: true`; the answer is looked up again, not stored, so `expires_in_seconds` is current; the call is audited like the first; if the values the call touches changed meanwhile, the waiting approval is closed instead and a new one is queued (a new `approval_id`, no replay header) |
| the same key, another request | `409 idempotency_key_reused`, unless the key's last answer was not stored (a pending-approval answer, a preview, an error): that claim is released, the key is free, and the other request runs as a new one |
| the same key while the first request runs | `409 idempotency_in_progress` |

A code is bound to the key (or, for a public tool, the client token), the tool, the arguments (their order in the JSON does not matter) and the fingerprint. It is spent by one atomic update, so two simultaneous confirmations run the operation once. Previews, prompts, errors and credential-bearing answers are not stored under an idempotency key, so the confirming call may reuse the key of its preview. Nor is the result of an approval stored under the key: once an approval has run, the same call sent again queues a new approval, so an `Idempotency-Key` is not exactly-once across an approval.

### What this protects against, and what it does not

A confirmation code protects against **accidents**, not against a malicious key holder: the same client that receives the code also uses it. A key holder can also stay under the thresholds (`api_confirm_batch_over`, a price change below the percentage) by splitting a change into several calls; the change log (Activity) is the control for that, so every write is logged with its key. The control for **AI agents** is the approval queue: give an agent a key marked "Needs approval", and a person decides every write it asks for, dangerous or not, so splitting a change does not get round it. A key without that mark confirms its own operations. The hint under the "Needs approval" box on the create-key form says the same in short.

The approver sees what is approved: the totals first, then at most 25 rows of the preview as JSON, and a notice (and a second confirmation on **Approve**) when the preview is cut. Approving runs the whole operation, never only the rows shown.

### Approvals

Approvals (a menu entry for holders of `api` while the site uses approvals — a live key marked "requires approval", or an approval still kept — at `/admin/approvals`, with a badge of the approvals the viewer may decide; the old `/admin/settings/api/approvals` redirects there) lists, for an Owner, every pending approval, and for the creator of a key the approvals of their keys for tools whose permission they hold. Approve runs the operation as the key's owner after repeating the request-path checks (key not revoked or expired, owner active, scope and permission still held, tool still enabled, input still valid, with the executor's own functions) and comparing the fingerprint; a failure of the first kind ends the approval `failed`, a changed fingerprint `stale`, and nothing is written. The operation runs in a task of `PhoenixKit.TaskSupervisor`, not in the approver's page: closing the tab or a dropped socket does not stop it half-way. An approval left `approved` or `executing` for 15 minutes (a node that went down) is failed by the five-minute worker. A key that repeats the same dangerous call while its code is live gets the same code; never-used codes are deleted an hour after they ran out. One notification per key per ten minutes goes to those who may decide; it links to the card of the approval that triggered it. A decided card stays on the page and says in words what became of it (done, not executed because the data changed, failed with its code, rejected, expired).

### Settings

`api_confirm_batch_over` (50), `api_confirm_ttl_seconds` (120, at most 600), `api_user_confirm_ttl_seconds` (600, 60 to 86400: a confirmation of a live session), `api_approval_ttl_hours` (72), `api_approval_pending_max` (20), `api_idempotency_ttl_hours` (24), `api_idempotency_lease_seconds` (120): Settings -> API -> Confirmation, approvals and repeats. A module that decides `danger:` from a threshold keeps that setting itself.

### Upgrading a host

`mix phoenix_kit.update` runs V220 (`phoenix_kit_api_confirmations`, `phoenix_kit_api_idempotency`) and V222 (`phoenix_kit_api_confirmations.actor_user_uuid`, the confirmations of live sessions) and adds three cron entries to the host's Oban config: `PhoenixKit.API.Idempotency.PruneWorker` (daily), `PhoenixKit.API.Confirm.ExpiryWorker` (every five minutes) and `PhoenixKit.API.Confirm.PruneWorker` (daily). Without the update there are no tables and a dangerous call answers `500`. The host's `:phoenix, :filter_parameters` should contain `idempotency_key` (`PhoenixKit.boot/1` adds it). Confirmation codes are signed with the host's `secret_key_base`; with none, no code is issued.

### Testing a write tool

`PhoenixKit.Test.ApiFlowTools` and `PhoenixKit.Test.ApiFlowHarness` (`test/support/`) show the whole contract with a handful of tools and an in-memory store; copy their shape. Test, for every write tool (a key marked "Needs approval" sends each of its writes through the dry run and the fingerprint, dangerous or not): the dry run writes nothing; the fingerprint changes when a touched value changes and not otherwise; a confirm after the values changed is `409`; an approval after the key was revoked or the values changed writes nothing.

## Deprecated aliases (until 3.0.0)

The API used to carry the name of one module. Every old name still works, is marked deprecated, and is deleted with `PhoenixKit.API.Legacy` (`lib/phoenix_kit/api/legacy.ex`) in 3.0.0. A guard test (`PhoenixKit.API.ModuleNeutralTest`) fails when anything in `lib/phoenix_kit/api/` outside `Legacy` spells a module name, and fails again when the version reaches 3.0.0 while `legacy.ex` is still there.

| Old name | Use instead | What happens until 3.0.0 |
|---|---|---|
| `/api/shop/v1`, `/mcp/shop` | `/api/public/v1`, `/mcp/public` | Same plug, same answers, plus `Deprecation: @1792454400` (RFC 9745) and `Link: <canonical>; rel="successor-version"`; one `info` log line per node. The body guard's own `413` and `400` on an alias carry them too. A request that gets the bare `404` (switch off, website gate) carries neither. OpenAPI, the guide, the catalog, `llms.txt` and `Link` headers name only the canonical paths |
| `api_public_cart_rate_per_min` | `api_public_token_rate_per_min` | The new key is read first; when it holds no valid number (an integer above 0) the old key is read, then the default |
| `api_public_cart_rows_per_ip_hour` | `api_public_new_rows_per_ip_hour` | The same |
| `api_public_cart_rows_global_hour` | `api_public_new_rows_global_hour` | The same |
| `RateLimit.check_cart_rows/1` | `RateLimit.check_new_rows/1` | Calls the new function; `@deprecated` |
| `Config.rate_limits/0` atoms `public_cart_per_min`, `cart_rows_ip_hour`, `cart_rows_global_hour` | `public_token_per_min`, `new_rows_ip_hour`, `new_rows_global_hour` | Renamed, no mirror |
| `Actor.cart_token_hash` | `Actor.client_token_hash` | Renamed, no mirror (no reader in a module's `lib/` is known; test fixtures that build an `Actor` need the new name) |
| a public tool that declares no `client_token` but has a `cart_token` property | `client_token: "cart_token"` on the tool | The executor reads `cart_token` as the client token, so such a module keeps its rate limit, idempotency scope and danger gate; `ToolLint` checks the tool the same way |
| output fields `claim_url`, `checkout_url`, `claim_token` and the value marker `/checkout/claim/` | `Tool.credentials` (or a `*_token` name) | Still treated as credentials: never stored for replay, redacted from approvals |
| error codes `cart_not_found` (404), `cart_locked` (409), `unsupported_source` (422), `insufficient_stock` (422) | `api_problems/0` of the module that answers them | Core answers them with the same `code`, `status`, `title` and advice as long as no enabled module declares the code |

Nothing deletes or migrates the old settings rows. The first save of Settings -> API writes the values in effect under the **new** keys and leaves the old rows alone, so a rollback still finds them.

Two names stay for good because a migration would be needed to remove them: the confirmations table column is `cart_token_hash` (V220, shipped in 2.63.0), and `PhoenixKit.API.Confirm.Confirmation` maps its `client_token_hash` field onto it with `source:`. Renaming the column is a question for the owner of the schema.

The segment that names the public audience in the paths is one constant (`PhoenixKit.API.Paths.public_segment/0`), so a different public prefix is a one-line change.

## Known limitations

These are deliberate for now; a module author or an operator should know them.

- **A personal key is as strong as its owner's account.** It acts with the owner's rights at the time of each request, so it is as safe as the way into the account: a reset of the password by someone else lets that someone create keys (see "Personal keys"). The expiry ceiling and the right to revoke bound it; nothing else does.
- **Lowering `api_personal_key_max_days` does not shorten issued keys**, and `api_personal_key_max_count` does not remove keys over a lowered limit; both apply to new keys and rotations.
- **Settings -> API changes need only the `api` permission.** The Owner-or-creator rule applies to keys and service users. The switches, rate limits, hidden tools, allowed MCP origins, confirmation thresholds and approval TTLs are global, and anyone who holds `api` can change them for every key, the Owner's included. The Admin role does not get `api` by default, so only an Owner's explicit grant widens this. Grant `api` accordingly; every change is an entry in the Activity log with the person as actor.
- **Dangerous public calls are not deduplicated.** A key that repeats a dangerous call while its code is live gets the same code back; a public caller (a client token) gets a new confirmation row for every call. The rows are bounded only by the public rate-limit buckets (per client token and per network), and unused codes are deleted an hour after they ran out.
- **`ctx.base_url` and `ctx.hosts` follow the `Host` header** unless the host app configures `:api_request_context` (`config :phoenix_kit, :api_request_context, {MyApp.ApiContext, :resolve}`). They are also stored on an approval and replayed when it runs. A module must not e-mail or otherwise send to a third party a link built from them unless the host configures a fixed host.
- **An idempotency lease expires after 120 seconds** (`api_idempotency_lease_seconds`). A retry with the same key and the same body after that takes the row over while the first handler may still be running; the first handler's writes are done, only its stored answer is lost. Make long writes idempotent by themselves (`external_ref`, see above).
- **`PhoenixKit.Activity.log_many/2`** is for modules that write many entries at once. Core does not call it.
