# AGENTS.md

**PhoenixKit** - A foundation for building your Elixir Phoenix apps — SaaS, social networks, ERP systems, marketplaces, internal tools, AI-powered apps, community platforms, and more. Library-first architecture with Elixir/Phoenix/PostgreSQL, complete auth system with Magic Links, role-based access control (Owner/Admin/User), built-in admin dashboard, daisyUI 5 theme system, professional versioned migrations, layout integration with parent apps.


## Development Workflow

```
# 1. Make changes

# 2. Format code
mix format

# 3. Compile
mix compile

# 4. Check types
mix credo --strict
```

## Pre-commit commands

Always run before git commit:

```
# 1.
mix precommit

# 2. Fix problems

# 3. Analyze current changes
git diff
git status

# 4. Make commit
```


## Development Commands

### Setup and Dependencies

- `mix setup` - Complete project setup
- `mix deps.get` - Install Elixir dependencies only

### Database Operations

- `mix ecto` - Print list of ecto commands

### Testing & Code Quality

PhoenixKit has two levels of tests:

1. **Unit tests** (`test/phoenix_kit/`, `test/modules/`) — Pure logic, no DB required
2. **Integration tests** (`test/integration/`) — Real PostgreSQL via Ecto sandbox

#### Test database setup

```bash
mix test.setup    # Create DB + run migrations (first time)
mix test          # Run all tests (migrations run automatically via test_helper)
mix test.reset    # Drop + recreate DB if needed
```

The test DB (`phoenix_kit_test`) uses an embedded `PhoenixKit.Test.Repo` in `test/support/test_repo.ex`. Migrations are in `test/support/postgres/migrations/`. No parent app required.

**Without PostgreSQL:** If the test DB doesn't exist, integration tests are automatically excluded and unit tests still run. You'll see:
```
⚠  Test database "phoenix_kit_test" not found — integration tests will be excluded.
   Run `mix test.setup` to create the test database.
868 tests, 0 failures, 274 excluded
```

#### Test commands

- `mix test` — Run all tests (unit + integration if DB available)
- `mix test test/integration/` — Run only user integration tests
- `mix test test/modules/publishing/integration/` — Run only publishing integration tests
- `mix format` — Format code
- `mix credo --strict` — Static analysis
- `mix dialyzer` — Type checking
- `mix quality` — Run all quality checks
- `mix quality.ci` — Run all quality checks for CI (strict formatting check)

#### Writing new integration tests

Use `PhoenixKit.DataCase` for tests that need the database. Tests using `DataCase` are automatically tagged `:integration` and excluded when the DB is unavailable.

```elixir
defmodule PhoenixKit.Integration.MyTest do
  use PhoenixKit.DataCase, async: true

  test "example" do
    {:ok, user} = PhoenixKit.Users.Auth.register_user(%{
      email: "test@example.com",
      password: "ValidPassword123!"
    })
    assert user.uuid
  end
end
```

#### Test infrastructure files

- `test/support/test_repo.ex` — `PhoenixKit.Test.Repo` (Ecto repo for tests)
- `test/support/data_case.ex` — `PhoenixKit.DataCase` (sandbox setup, `:integration` tag)
- `test/support/postgres/migrations/` — Migration wrapper calling `PhoenixKit.Migrations.up()`
- `config/test.exs` — DB config, sandbox pool, repo wiring

### Code Search

- Use `rg` (ripgrep) for text/regex/strings/comments
- Use `ast-grep` for structural patterns/function calls/refactoring

**Prefer `ast-grep` over text-based grep for structural code searches.**

```bash
ast-grep --lang elixir --pattern 'load_filter_data($$$)' lib/
ast-grep --lang elixir --pattern 'def $FUNC($$$ARGS) do $$$BODY end' lib/
```


## Pull requests

### CI/CD

GitHub Actions on push to `main`, `dev`, `claude/**` and all PRs. Checks: formatting, credo, dialyzer, compilation (warnings as errors), dependency audit, tests (with PostgreSQL).

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

### Version Management

**Current versions** (check dynamically):

```bash
# Package version
mix run --eval "IO.puts Mix.Project.config[:version]"

# Migration version (highest vN file)
ls lib/phoenix_kit/migrations/postgres/v*.ex | sed 's/.*\/v\([0-9]*\)\.ex/\1/' | sort -rn | head -1
```

Updates require: `mix.exs` (@version), `CHANGELOG.md`. Run `mix compile`, `mix test`, `mix format`, `mix credo --strict` before committing.

> **CHANGELOG ownership:** entries in `CHANGELOG.md` are written by the project maintainer, not by agents. If you bump `@version` and the CHANGELOG hasn't caught up yet, that's intentional — flag the gap and stop. Do not auto-write entries.

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`). See `dev_docs/pull_requests/README.md`.

Severity levels for review findings:

- `BUG - CRITICAL` — Will cause crashes, data loss, or security issues
- `BUG - HIGH` — Incorrect behavior that affects users
- `BUG - MEDIUM` — Edge cases, minor incorrect behavior
- `IMPROVEMENT - HIGH` — Significant code quality or performance issue
- `IMPROVEMENT - MEDIUM` — Better patterns or maintainability
- `NITPICK` — Style, naming, minor suggestions

### Publishing commands

- `mix hex.build`
- `mix hex.publish`
- `mix docs`


## Database

- All schemas use `@primary_key {:uuid, UUIDv7, autogenerate: true}`
- **New migrations must use** `uuid_generate_v7()` (NOT `gen_random_uuid()`)
- The migration system uses Oban-style versioned migrations (see `lib/phoenix_kit/migrations/postgres/`)


## Integrations System

Centralized management of external service connections (OAuth, API keys, bot tokens).

**Architecture:**
- `lib/phoenix_kit/integrations/integrations.ex` — Main context (CRUD, OAuth flow, credentials, validation)
- `lib/phoenix_kit/integrations/providers.ex` — Provider registry (Google, OpenRouter built-in; extensible via modules)
- `lib/phoenix_kit/integrations/oauth.ex` — Generic OAuth 2.0 flow with CSRF state protection
- `lib/phoenix_kit/integrations/events.ex` — PubSub events for real-time UI updates
- `lib/phoenix_kit_web/live/settings/integrations.ex` — List page (cards with status, actions)
- `lib/phoenix_kit_web/live/settings/integration_form.ex` — Add/edit page (OAuth flow, test connection)
- `lib/phoenix_kit_web/components/core/integration_picker.ex` — Reusable picker component for module UIs

**Storage:** Uses existing `phoenix_kit_settings` table with `value_json` JSONB. Keys follow `integration:{provider}:{name}` convention (e.g., `integration:google:default`). **Consumers reference connections by the storage row's UUID** — that uuid is the stable handle that survives renames.

**Auth types:** `:oauth2` (Google, Microsoft), `:api_key` (OpenRouter, Stripe), `:key_secret` (AWS), `:bot_token` (Telegram, Discord), `:credentials` (SMTP, databases).

**Named connections:** Multiple connections per provider (e.g., `google:default`, `google:personal`). Use `add_connection/3`, `remove_connection/2`, `rename_connection/3`, `list_connections/1`. **Names are pure user-chosen labels** — `"default"` is no longer privileged; any connection can be renamed or removed. Connection names must match `[a-zA-Z0-9][a-zA-Z0-9\-_]*`.

**API shape (uuid-strict).** Every operation past row creation takes the row's `uuid`. The structural rule: `"integration:{provider}:{name}"` storage-key construction happens only inside `add_connection/3` (creation) and module-side `migrate_legacy/0` migrators (translation of legacy data). Every other public API takes a uuid:

- Mutating: `save_setup(uuid, attrs, actor)`, `disconnect(uuid, actor)`, `remove_connection(uuid, actor)`, `rename_connection(uuid, new_name, actor)`, `record_validation(uuid, result)`
- OAuth: `authorization_url(uuid, redirect_uri, ...)`, `exchange_code(uuid, code, ...)`, `refresh_access_token(uuid)`
- HTTP: `authenticated_request(uuid, method, url, opts)`, `validate_connection(uuid, actor)`
- Read shims (dual-input — uuid OR `provider:name` string — for legacy data walks): `get_integration/1`, `get_credentials/1`, `connected?/1`
- Migration primitive: `find_uuid_by_provider_name/1` (string → uuid for `migrate_legacy/0` callbacks)

A corrupted JSONB `provider`/`name` field cannot leak into a new storage key because no public write API derives keys from JSONB. Provider+name are sourced only from the row's `key` column when needed for display.

**Consumer pattern (uuid-everywhere):** Modules that depend on an integration store its uuid on their own records (e.g. `phoenix_kit_ai_endpoints.integration_uuid`, `document_creator_settings.google_connection`). Lookups go through `get_integration_by_uuid/1` or `get_credentials/1` (dual-input). The system does **not** silently fall back to "any connected row of this provider" — consumers must specify which integration they want.

**Validation:** `validate_connection/2` tests if credentials work — calls provider's userinfo endpoint (OAuth) or validation endpoint (API key/bot token). Results stored in integration data. Successful validation flips `status` to `"connected"` and rewrites `connected_at` on every successful re-test (matches the OAuth `exchange_code/4` path; the form's "Connected N ago" reading bumps when the operator re-tests after fixing credentials). `last_validated_at` is rewritten unconditionally on every validation attempt, success or failure.

**Events (PubSub):** Topic `"phoenix_kit:integrations"`. Events: `integration_setup_saved`, `integration_connected`, `integration_disconnected`, `integration_validated`, `integration_connection_added`, `integration_connection_removed`, `integration_connection_renamed`.

**Module callbacks:** `required_integrations/0` — declares provider keys this module needs. `integration_providers/0` — contributes custom provider definitions to the registry.

**Legacy migration:** Each module that has legacy data implements an optional `migrate_legacy/0` callback on `PhoenixKit.Module`. Host apps call `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0` from `Application.start/2`; the orchestrator walks every registered module and invokes its callback (idempotent per module, errors caught + logged, never crashes the boot). Each module owns its own data shape — core provides primitives like `Integrations.find_uuid_by_provider_name/1` that modules use in their migrators. The pre-uuid `Integrations.run_legacy_migrations/0` is now a deprecated shim that delegates to the orchestrator.

**Plan:** `dev_docs/plans/integrations-system.md`


## Core Form Components

`PhoenixKitWeb.Components.Core.{Input, Select, Textarea, Checkbox}` are the canonical form primitives. Use them over raw `<input>`/`<select>`/`<textarea>` markup in new code — they handle `phx-feedback-for`, gettext-translated error display, label wiring, and daisyUI styling for you. The existing `lib/phoenix_kit_web/users/user_form.html.heex` is the canonical reference usage.

- All four accept a `class` attr that merges onto the **styled element** itself (the `<input>` / daisyUI `<label class="select">` / `<textarea>` / `<input type="checkbox">`) — pass daisyUI modifiers here: `input-sm`, `select-primary`, `checkbox-accent`, or project-specific focus styles like `transition-colors focus:input-primary`.
- `<.input>` additionally has a `wrapper_class` attr that goes to the outer `<div phx-feedback-for>` — this is the role the `class` attr used to play before the convention was aligned with the Phoenix 1.7 generator (`class` → input element). No in-tree caller used the old behavior, but external consumers who did should switch to `wrapper_class`.
- FormField binding is preferred: `<.input field={@form[:email]} type="email" label="Email" />`. The component dispatches on `%Phoenix.HTML.FormField{}` to pull id / name / value / errors in one shot. The raw `name=` + `value=` form still works for cases where field names are dynamic (import wizards, custom field loops in user_form).

## Multilang Form Components

`PhoenixKitWeb.Components.MultilangForm` provides the form-level translation toolkit: `<.multilang_tabs>`, `<.multilang_fields_wrapper>`, `<.translatable_field>`, plus helpers `mount_multilang/1`, `handle_switch_language/2`, `merge_translatable_params/4`. Forms that edit translatable content `import PhoenixKitWeb.Components.MultilangForm` and call `mount_multilang(socket)` in `mount/3`.

### Wrapper scope rule

`<.multilang_fields_wrapper>` wraps translatable fields *only*. Everything else — pricing, classification, status, actions — renders as a sibling **outside** the wrapper. This is load-bearing: the wrapper's `id` includes `@current_lang`, so a language switch changes the ID and morphdom re-mounts everything inside. If you put non-translatable fields inside, they get re-mounted on every switch (churn + focus loss + lost input state). Keep the wrapper small — in practice, the name + description `<.translatable_field>` calls are all that belongs inside.

### Language switching: client-side visibility + trailing debounce

`mount_multilang/1` seeds the multilang assigns and attaches a `:handle_info` hook via `Phoenix.LiveView.attach_hook/4` that receives the debounced timer message. The flow:

1. User clicks a language tab → `switch_lang_js/2` runs a composed `%JS{}`: pushes `"switch_language"` **and** immediately toggles `hidden` on the two sibling divs client-side — `add_class` on `[data-translatable=fields]`, `remove_class` on `[data-translatable=skeletons]`. The skeleton is visible at `t=0`, no round-trip delay.
2. `handle_switch_language/2` cancels any pending timer, schedules a new `Process.send_after(self(), {:__multilang_apply_lang__, lang}, 150)`, stores the timer ref in the process dictionary (not socket assigns — avoids triggering phantom render+diff cycles), and returns the socket **unchanged**. The server does not touch the wrapper's class state — so nothing can fight the JS toggles on the client.
3. Rapid clicks re-enter step 2 — timer is cancelled and rescheduled; the JS toggles are idempotent. Only the final click's lang reaches step 4.
4. 150ms after the last click: the timer fires, the hook intercepts `{:__multilang_apply_lang__, lang}`, calls `handle_multilang_apply_lang/2` which sets `:current_lang = lang`, and returns `{:halt, socket}` so the consumer never sees the message.
5. Wrapper re-renders with new lang in its ids (skeleton id, fields id, and the translatable inputs' `lang_data`). morphdom sees the id change and **replaces both sibling divs** — the new skeleton div is re-rendered with `class="hidden …"` (its default), the new fields div is re-rendered without `hidden` and with the new-language content. The skeleton is hidden again, the fields are back, and everything else on the form (outside the wrapper) is untouched.

Why client-side and not server-driven: the skeleton has to appear **before** any round-trip to feel responsive. A server-driven visibility flag needs the `JS.push` to reach the server, the server to re-render, and the diff to arrive at the client — visible delay on slow connections, and on localhost the window is so brief you can barely perceive it. The client-side toggle shows the skeleton at `t=0`; the server only owns the final `current_lang` commit.

The `attach_hook` approach means consumers **don't need a `handle_info` clause** — the library handles the timer message transparently. There's a graceful fallback for LiveComponent sockets (where `attach_hook` raises `ArgumentError`): rescue + return socket unchanged; those consumers can add the clause manually if they ever appear.

The wrapper accepts a `switching_lang` attr and `mount_multilang/1` seeds `:switching_lang = false`, purely as a backwards-compat no-op — consumer templates that already pass `switching_lang={@switching_lang}` keep resolving. The wrapper doesn't read the value.

### Translatable fields

`<.translatable_field>` takes the raw changeset via `changeset={@changeset}` (not FormField) because its behavior changes with the active tab — primary-language input vs. secondary-language JSONB-backed input with different `name` attributes. When using `<.translatable_field>` alongside component-style inputs, a form LV keeps **both** `:changeset` (for translatable_field) and `:form = to_form(changeset)` (for `<.input>` / `<.select>`) in sync via a private helper called from mount / validate / save-error paths.

## Documentations

Built-in Dashboard Features
**Full documentation:** `lib/phoenix_kit/dashboard/README.md` (tabs, subtabs, badges, context selectors, and more).


## Activity Feed

Core module at `lib/phoenix_kit/activity/` — tracks business-level actions across the platform. Admin UI at `/admin/activity` with detail pages at `/admin/activity/:uuid`.

### Logging an activity

```elixir
PhoenixKit.Activity.log(%{
  action: "post.created",       # required — dotted format: resource.verb
  module: "posts",              # which module this belongs to (filterable)
  mode: "manual",               # "manual" (user/admin clicked) or "auto" (system triggered)
  actor_uuid: user.uuid,        # who did it
  resource_type: "post",        # what kind of thing was acted on
  resource_uuid: post.uuid,     # the thing's UUID
  target_uuid: nil,             # optional: who was affected (e.g., follow target)
  metadata: %{                  # flexible JSONB — shown in detail page
    "actor_role" => "user",     # "user" or "admin"
    "title" => post.title
  }
})
```

### Helper for profile/field changes

For changes with from/to diffs, use `log_user_change/4` — auto-extracts `field_from`/`field_to` pairs from an Ecto changeset:

```elixir
# User updates own profile (defaults: mode "manual", actor_role "user")
PhoenixKit.Activity.log_user_change("user.profile_updated", user, changeset)

# Admin updates a user (override actor and role)
PhoenixKit.Activity.log_user_change("user.profile_updated", user, changeset,
  actor_uuid: admin.uuid,
  target_uuid: user.uuid,
  mode: "manual",
  actor_role: "admin"
)
```

Skips logging if nothing actually changed. The index page summarizes diffs as "username, email updated"; the detail page shows full `_from`/`_to` values.

### Conventions

| Field | Convention |
|-------|-----------|
| `action` | `resource.verb` — e.g., `user.registered`, `post.created`, `comment.liked` |
| `module` | Module key string: `"users"`, `"posts"`, `"comments"`, `"connections"` |
| `mode` | `"manual"` = person clicked a button; `"auto"` = system/token triggered; `"cron"` = scheduled; `"script"` = one-off |
| `actor_role` | `"admin"` or `"user"` — baked into metadata at log time (captures role at time of action) |
| `resource_type` | Same as `module` for most cases, but can differ (e.g., module `"users"`, resource_type `"user"`) |

### Existing user actions

| Action | Mode | Logged in |
|--------|------|-----------|
| `user.registered` | manual | `registration.ex` |
| `user.created` | manual | `user_form.ex` (admin) |
| `user.email_confirmed` | auto/manual | `auth.ex`, `magic_link.ex`, `oauth.ex`, `users.ex` |
| `user.email_unconfirmed` | manual | `users.ex` |
| `user.password_changed` | manual | `auth.ex` (user + admin paths) |
| `user.password_reset` | auto | `auth.ex` |
| `user.email_changed` | auto | `auth.ex` (stores old_email/new_email) |
| `user.profile_updated` | manual | `auth.ex` (user), `user_form.ex` (admin) — uses `log_user_change` |
| `user.avatar_changed` | manual | `user_settings.ex` (user), `user_form.ex` (admin) |
| `user.status_changed` | manual | `users.ex` (admin) |
| `user.deleted` | manual | `auth.ex` (stores deleted_email) |
| `user.roles_updated` | manual | `user_form.ex`, `users.ex` (admin) — stores roles_from/to, added/removed |
| `user.note_created` | manual | `auth.ex` |
| `user.note_deleted` | manual | `auth.ex` |

### External modules

External modules should guard with `Code.ensure_loaded?/1`:

```elixir
if Code.ensure_loaded?(PhoenixKit.Activity) do
  PhoenixKit.Activity.log(%{action: "comment.created", module: "comments", ...})
end
```

### Cleanup

Configurable via `activity_retention_days` setting (default: 90 days). `PhoenixKit.Activity.PruneWorker` runs daily via Oban.


## Notifications

Per-user inbox driven by the activity log. Whenever `PhoenixKit.Activity.log/1` records an entry with a `target_uuid` that differs from `actor_uuid`, a row is inserted into `phoenix_kit_notifications` for the target user. Admins still use `/admin/activity` for audit — they do NOT receive notifications, so high-volume systems don't drown them.

Global kill switch: `notifications_enabled` setting (default `"true"`). When `"false"`, `maybe_create_from_activity/1` is a no-op.

### Generating notifications

Nothing to do in caller code. As soon as an activity meets the rule (`target_uuid != nil and target_uuid != actor_uuid` and the feature is enabled), the hook in `lib/phoenix_kit/activity/activity.ex` fans out to `PhoenixKit.Notifications.maybe_create_from_activity/1`. Each row is a `(activity_uuid, recipient_uuid)` pair with independent `seen_at` / `dismissed_at`.

If you want a notification without a matching activity log entry, create the activity first and let the hook do the rest — don't insert directly into `phoenix_kit_notifications`.

### Rendering

`PhoenixKit.Notifications.Render.render(notification)` maps the notification's preloaded activity to `%{icon, text, link, actor_uuid}`. Unknown actions fall back to the raw action string — safe default.

### Public API (on `PhoenixKit.Notifications`)

- `list_for_user(user_uuid, opts)` — `:page`, `:per_page`, `:status (:unread|:all)`, `:include_dismissed`
- `recent_for_user(user_uuid, limit \\ 10)` — bell dropdown
- `count_unread(user_uuid)` — badge
- `mark_seen(user_uuid, uuid)` / `mark_all_seen(user_uuid)`
- `dismiss(user_uuid, uuid)` / `dismiss_all(user_uuid)`
- `get_notification(user_uuid, uuid)` — scoped to recipient
- `enabled?/0`, `retention_days/0`, `prune/1`

All writes broadcast on `PhoenixKit.Notifications.Events.topic_for_user(user_uuid)` (`"phoenix_kit:notifications:<user_uuid>"`) so LiveViews stay in sync:
- `{:notification_created, n}`
- `{:notification_seen, n}`
- `{:notification_dismissed, n}`
- `{:notifications_bulk_updated, :seen | :dismissed}`

### UI

There is no PhoenixKit-owned notifications page — the feature is a pure backend + embeddable bell.

**Bell** — `PhoenixKitWeb.Live.NotificationsBell`, a sticky nested LiveView. Not mounted anywhere by default; parent apps render it where they have a user-facing header:

```heex
<%= Phoenix.Component.live_render(@socket, PhoenixKitWeb.Live.NotificationsBell,
      id: "pk-notifications-bell",
      sticky: true,
      session: %{"user_uuid" => @current_user.uuid}) %>
```

The bell owns its own PubSub subscription so the badge and dropdown refresh live. Clicking a notification row marks it seen and navigates to `Render.render(n).link` when one is set; if `link` is `nil`, the dropdown just refreshes.

"Seen" is only set on explicit user action (clicking a row or "Mark all seen"). Opening the dropdown does NOT auto-mark seen.

### Per-user preferences

Each user can mute notification *types* (not individual actions) from the `UserSettings` LiveComponent's Notifications section. Preferences persist in `users.custom_fields["notification_preferences"]` as `%{"posts" => true, "account" => false, …}`. No migration — reuses the existing V18 JSONB column.

The types registry lives in `PhoenixKit.Notifications.Types`. Core types: `"account"`, `"posts"`, `"comments"`. External modules contribute their own via the optional `notification_types/0` callback on `PhoenixKit.Module`:

```elixir
@impl PhoenixKit.Module
def notification_types do
  [%{
    key: "reviews",
    label: "Reviews",
    description: "When someone leaves you a review",
    actions: ["review.submitted", "review.edited"],
    default: true
  }]
end
```

`Types.list/0` merges core + discovered modules; the toggle appears in every user's UserSettings automatically. The filter in `maybe_create_from_activity/1` calls `PhoenixKit.Notifications.Prefs.user_wants?(target_uuid, action)`, which resolves the action to its type (`Types.type_for_action/1`) and checks the recipient's `custom_fields`. **Fail-open**: unknown actions, missing prefs, or lookup errors all return `true` — a notification is never silently dropped because of a malformed row.

### Custom display (metadata override)

`Render.render/1` honors three conventional metadata keys before falling back to the action lookup. Any `Activity.log/1` caller can ship custom text/icon/link without editing PhoenixKit:

```elixir
Activity.log(%{
  action: "review.submitted",
  actor_uuid: alice.uuid,
  target_uuid: bob.uuid,
  metadata: %{
    "notification_text" => "Alice left you a 5-star review.",
    "notification_icon" => "hero-star",
    "notification_link" => "/reviews/#{review.uuid}"
  }
})
```

Any key can be absent — Render falls back to `icon_and_text/2` and `link_for/1` for the missing parts.

### Extensibility cheat sheet

| Scenario | Developer work | PhoenixKit work |
|---|---|---|
| New action in an existing type | one `Activity.log/1` call | None (prefix is already covered) or add to the type's `actions` list |
| New type (category of actions) | implement `notification_types/0` (~10 lines) | None |
| Custom text / icon / link | set three metadata keys at the call site | None |

### Cleanup

`PhoenixKit.Notifications.PruneWorker` runs daily (`"0 4 * * *"`). Retention is driven by `notifications_retention_days` (falls back to `activity_retention_days`, default 90). Cascading FK deletes also remove notifications when the underlying activity is pruned.


## MediaBrowser Component

Embeddable media management UI — full folder tree, grid/list view, upload, search, selection tools, drag-drop, trash bucket. Lives at `lib/phoenix_kit_web/components/media_browser.ex` (+ `.html.heex`). Used by the admin page (`/admin/media`) and any parent LiveView that needs media picking or browsing.

### One-line embed

Use the Embed macro. It injects the upload setup (`on_mount`), the `"validate"` upload-channel stub, and the `handle_info` delegator for MediaBrowser messages:

```elixir
defmodule MyAppWeb.MediaPage do
  use MyAppWeb, :live_view
  use PhoenixKitWeb.Components.MediaBrowser.Embed

  def mount(_params, _session, socket), do: {:ok, socket}
end
```

Template:

```heex
<.live_component
  module={PhoenixKitWeb.Components.MediaBrowser}
  id="media-browser"
  parent_uploads={@uploads}
/>
```

`parent_uploads={@uploads}` is required (the component renders a hidden `<.live_file_input>` from the parent's upload config). That's a LiveView constraint — `allow_upload` must live on the parent socket.

### Click behavior — three modes

The `click_file` handler picks one branch in this order:

1. `select_mode` already on (anywhere, any caller) → toggle this file in/out of the selection set, stay in selection mode.
2. `admin={true}` → `push_navigate` to `/admin/media/:uuid` (the rich admin detail page with delete / restore / edit / regenerate).
3. `view_path="/some/path/:uuid"` → `push_navigate` to that path with `:uuid` substituted by the file's uuid. Use this to send non-admin users to a read-only viewer (e.g. `PhoenixKitWeb.Live.Media.View` at `/media/:uuid`).
4. Default — enter `select_mode` and toggle the clicked file in. Picker behaviour.

So a non-admin caller has two choices:
- Pure picker (no `admin`, no `view_path`) — clicking selects.
- Viewer (no `admin`, set `view_path="/media/:uuid"`) — clicking opens the read-only viewer.

The built-in viewer at `/media/:file_uuid` is mounted in the authenticated `live_session` — any logged-in user can reach it. It renders the file (image / video / PDF / icon fallback) plus basic metadata (type, size, MIME, uploader, uploaded-at) and a Download button. No admin actions.

### Other useful attrs

- `scope_folder_id` — constrain the whole browser to a virtual root folder. Trash, folder tree, uploads, move — all honor the scope.
- `on_navigate={:navigate}` — controlled mode. Component emits `{MediaBrowser, id, {:navigate, params}}` to the parent on folder/search/page changes so the parent can `push_patch` the URL. The parent must then feed URL params back via `send_update(..., nav_params: ...)`. See `lib/phoenix_kit_web/live/users/media.ex` for the reference wiring.
- `initial_params` — apply URL params on first render to avoid a flash of the root view.

### Selection actions (built-in)

When items are selected, a `…` dropdown appears in the header with Download + Delete. Download pushes a `download_files` event that the `MediaDragDrop` hook (in `priv/static/assets/phoenix_kit.js`) consumes — each entry is dispatched as a staggered `<a download>` click. Delete moves files to trash (or permanently removes if the trash view is active) and deletes folders.

### Manual wiring (if not using Embed)

```elixir
def mount(_params, _session, socket) do
  {:ok, PhoenixKitWeb.Components.MediaBrowser.setup_uploads(socket)}
end

def handle_event("validate", _params, socket), do: {:noreply, socket}

def handle_info({PhoenixKitWeb.Components.MediaBrowser, _, _} = msg, socket) do
  PhoenixKitWeb.Components.MediaBrowser.handle_parent_info(msg, socket)
end
```

The Embed macro injects these last via `@before_compile`, so user-defined clauses for other events/messages still match first.

### Files

- `lib/phoenix_kit_web/components/media_browser.ex` — LiveComponent
- `lib/phoenix_kit_web/components/media_browser.html.heex` — template
- `lib/phoenix_kit_web/components/media_browser/embed.ex` — the `use`-able macro
- `lib/modules/storage/storage.ex` — backing context (folders, files, trash, variants)
- `priv/static/assets/phoenix_kit.js` — `MediaDragDrop` and `FolderDropUpload` hooks


## Guidelines

### External Module Auto-Discovery

When extracting modules to standalone packages, the package's `mix.exs` **must** include `:phoenix_kit` in `extra_applications`:

```elixir
def application do
  [extra_applications: [:logger, :phoenix_kit]]
end
```

Without this, `PhoenixKit.ModuleDiscovery` won't find the module and routes will return 404. See `phoenix_kit_hello_world` for the template.

### Tailwind CSS Scanning for External Modules

External modules with UI must implement `css_sources/0` returning their OTP app name:

```elixir
@impl PhoenixKit.Module
def css_sources, do: [:phoenix_kit_my_module]
```

CSS source discovery is **automatic at compile time**. The `:phoenix_kit_css_sources` compiler (in `lib/mix/tasks/compile.phoenix_kit_css_sources.ex`) discovers all modules with `css_sources/0`, resolves their paths (path deps vs hex deps), and writes `assets/css/_phoenix_kit_sources.css`. The parent app's `app.css` imports this generated file.

**Parent app setup (one-time, handled by `mix phoenix_kit.install`):**
1. Add `:phoenix_kit_css_sources` to `compilers:` in `mix.exs` (before `:phoenix_live_view`)
2. `app.css` must have `@import "./_phoenix_kit_sources.css";`

After setup, adding or removing modules is zero-config — the compiler regenerates on each compilation.

### JavaScript Hooks for External Modules

PhoenixKit provides JS hooks (RowMenu, TableCardView, SortableGrid, etc.) in `priv/static/assets/phoenix_kit.js`. This file defines `window.PhoenixKitHooks` which the parent app spreads into LiveSocket:

```javascript
hooks: { ...window.PhoenixKitHooks, ...colocatedHooks }
```

**Parent app setup (handled by `mix phoenix_kit.install`):**
1. `phoenix_kit.js` is copied to `priv/static/assets/vendor/`
2. A `<script>` tag is added to the root layout **before** `app.js`:
   ```html
   <script src={~p"/assets/vendor/phoenix_kit.js"}></script>
   ```

**On update (`mix phoenix_kit.update`):** The JS file is automatically refreshed to keep hooks in sync.

External modules register custom hooks via inline `<script>` tags on `window.PhoenixKitHooks`. See the hello_world template for examples.

### PhoenixKit Layout Guidelines

PhoenixKit uses its own layout wrapper component instead of the standard Phoenix `Layouts.app`:

- **Always** begin PhoenixKit LiveView templates with `<PhoenixKitWeb.Components.LayoutWrapper.app_layout ...>` which wraps all inner content
- Required attribute: `flash`
- Recommended attributes: `page_title`, `current_path`, `project_title`, `phoenix_kit_current_scope`
- Optional: `current_locale`
- Pass the `@url_path` assign (set by PhoenixKit's on_mount hook) into the `current_path` attribute — the component attribute is named `current_path`, not `url_path`

Example:

```heex
<PhoenixKitWeb.Components.LayoutWrapper.app_layout
  flash={@flash}
  page_title={@page_title}
  current_path={@url_path}
  project_title={@project_title}
  phoenix_kit_current_scope={@phoenix_kit_current_scope}
  current_locale={assigns[:current_locale]}
>
  <!-- Your content here -->
</PhoenixKitWeb.Components.LayoutWrapper.app_layout>
```

For the complete list of component attributes, see `lib/phoenix_kit_web/components/layout_wrapper.ex` — only `flash` is strictly required; everything else has sensible defaults.

### URL Prefix and Navigation

**NEVER hardcode PhoenixKit paths.** Use configurable prefix helpers:

1. `PhoenixKit.Utils.Routes.path/1` - Prefix-aware paths in Elixir code (alias or import first)
2. `<.pk_link>` - Prefix-aware link component for templates

```elixir
# In LiveView/Controller - alias Routes first
alias PhoenixKit.Utils.Routes
push_navigate(socket, to: Routes.path("/dashboard"))
url = Routes.url("/users/confirm/#{token}")
```

```heex
<.pk_link navigate="/dashboard">Dashboard</.pk_link>
<.pk_link patch="/dashboard/settings">Settings</.pk_link>
<.pk_link_button navigate="/admin/users" variant="primary">Manage Users</.pk_link_button>
```

| Scenario                | Use                                      |
|-------------------------|------------------------------------------|
| Template links          | `<.pk_link navigate="/path">` or `patch` |
| LiveView navigate/patch | `Routes.path("/path")`                   |
| Controller redirect     | `Routes.path("/path")`                   |
| Email URLs              | `Routes.url("/path")`                    |


## Parent project

### Installing commands

- `mix phoenix_kit.install` - Install PhoenixKit (use `--help` for options)
- `mix phoenix_kit.update` - Update existing installation (use `--help`)
- `mix phoenix_kit.status` - Shows comprehensive PhoenixKit installation status
- `mix phoenix_kit.gen.migration` - Generate custom migration files

Features: versioned migrations, database tables prefix support, idempotent operations, PostgreSQL validation, production mailer templates.

### External module route discovery

Routes from external PhoenixKit modules are auto-discovered at compile time via `ModuleDiscovery` beam scanning. The host router automatically recompiles when module deps are added or removed — the `phoenix_kit_routes()` macro injects `__mix_recompile__?/0` into the host router with a hash of the discovered module set. No manual config needed.

**Two routing patterns:**

1. **Single page** — add `live_view: {MyModule.Web.IndexLive, :index}` to `admin_tabs/0` or `settings_tabs/0`. The route is auto-generated. No route module needed. Used by: hello_world, sync, catalogue, document_creator, emails (settings), user_connections, legal.

2. **Multi-page** — implement `route_module/0` returning a module with `admin_routes/0` and `admin_locale_routes/0`. Required for sub-routes like `/new`, `/edit`, `/:id`. Do NOT set `live_view:` on the main tab when using a route module. Used by: ai, entities, publishing, newsletters.

**Important:** if a parent tab and subtab share the same path and both have `live_view:`, the core deduplicates by path (first wins). But avoid this pattern — only set `live_view:` on one tab per unique path.

If auto-discovery fails, register route modules explicitly as a fallback:

```elixir
# config/config.exs
config :phoenix_kit,
  route_modules: [PhoenixKitEntities.Routes]
```


## TODOs

Workspace-tracked items that aren't ready for inline `# TODO`
comments in `lib/` (per the playbook, those should be resolved or
moved here).

### Component test coverage for `phoenix_kit_web/components/core/`

There are no tests under `test/phoenix_kit_web/components/core/` —
the directory doesn't exist. Several components in
`lib/phoenix_kit_web/components/core/` are now non-trivial and would
benefit from `Phoenix.LiveViewTest`-style render-and-assert
coverage:

- `<.draggable_list>` — recently grew a `:draggable` attr that
  conditionally hides the SortableJS hook + `cursor-grab` styling.
  Both branches need at least one rendered-HTML assertion.
- `<.table_default>` — recently grew `:on_reorder` / `:reorder_scope`
  / `:reorder_group` / `:item_id` attrs that wire the card-view
  container as a sortable target. With- and without-DnD branches
  need rendered-HTML assertions to pin `phx-hook="SortableGrid"`,
  `data-sortable-*`, `data-id`, `class="sortable-item"`, and the
  drag-handle footer row.
- `<.input>`, `<.select>`, `<.textarea>`, `<.checkbox>` — the
  canonical form primitives; surveyed for inline error rendering,
  daisyUI variant classes, and the FormField vs raw `name=`/`value=`
  dispatch.
- `<.flash>`, `<.modal>` (if either's complexity has grown).

Surfaced 2026-05-02 by the C12 triage during the V108 / DnD core
work. Treated as out of scope for that PR (a single fixture in an
empty test dir is awkward); fold into a future component-coverage
sweep.

