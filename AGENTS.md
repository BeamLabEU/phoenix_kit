# AGENTS.md

**PhoenixKit** — foundation for building Elixir/Phoenix apps (SaaS, ERP, marketplaces, AI apps, community platforms). Library-first architecture with Phoenix/PostgreSQL: auth + Magic Links, role-based access (Owner/Admin/User), admin dashboard, daisyUI 5 themes, versioned migrations, layout integration with parent apps.

## Workflow

1. Make changes
2. `mix precommit` (runs format + compile + credo --strict)
3. Fix problems
4. `git diff` / `git status` → commit

## Development Commands

- `mix setup` — full project setup
- `mix deps.get` — deps only
- `mix ecto` — list ecto commands
- `mix format`, `mix credo --strict`, `mix dialyzer`, `mix quality`, `mix quality.ci`

### Tests

Two levels: **unit** (`test/phoenix_kit/`, `test/modules/` — no DB) and **integration** (`test/integration/`, `test/modules/*/integration/` — real PostgreSQL via Ecto sandbox).

```bash
mix test.setup    # create DB + run migrations (first time)
mix test          # run all (migrations auto via test_helper)
mix test.reset    # drop + recreate
```

Test DB `phoenix_kit_test` uses embedded `PhoenixKit.Test.Repo` (`test/support/test_repo.ex`). Migrations live in `test/support/postgres/migrations/`.

**Without PostgreSQL:** integration tests are auto-excluded; unit tests still run. `mix test` will print a banner and continue.

Use `PhoenixKit.DataCase` for tests needing the DB — auto-tags `:integration`.

```elixir
defmodule PhoenixKit.Integration.MyTest do
  use PhoenixKit.DataCase, async: true
  test "example" do
    {:ok, user} = PhoenixKit.Users.Auth.register_user(%{email: "test@example.com", password: "ValidPassword123!"})
    assert user.uuid
  end
end
```

`test/test_helper.exs` calls `PhoenixKit.Migration.ensure_current/2`. **Do not** swap in `Ecto.Migrator.run(repo, [{0, PhoenixKit.Migration}], :up, all: true)` — it goes silently stale (see `ensure_current/2` moduledoc).

### Code Search

- `rg` (ripgrep) — text/regex/strings/comments
- `ast-grep` — structural patterns; **prefer over text grep for code searches**

```bash
ast-grep --lang elixir --pattern 'load_filter_data($$$)' lib/
ast-grep --lang elixir --pattern 'def $FUNC($$$ARGS) do $$$BODY end' lib/
```

## Pull Requests

- **Branch:** core integrates on **`main`** — open PRs against `main` (`gh pr create --base main --head mdon:main`). The `dev` branch was **retired 2026-06-01**; do not target it. (Historical: core used `dev` as its integration branch until then.)
- **CI/CD:** the `.github/workflows/ci.yml` workflow is **manual-only** (`workflow_dispatch`) — the equivalent checks run locally via `mix precommit` / `mix quality.ci`. Checks: format, credo, dialyzer, compile (warnings as errors), deps audit, tests with PostgreSQL.
- **Commit messages:** start with `Add`, `Update`, `Fix`, `Remove`, `Merge`.
- **Version management:** `mix.exs` `@version` + `CHANGELOG.md`. Run `mix compile`, `mix test`, `mix format`, `mix credo --strict` before committing. Get current versions:
  ```bash
  mix run --eval "IO.puts Mix.Project.config[:version]"
  ls lib/phoenix_kit/migrations/postgres/v*.ex | sed 's/.*\/v\([0-9]*\)\.ex/\1/' | sort -rn | head -1
  ```
- **CHANGELOG entries:** agents write the entry against the bumped `@version` heading. Match the existing style (Added / Changed / Fixed / i18n sections, bullets sourced from PR scopes + post-merge review fixes).
- **PR reviews:** files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md` (always `CLAUDE_REVIEW.md` for me). Severity levels: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.
- **Publish:** `mix hex.build`, `mix hex.publish`, `mix docs`.

## Database

- Schemas use `@primary_key {:uuid, UUIDv7, autogenerate: true}`
- New migrations use `uuid_generate_v7()` (NOT `gen_random_uuid()`)
- Oban-style versioned migrations in `lib/phoenix_kit/migrations/postgres/`

## Integrations System

Centralized OAuth / API key / bot token / credential management. Full design: `dev_docs/plans/integrations-system.md`.

**Files:**
- `lib/phoenix_kit/integrations/integrations.ex` — main context (CRUD, OAuth, validation)
- `lib/phoenix_kit/integrations/providers.ex` — provider registry (Google, OpenRouter built-in)
- `lib/phoenix_kit/integrations/oauth.ex` — generic OAuth 2.0 with CSRF state
- `lib/phoenix_kit/integrations/events.ex` — PubSub events
- `lib/phoenix_kit_web/live/settings/integrations.ex` + `integration_form.ex` — admin UI
- `lib/phoenix_kit_web/components/core/integration_picker.ex` — reusable picker

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

**Legacy migration:** modules implement optional `migrate_legacy/0` on `PhoenixKit.Module`. Host apps call `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0` from `Application.start/2`. Idempotent per module; errors are caught and logged. The pre-uuid `Integrations.run_legacy_migrations/0` is now a deprecated shim.

## Core Form Components

`PhoenixKitWeb.Components.Core.{Input, Select, Textarea, Checkbox}` — canonical form primitives. Use over raw `<input>`/`<select>`/`<textarea>` in new code. They handle `phx-feedback-for`, gettext error display, label wiring, daisyUI styling. Reference: `lib/phoenix_kit_web/users/user_form.html.heex`.

- `class` attr → merges onto the **styled element** (input/label/textarea/checkbox). Pass daisyUI modifiers here: `input-sm`, `select-primary`, `checkbox-accent`, etc.
- `<.input>` also has `wrapper_class` → goes to the outer `<div phx-feedback-for>`. (Aligned with Phoenix 1.7 generator: `class` → input element, not wrapper.)
- Prefer FormField binding: `<.input field={@form[:email]} type="email" label="Email" />`. Raw `name=`/`value=` still works for dynamic field names.

## Core List-UI Components

The canonical toolkit for admin list views — DnD reorder, bulk-select, sort, strategy reorder, load-more pagination. All live in `lib/phoenix_kit_web/components/core/`. Reference call sites: `phoenix_kit_projects`' `projects_live.ex` / `tasks_live.ex` / `templates_live.ex`.

**Sortable** — `<.sortable_tbody enabled={…} event="reorder_x" id="…">` + `<.sortable_row item_id={uuid}>`. Replaces the bespoke `<tbody phx-hook="SortableGrid" data-sortable-* …>` boilerplate. `enabled={false}` omits the hook so DnD turns off cleanly when sort_by ≠ position. Pair with `<.drag_handle_cell>` + `<.drag_handle_header_cell>` (in `table_default.ex`) — those render the grip icon and the `.pk-drag-handle` selector the SortableGrid hook reads. Rows inherit a named `group/row` Tailwind marker so the handle can hide-until-row-hover via `group-hover/row:` (named so it doesn't clobber unnamed `group-hover:` utilities nested in cells).

**BulkSelect** — `<.bulk_select_scope id="…" total_count={…}>` wraps the table and attaches the `BulkSelectScope` JS hook (in `priv/static/assets/phoenix_kit.js`). Selection lives client-side; the hook reads it at action-button-click time and pushes `%{"uuids" => […]}` to the LV. Three children: `<.bulk_select_header_cell>` (tri-state checkbox), `<.bulk_select_cell value={uuid}>` (per-row), and `<.bulk_actions_toolbar on_open_reorder="…" on_bulk_delete={…} reorder_dialog_id={…}>` (the floating toolbar with Reorder / Delete / Clear). Optional `reorder_dialog_id` wires instant client-side dialog open (skip the LV round-trip) when paired with a kept-in-DOM `<.reorder_modal>`. Consumer LVs collapse 0–1 captured uuids to `:all` in `open_reorder_modal` — a single-row "reorder" is a no-op and the bulk-toolbar label reads "Reorder all" in that state.

**ReorderModal** — `<.reorder_modal show on_close on_apply selected_count total_count strategies={[{value, label}…]} noun_singular noun_plural>` renders a strategy-picker dialog. Wraps `<.modal keep_in_dom={true}>` so the toolbar's `data-bulk-opens-dialog` can open it locally. The consumer LV owns the strategy whitelist (use a hardcoded `%{"name_asc" => :name_asc, …}` map for string→atom — never `String.to_existing_atom` on attacker input). Apply button carries `phx-disable-with` automatically.

**Modal — `keep_in_dom` mode** — `<.modal keep_in_dom>` renders the `<dialog>` regardless of `@show`; visibility flips via `data-show` and the `PkDialog` hook calls `showModal()/close()`. Suits modals whose inner block is static (strategy picker, confirmation with fixed copy). Default conditional render is preserved for forms whose `@form` is `nil` until opened. **Pass an explicit `id=` when using `keep_in_dom`** — the auto-derived id (`pk-modal-<on_close>`) collides if two kept-in-DOM modals share the same close-event name.

**SortSelector** — `<.sort_selector sort_by sort_dir options manual_field>` is the field-picker `<.select>` + direction-toggle button used in toolbars. Race-free by design: the select sends only `sort_by`, the arrow sends only `sort_dir`; the LV handler derives the missing half from `socket.assigns`. `manual_field={:position}` hides the direction toggle when the manual-order field is active (direction is meaningless when each row has a user-specified position).

**Pagination — `<.load_more>`** — `<.load_more loaded={length(@items)} total={@total_count} on_load_more="load_more" noun_plural="…">` renders a status line + Load more button. Hides entirely at `total=0`; button hides at `loaded>=total`. Suits embeddable LVs (no URL state) and DnD-aware lists where rows append (don't replace) on each click — selection persists across loads because rows stay in the DOM. Page-numbered `<.pagination>` is the alternative for standalone admin pages with deep-linkable state.

## Multilang Form Components

`PhoenixKitWeb.Components.MultilangForm` — `<.multilang_tabs>`, `<.multilang_fields_wrapper>`, `<.translatable_field>`, plus helpers `mount_multilang/1`, `handle_switch_language/2`, `merge_translatable_params/4`. Forms `import` it and call `mount_multilang(socket)` in `mount/3`.

**Wrapper scope rule** (load-bearing): `<.multilang_fields_wrapper>` wraps translatable fields **only**. The wrapper's id includes `@current_lang`, so a switch causes morphdom to re-mount everything inside. Non-translatable fields (pricing, status, actions) render as siblings outside the wrapper or they lose state on every switch.

**Language switching:** client-side skeleton toggle + 150ms trailing debounce on the server. `mount_multilang/1` attaches a `:handle_info` hook via `Phoenix.LiveView.attach_hook/4` that intercepts the timer message — consumers don't need a `handle_info` clause. LiveComponent fallback: rescue `ArgumentError` from `attach_hook` and add the clause manually if needed. The `switching_lang` attr is a backwards-compat no-op.

**Translatable fields:** `<.translatable_field>` takes `changeset={@changeset}` (not FormField) — its behavior changes with the active tab (primary-language vs JSONB-backed secondary). When mixed with `<.input>`/`<.select>`, the LV keeps both `:changeset` and `:form = to_form(changeset)` in sync via a private helper from mount/validate/save-error paths.

## Built-in Dashboard

Tabs, subtabs, badges, context selectors: see `lib/phoenix_kit/dashboard/README.md`.

## Activity Feed

Tracks business-level actions. Admin UI: `/admin/activity` (and `/admin/activity/:uuid`). Core: `lib/phoenix_kit/activity/`.

```elixir
PhoenixKit.Activity.log(%{
  action: "post.created",       # required — "resource.verb"
  module: "posts",              # filterable
  mode: "manual",               # "manual" | "auto" | "cron" | "script"
  actor_uuid: user.uuid,
  resource_type: "post",
  resource_uuid: post.uuid,
  target_uuid: nil,             # who was affected (drives notifications)
  metadata: %{"actor_role" => "user", "title" => post.title}
})
```

**Profile/field changes** — `log_user_change/4` auto-extracts `field_from`/`field_to` from a changeset; skips logging if nothing changed:

```elixir
PhoenixKit.Activity.log_user_change("user.profile_updated", user, changeset)
PhoenixKit.Activity.log_user_change("user.profile_updated", user, changeset,
  actor_uuid: admin.uuid, target_uuid: user.uuid, mode: "manual", actor_role: "admin")
```

**Conventions:** `action` = `resource.verb`; `module` = key string (`"users"`, `"posts"`); `mode` = manual/auto/cron/script; `actor_role` baked at log time (`"admin"`/`"user"`); `resource_type` usually equals `module`. Existing user actions are findable via `rg 'Activity.log' lib/phoenix_kit/users/`.

**External modules** — guard with `Code.ensure_loaded?/1`:

```elixir
if Code.ensure_loaded?(PhoenixKit.Activity) do
  PhoenixKit.Activity.log(%{action: "comment.created", module: "comments", ...})
end
```

**Cleanup:** `activity_retention_days` setting (default 90). `PhoenixKit.Activity.PruneWorker` runs daily via Oban.

## Notifications

Per-user inbox, driven by activity log. When `Activity.log/1` records an entry with `target_uuid != actor_uuid`, a row goes into `phoenix_kit_notifications` for the target user. Admins use `/admin/activity` for audit — they do NOT receive notifications.

Kill switch: `notifications_enabled` setting (default `"true"`).

**Generation:** automatic — never insert directly into `phoenix_kit_notifications`; create the activity and let the hook in `lib/phoenix_kit/activity/activity.ex` fan out via `PhoenixKit.Notifications.maybe_create_from_activity/1`. Each row is `(activity_uuid, recipient_uuid)` with independent `seen_at`/`dismissed_at`.

**Rendering:** `PhoenixKit.Notifications.Render.render(notification)` → `%{icon, text, link, actor_uuid}`. Unknown actions fall back to the raw action string.

**Public API** (`PhoenixKit.Notifications`):
- `list_for_user(user_uuid, opts)` — `:page`, `:per_page`, `:status (:unread|:all)`, `:include_dismissed`
- `recent_for_user(user_uuid, limit \\ 10)`, `count_unread(user_uuid)`
- `mark_seen` / `mark_all_seen` / `dismiss` / `dismiss_all` (all `(user_uuid, ...)`)
- `get_notification(user_uuid, uuid)` — recipient-scoped
- `enabled?/0`, `retention_days/0`, `prune/1`

**PubSub topic:** `PhoenixKit.Notifications.Events.topic_for_user(user_uuid)` (`"phoenix_kit:notifications:<uuid>"`). Events: `{:notification_created, n}`, `{:notification_seen, n}`, `{:notification_dismissed, n}`, `{:notifications_bulk_updated, :seen | :dismissed}`.

**UI** — no PhoenixKit-owned notifications page. Embeddable bell `PhoenixKitWeb.Live.NotificationsBell` (sticky nested LV, owns its PubSub sub):

```heex
<%= Phoenix.Component.live_render(@socket, PhoenixKitWeb.Live.NotificationsBell,
      id: "pk-notifications-bell", sticky: true,
      session: %{"user_uuid" => @current_user.uuid}) %>
```

"Seen" only on explicit user action — opening the dropdown does NOT auto-mark seen.

**Per-user preferences:** users mute notification *types* (not actions) via `UserSettings`. Persisted in `users.custom_fields["notification_preferences"]` (V18 JSONB column). Types live in `PhoenixKit.Notifications.Types`. Core types: `"account"`, `"posts"`, `"comments"`. External modules contribute via optional `notification_types/0` on `PhoenixKit.Module`:

```elixir
@impl PhoenixKit.Module
def notification_types do
  [%{key: "reviews", label: "Reviews", description: "...",
     actions: ["review.submitted", "review.edited"], default: true}]
end
```

`Types.list/0` merges core + modules; toggle appears automatically. `Notifications.Prefs.user_wants?/2` is **fail-open** — unknown actions, missing prefs, or lookup errors return `true`.

**Custom display:** `Render.render/1` honors three metadata keys before falling back:

```elixir
metadata: %{
  "notification_text" => "Alice left you a 5-star review.",
  "notification_icon" => "hero-star",
  "notification_link" => "/reviews/#{review.uuid}"
}
```

Any key can be absent — Render falls back to the action lookup for the missing parts.

**Cleanup:** `PhoenixKit.Notifications.PruneWorker` daily (`"0 4 * * *"`). Retention: `notifications_retention_days` → falls back to `activity_retention_days` (default 90). Cascading FK deletes also remove notifications when the underlying activity is pruned.

## MediaBrowser Component

Embeddable media UI: folder tree, grid/list, upload, search, selection, drag-drop, trash. `lib/phoenix_kit_web/components/media_browser.ex` (+ `.html.heex`). Used by `/admin/media` and any LV needing media picking.

**One-line embed** — the macro injects upload setup, the `"validate"` upload-channel stub, and the `handle_info` delegator:

```elixir
defmodule MyAppWeb.MediaPage do
  use MyAppWeb, :live_view
  use PhoenixKitWeb.Components.MediaBrowser.Embed
  def mount(_params, _session, socket), do: {:ok, socket}
end
```

```heex
<.live_component module={PhoenixKitWeb.Components.MediaBrowser}
  id="media-browser" parent_uploads={@uploads} />
```

`parent_uploads={@uploads}` is required (LiveView `allow_upload` constraint).

**Click behavior** (in order):
1. `select_mode` on → toggle file in/out of selection (toolbar Select button enters this mode).
2. `admin={true}` → `push_navigate` to `/admin/media/:uuid`.
3. Default → in-place modal (image/video/PDF/icon + metadata + Download). Closes via X/Esc/backdrop. Prev/Next chevrons + ←/→ keys step through current page's `uploaded_files`. If `PhoenixKitComments` is installed AND admin-enabled, a comment thread for `resource_type="file"` renders under metadata, keyed by `file_uuid`.

**Other attrs:**
- `scope_folder_id` — constrain to a virtual root (trash/tree/uploads/move all honor it)
- `on_navigate={:navigate}` — controlled mode; component emits `{MediaBrowser, id, {:navigate, params}}` so parent can `push_patch`. Parent feeds URL params back via `send_update(..., nav_params: ...)`. Reference: `lib/phoenix_kit_web/live/users/media.ex`.
- `initial_params` — apply URL params on first render (avoid root-view flash)

**URL sync (shareable folder deep links)** — added 1.7.126. Don't hand-write the controlled-mode round-trip; opt in via the Embed macro and it's automatic — folder/search/page/view land in the URL as `?folder=<uuid>&q=&page=&view=`, so a reload or a shared link reopens that folder. Folder tracked by uuid (rename-stable; unknown/out-of-scope → root). The `push_patch` only appends the query to the **current** path, so every existing segment (locale, parent resource ids, sub-tab — e.g. `/en/admin/orders/:id/edit/files`) is preserved.

```elixir
use PhoenixKitWeb.Components.MediaBrowser.Embed, url_sync: true
# non-default component id / multiple browsers:
use PhoenixKitWeb.Components.MediaBrowser.Embed, url_sync: [id: "my-browser"]
```
```heex
<.live_component module={PhoenixKitWeb.Components.MediaBrowser}
  id="my-browser" on_navigate={:navigate} initial_params={@initial_params}
  parent_uploads={@uploads} />
```

Implemented with LiveView lifecycle hooks (`attach_hook(:handle_params)` + `attach_hook(:handle_info)` in `on_mount`), **not** injected clauses — so it composes with a host LiveView that already defines its own `handle_params`/`handle_info` (e.g. a resource-edit page that loads its record in `handle_params`). No clash, nothing to reconcile. Public helpers `MediaBrowser.Embed.parse_nav_params/1` + `build_nav_query/1` for hosts that want a custom round-trip. `/admin/media` (`Live.Users.Media`) is the reference call site. Single-browser-per-page assumed (query keys aren't namespaced per component).

**Selection actions:** `…` dropdown in header → Download (staggered `<a download>` clicks via `MediaDragDrop` hook in `priv/static/assets/phoenix_kit.js`) + Delete (move to trash, or permanently if trash view active).

**Manual wiring** (if not using Embed) — Embed's `@before_compile` injection ensures user-defined clauses match first:

```elixir
def mount(_p, _s, socket), do: {:ok, PhoenixKitWeb.Components.MediaBrowser.setup_uploads(socket)}
def handle_event("validate", _p, socket), do: {:noreply, socket}
def handle_info({PhoenixKitWeb.Components.MediaBrowser, _, _} = msg, socket),
  do: PhoenixKitWeb.Components.MediaBrowser.handle_parent_info(msg, socket)
```

**Files:** `media_browser.ex`/`.html.heex`/`embed.ex`, backing context `lib/modules/storage/storage.ex`, JS hooks `priv/static/assets/phoenix_kit.js`.

## Guidelines

### External Module Auto-Discovery

Standalone module packages **must** include `:phoenix_kit` in `extra_applications`:

```elixir
def application, do: [extra_applications: [:logger, :phoenix_kit]]
```

Without this, `PhoenixKit.ModuleDiscovery` won't find it and routes 404. Template: `phoenix_kit_hello_world`.

### Tailwind CSS for External Modules

Modules with UI implement `css_sources/0`:

```elixir
@impl PhoenixKit.Module
def css_sources, do: [:phoenix_kit_my_module]
```

Discovery is automatic at compile time via `:phoenix_kit_css_sources` compiler (`lib/mix/tasks/compile.phoenix_kit_css_sources.ex`) — generates `assets/css/_phoenix_kit_sources.css`.

**Parent app setup (one-time, by `mix phoenix_kit.install`):**
1. Add `:phoenix_kit_css_sources` to `compilers:` in `mix.exs` (before `:phoenix_live_view`)
2. `app.css` has `@import "./_phoenix_kit_sources.css";`

After setup, adding/removing modules is zero-config.

### JavaScript Hooks for External Modules

PhoenixKit ships hooks (RowMenu, TableCardView, SortableGrid, etc.) in `priv/static/assets/phoenix_kit.js`, exposed as `window.PhoenixKitHooks`. Parent spreads into LiveSocket:

```javascript
hooks: { ...window.PhoenixKitHooks, ...colocatedHooks }
```

**Parent setup (by `mix phoenix_kit.install`):** copy `phoenix_kit.js` to `priv/static/assets/vendor/`, add `<script src={~p"/assets/vendor/phoenix_kit.js"}></script>` **before** `app.js` in root layout. `mix phoenix_kit.update` refreshes it.

External modules add hooks via inline `<script>` on `window.PhoenixKitHooks` (see hello_world).

### Layout Wrapper

PhoenixKit LiveView templates use `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>` (NOT `Layouts.app`):

```heex
<PhoenixKitWeb.Components.LayoutWrapper.app_layout
  flash={@flash} page_title={@page_title} current_path={@url_path}
  project_title={@project_title} phoenix_kit_current_scope={@phoenix_kit_current_scope}
  current_locale={assigns[:current_locale]}>
  <!-- content -->
</PhoenixKitWeb.Components.LayoutWrapper.app_layout>
```

Only `flash` is required. Note: the assign is `@url_path`, the attr is `current_path`. Full attr list: `lib/phoenix_kit_web/components/layout_wrapper.ex`.

### URL Prefix and Navigation

**NEVER hardcode PhoenixKit paths.** Use prefix helpers:

| Scenario | Use |
|---|---|
| Template links | `<.pk_link navigate="/path">` or `patch` |
| LV navigate/patch | `Routes.path("/path")` |
| Controller redirect | `Routes.path("/path")` |
| Email URLs | `Routes.url("/path")` |

```elixir
alias PhoenixKit.Utils.Routes
push_navigate(socket, to: Routes.path("/dashboard"))
url = Routes.url("/users/confirm/#{token}")
```

```heex
<.pk_link navigate="/dashboard">Dashboard</.pk_link>
<.pk_link_button navigate="/admin/users" variant="primary">Manage Users</.pk_link_button>
```

## Parent Project

### Install Commands

- `mix phoenix_kit.install` — install (use `--help`)
- `mix phoenix_kit.update` — update
- `mix phoenix_kit.status` — installation status
- `mix phoenix_kit.gen.migration` — custom migration

Features: versioned migrations, table prefix, idempotent ops, PostgreSQL validation, mailer templates.

### External Module Route Discovery

Routes auto-discovered at compile time via `ModuleDiscovery` beam scanning. The host router auto-recompiles when module deps change — `phoenix_kit_routes()` injects `__mix_recompile__?/0` with a hash of the discovered set.

**Two patterns:**
1. **Single page** — set `live_view: {Module.Web.IndexLive, :index}` on a tab in `admin_tabs/0` or `settings_tabs/0`. Route auto-generated. Used by: hello_world, sync, catalogue, document_creator, emails (settings), user_connections, legal.
2. **Multi-page** — implement `route_module/0` returning a module with `admin_routes/0` and `admin_locale_routes/0`. Required for sub-routes (`/new`, `/edit`, `/:id`). Do NOT also set `live_view:` on the main tab. Used by: ai, entities, publishing, newsletters.

If a parent tab + subtab share a path with both having `live_view:`, the core deduplicates (first wins) — but avoid this; only one `live_view:` per path.

Fallback for failed auto-discovery:

```elixir
config :phoenix_kit, route_modules: [PhoenixKitEntities.Routes]
```

### Publishing Routing Strategy

Publishing's `/:language/:group/*path` catch-all matches every 2+ segment URL and Phoenix has no fall-through after a route matches — so any host route declared after `phoenix_kit_routes()` shaped `/:locale/<literal>/...` was silently shadowed. `compile_publishing_routing/1` in `integration.ex` emits a dispatch shim (compile-time gated on `Code.ensure_loaded?(PhoenixKitPublishing.RouterDispatch)`):

1. Internal scope `/<url_prefix>/__phoenix_kit_publishing_dispatch` with `/localized` (binds `:language` + `:group`) and `/root` (binds `:group`) sub-scopes.
2. `def call/2` override on the host router: calls `RouterDispatch.maybe_rewrite/1`; on cache hit, prepends the internal prefix to `path_info` + `request_path` (originals stashed in `conn.private`), then `super(conn, opts)` matches against the internal scope. Miss → conn passes through, host routes win.
3. `restore_path/2` un-rewrites after route bind, before controller — without it, `default_language_no_prefix` redirect spins forever.

**Known blind spot:** `mix phx.routes` shows publishing routes under the internal prefix, not at the user-facing URL.

The mechanism generalizes; for now hardcoded to publishing — lift to a registry shape when a second module needs it.

## TODOs

Workspace-tracked items not ready for inline `# TODO` in `lib/`.

### Component test coverage for `phoenix_kit_web/components/core/`

Partial coverage exists in `test/phoenix_kit_web/components/core/` — written for the modal-to-native-dialog sweep. Remaining gaps:

- `<.draggable_list>` — three-axis coverage: (a) `:draggable=false` → no SortableJS hook, no `cursor-grab`; (b) `:draggable=true, :sortable_handle=nil` → SortableJS hook + full-item `cursor-grab`; (c) `:draggable=true, :sortable_handle=".pk-drag-handle"` → SortableJS hook + `data-sortable-handle` attribute set, **no** `cursor-grab` on the item wrapper (caller's responsibility). All three branches need rendered-HTML asserts.
- `<.table_default>` card-view branch — `:on_reorder` / `:reorder_scope` / `:reorder_group` / `:item_id` wire card-view as sortable target. Need to pin `phx-hook="SortableGrid"`, `data-sortable-*`, `data-id`, `class="sortable-item"`, drag-handle footer.
- `<.input>`, `<.select>`, `<.textarea>`, `<.checkbox>` — inline error rendering, daisyUI variant classes, FormField vs raw `name=`/`value=` dispatch.
- `<.flash>` if complexity has grown.

Surfaced 2026-05-02 by C12 triage during V108 / DnD core work. Partially closed 2026-05-23 (`bulk_select`, `sortable`, `reorder_modal`, `load_more`, `sort_selector`, `modal` keep_in_dom, `table_default` row + drag_handle). Fold the rest into a future component-coverage sweep.
