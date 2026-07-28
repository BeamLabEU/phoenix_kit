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

Test DB `phoenix_kit_test` uses embedded `PhoenixKit.Test.Repo` (`test/support/test_repo.ex`). Schema comes from the versioned migration chain — `test_helper.exs` runs `PhoenixKit.Migration.ensure_current/2` on every boot (there is no `test/support/postgres/migrations/` directory; that per-file approach was retired 2026-05-05). **Do not** swap in `Ecto.Migrator.run(repo, [{0, PhoenixKit.Migration}], :up, all: true)` — it goes silently stale (see `ensure_current/2` moduledoc).

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

### Local cross-repo development

Core has no `phoenix_kit` dep of its own — the flow matters from the **consumer** side. Every Max-maintained feature module wraps its `phoenix_kit*` deps in a `pk_dep/3` helper, so a module's suite can run against **uncommitted local core** without publishing. From inside the module's directory:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

Mix swaps the module's Hex pin for a local `path:` + `override: true` dep (var name = dep app upper-cased + `_PATH`; unset = published pin, so `mix hex.publish` / CI are unaffected). `phoenix_kit_parent` does the same permanently — use it to exercise the whole tree against local core. Full write-up: workspace `AGENTS.md` → "Testing a module against local deps".

### Code Search

- `rg` (ripgrep) — text/regex/strings/comments
- `ast-grep` — structural patterns; **prefer over text grep for code searches**

```bash
ast-grep --lang elixir --pattern 'load_filter_data($$$)' lib/
ast-grep --lang elixir --pattern 'def $FUNC($$$ARGS) do $$$BODY end' lib/
```

## Pull Requests

- **Branch:** core integrates on **`main`** — open PRs against `main` (`gh pr create --base main --head mdon:main`). The `dev` branch was **retired 2026-06-01**; do not target it.
- **CI/CD:** `.github/workflows/ci.yml` is **manual-only** (`workflow_dispatch`) — the equivalent checks run locally via `mix precommit` / `mix quality.ci` (format, credo, dialyzer, compile with warnings as errors, deps audit, tests with PostgreSQL).
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

### Prefix-safe migrations (named-schema installs)

The chain supports running into a named Postgres schema (`prefix:` opt / `--prefix`). Full reference + incident history: `dev_docs/guides/2026-07-27-prefix-safe-migrations.md`. Rules for any new `execute`-built SQL:

- **Index names stay bare on CREATE** — qualify only on `DROP INDEX`.
- **Every existence check needs a schema anchor** — `table_schema` on `information_schema.*`, `schemaname` on `pg_indexes`, and a name-based `pg_class` + `pg_namespace` JOIN for `pg_constraint` (never `'p.table'::regclass` in an IMMEDIATE check — it raises when the relation doesn't exist yet and aborts the whole transaction).
- **Schema-qualify functions** via `PhoenixKit.Migrations.Postgres.Helpers.ensure_uuid_v7_function/1` + `uuid_v7_call/1`; **never bare `CREATE EXTENSION`** (use `Helpers.ensure_extension!/1`) **or bare `CREATE SCHEMA`** (check `information_schema.schemata` first; thread `create_schema: false` to external migrators like Oban).
- The prefix is validated at the entry points (`Helpers.validate_prefix!/1`); tooling resolves `--prefix` → `config :phoenix_kit, prefix:` → `"public"`.
- **New table-backed schemas must `use PhoenixKit.SchemaPrefix`** right after `use Ecto.Schema` — enforced by `test/phoenix_kit/schema_prefix_test.exs`. Prefix is compile-time config (`config.exs`, never `runtime.exs`).
- **Oban rides the same prefix** — the host's `config :app, Oban` must carry `prefix: "..."`.
- Oracle: `test/integration/prefix_migration_test.exs` runs the full chain into a scratch schema (failures surface late — bad SQL queued by one version often blows up at a later version's `flush()`).

## Integrations System

Centralized OAuth / API key / bot token / credential management. Full reference: `dev_docs/guides/2026-07-27-integrations-system.md`; design: `dev_docs/plans/integrations-system.md`.

- **Storage:** `phoenix_kit_settings` JSONB, keys `integration:{provider}:{name}`. Consumers reference connections by storage-row **uuid** — all public API except `add_connection/3` and the read shims is uuid-strict.
- **Owner scopes:** `:system` (website-wide UI `/admin/settings/integrations/website`) vs `{:user, uuid}` (personal UI `/admin/settings/integrations`). Every context call takes an `:owner` opt, **default `:system`** — pass `owner:` explicitly on the personal path or a forgotten owner silently births a SYSTEM row. Never encrypt `owner_uuid`.
- **Module callbacks:** `required_integrations/0`, `integration_providers/0`, optional `migrate_legacy/0` (run via `ModuleRegistry.run_all_legacy_migrations/0`).

## Core Form Components

`PhoenixKitWeb.Components.Core.{Input, Select, Textarea, Checkbox}` — canonical form primitives. Use over raw `<input>`/`<select>`/`<textarea>` in new code. They handle `phx-feedback-for`, gettext error display, label wiring, daisyUI styling. Reference: `lib/phoenix_kit_web/users/user_form.html.heex`.

- `class` attr → merges onto the **styled element** (input/label/textarea/checkbox). Pass daisyUI modifiers here: `input-sm`, `select-primary`, `checkbox-accent`, etc.
- `<.input>` also has `wrapper_class` → goes to the outer `<div phx-feedback-for>`.
- Prefer FormField binding: `<.input field={@form[:email]} type="email" label="Email" />`. Raw `name=`/`value=` still works for dynamic field names.

## Core List-UI Components

The canonical toolkit for admin list views — DnD reorder, bulk-select, sort, strategy reorder, load-more pagination. All live in `lib/phoenix_kit_web/components/core/`. Reference call sites: `phoenix_kit_projects`' `projects_live.ex` / `tasks_live.ex` / `templates_live.ex`.

- **Sortable** — `<.sortable_tbody enabled={…} event="reorder_x" id="…">` + `<.sortable_row item_id={uuid}>`; `enabled={false}` omits the hook so DnD turns off when sort_by ≠ position. Pair with `<.drag_handle_cell>` / `<.drag_handle_header_cell>` (render the `.pk-drag-handle` the SortableGrid hook reads).
- **BulkSelect** — `<.bulk_select_scope>` wraps the table; selection lives client-side, the hook pushes `%{"uuids" => […]}` on action-click. Children: `<.bulk_select_header_cell>`, `<.bulk_select_cell value={uuid}>`, `<.bulk_actions_toolbar>`. Consumer LVs collapse 0–1 captured uuids to `:all` (a single-row "reorder" is a no-op).
- **ReorderModal** — `<.reorder_modal>` strategy-picker dialog. The consumer LV owns the strategy whitelist (hardcoded string→atom map — never `String.to_existing_atom` on attacker input).
- **Modal `keep_in_dom`** — `<.modal keep_in_dom>` renders the `<dialog>` always; visibility flips via `data-show`. **Pass an explicit `id=`** — the auto-derived id collides when two kept-in-DOM modals share a close-event name.
- **SortSelector** — `<.sort_selector sort_by sort_dir options manual_field>`; select sends only `sort_by`, arrow only `sort_dir` (race-free). `manual_field={:position}` hides the direction toggle. Accepts `id` (default `"pk-sort-selector-#{event}"`).
- **Pagination** — `<.load_more>` for embeddable / DnD-aware lists (rows append, selection persists); `<.pagination>` for standalone pages with deep-linkable state.

## Multilang Form Components

`PhoenixKitWeb.Components.MultilangForm` — `<.multilang_tabs>`, `<.multilang_fields_wrapper>`, `<.translatable_field>`, plus helpers `mount_multilang/1`, `handle_switch_language/2`, `merge_translatable_params/4`. Forms `import` it and call `mount_multilang(socket)` in `mount/3`.

**Wrapper scope rule** (load-bearing): `<.multilang_fields_wrapper>` wraps translatable fields **only**. The wrapper's id includes `@current_lang`, so a switch causes morphdom to re-mount everything inside. Non-translatable fields (pricing, status, actions) render as siblings outside the wrapper or they lose state on every switch.

**Language switching:** client-side skeleton toggle + 150ms trailing debounce on the server. `mount_multilang/1` attaches a `:handle_info` hook via `Phoenix.LiveView.attach_hook/4` that intercepts the timer message — consumers don't need a `handle_info` clause. LiveComponent fallback: rescue `ArgumentError` from `attach_hook` and add the clause manually if needed. The `switching_lang` attr is a backwards-compat no-op.

**Translatable fields:** `<.translatable_field>` takes `changeset={@changeset}` (not FormField) — its behavior changes with the active tab (primary-language vs JSONB-backed secondary). When mixed with `<.input>`/`<.select>`, the LV keeps both `:changeset` and `:form = to_form(changeset)` in sync via a private helper from mount/validate/save-error paths.

## Built-in Dashboard

Tabs, subtabs, badges, context selectors: see `lib/phoenix_kit/dashboard/README.md`.

## Login & Registration

Settings live on the admin **Users settings** page (`/admin/settings/users`).

**Session persistence** is one site-wide policy, two settings, and a visible
per-user choice:

- `remember_me_enabled` (default true) — master switch. Off hides the checkbox
  on every auth form AND hard-blocks the cookie in
  `maybe_write_remember_me_cookie/3`, so no caller (nor a forged param) can
  persist a session.
- `remember_me_default` (default true) — whether that checkbox starts
  **checked**. Users untick it for a session-only login.

Every form with a UI (password login, registration, magic-link completion, QR
handoff) renders the same pre-checked "Keep me logged in" box. Flows with no UI
to tick — **magic-link login** (arrives from an email) and **OAuth** (external
round-trip) — call `Auth.remember_me_params/0` and follow `remember_me_default`.
Read the policy via `Auth.remember_me_enabled?/0` / `remember_me_default?/0`;
never hardcode `%{"remember_me" => "true"}` at a call site again.

Why it defaults on: registration used to force a session-only login, so the
session rode the browser-session cookie that mobile browsers drop when they
evict the tab — freshly registered users were silently logged out overnight
(the DB token was fine; nothing referenced it).

⚠️ In the settings UI, do **not** mark a `<.checkbox>` `disabled` to express
"this doesn't apply right now": the component pairs the box with an
**un-disabled** hidden `value="false"` input, so a disabled box still submits
`false` and silently rewrites the stored setting on save.

**Post-auth destination** — one resolver, `Routes.post_auth_path/1`, takes
candidates in priority order and falls back to the `after_login_path` setting
then `"/"`. Precedence everywhere: explicit `return_to` (a `?return_to=` param
or the `:user_return_to` a gate stashed) > `after_registration_path` (registration
only) > `after_login_path`. `log_in_user/3` honors a `"return_to"` in its params
map as well as the session key. Both settings are validated as local paths on
save AND re-guarded at read time, so a hand-edited DB row can't create an open
redirect.

⚠️ **`Routes.local_path?/1` is the only redirect guard** — it rejects `//`,
`/\`, and **ASCII control characters**. The control-char rule is load-bearing:
browsers strip tab/CR/LF while parsing, so `"/\t/evil.com"` becomes
`//evil.com`. `Phoenix.Controller.redirect/2` blocks those itself, but
LiveView's `validate_local_url!` only rejects `\\` and a leading `//` — so any
LiveView `redirect(to: ...)` of user-influenced input MUST go through
`local_path?/1`.

**Email confirmation** — `require_email_confirmation` (default `"true"`,
historical behavior) gates enforcement only; confirmation emails always send.
All **six** enforcement sites honor it: the `require_authenticated_user` /
`require_authenticated_scope` conn plugs and the `ensure_authenticated`,
`ensure_authenticated_scope`, `ensure_owner`, `ensure_admin`, and
`ensure_module_access` on_mount hooks. Add the check to any new gate.

**The parked `/users/confirm` page** moves users along instead of stranding
them. Gates stash where the user was headed (`?return_to=`), and
`ConfirmationInstructions` advances (a) on mount when the user is already
confirmed — covers a `confirmed_at` flipped directly in the DB, then a refresh
— and (b) live, via the `{:user_confirmed, user}` broadcast, so clicking the
emailed link in another tab advances the parked tab. It subscribes **before**
re-reading the user, so a confirmation landing mid-mount can't be missed. The
email-link LiveView (`Users.Confirmation`) resolves the same destination, so
the two tabs never diverge.

**Soft-failure paths need `rescue` AND `catch :exit`** — an unreachable
database surfaces both ways: a checkout with no owner *raises*
(`DBConnection.OwnershipError`), while a dead pool or a died-mid-flight owner
*exits*. `Settings.get_setting_cached/2` and the boot-safe URL wrappers had
`rescue` only (so they leaked exits) and `Settings.get_setting/1` had neither —
meaning a transient DB problem crashed every caller, including the login
redirect resolver. All three now carry both clauses and log-then-default.

Because settings reads are ETS-cached, the pool is only touched on a cache
MISS, so this presented as **suite flakiness**, not a hard failure: DB-less
unit tests (`routes_test`, `language_refactor_test`, `tab_item_test`) passed on
a warm cache and died whenever another test's settings write evicted the key.
`test/integration/settings_unreachable_db_test.exs` pins it. Reproducing "no
database" in a test needs `async: true` (so sandbox ownership isn't shared)
**and** `Process.delete(:"$callers")` in the spawned process (Ecto lets a Task
borrow its caller's connection) — miss either and the test passes vacuously
against a healthy DB, which is why that file leads with a guard test.

⚠️ **Never evict a real key from the settings cache in a test.** The ETS cache
is global, so an `async: true` test that evicts `languages_enabled` (or any
shared key) forces every concurrently-running test to hit the database at
once — which showed up as unrelated permission-test failures and even a
Postgres `40P01 deadlock_detected`. Read a unique probe key instead: one that
exists in neither cache nor database misses inherently, with no eviction and
no blast radius.

**Flash ownership** — the flash group belongs INSIDE the LiveView tree
(LayoutWrapper's per-branch `<.flash_group>`, the dashboard layout, or the
host's layout). `root.html.heex` deliberately has none: a copy there rendered
every message twice with duplicate `flash-<kind>` ids and froze at its
dead-render value. Don't add one back.

## Permissions

`PhoenixKit.Users.Permissions` — allowlist model (row present = granted, absent = denied); Owner always has full access, enforced in code. The moduledoc is the source of truth; highlights:

- **Module keys** gate admin sections/feature modules; custom keys via `register_custom_key/2`. The two integration keys are independent flat keys: `integrations_system` is auto-granted to Admin, `integrations` is opt-in (never auto-granted).
- **`"*"` superadmin key** (`Permissions.superadmin_key/0`) — a blanket Owner-equivalent grant honored by `Scope.superadmin?/1` / `has_module_access?/2` / `accessible_modules/1`. In `all_module_keys/0` but NOT `enabled_module_keys/0` (never a *required* key); cannot be registered as a custom key.
- **Admin-area gate**: `Scope.can_access_admin_area?/1` — true for Owner, Admin, OR any single permission holder (`admin?/1` is a deprecated alias). `Scope.holds_all_enabled_permissions?/1` is the "can do everything, like Owner" check.
- **Sub-permissions** — dotted keys under a base (`"calendar.view_others"`), declared in `permission_metadata/0`'s `sub_permissions`, checked by the module via `Scope.can?/2`. A sub implies its base (granting a sub auto-grants the base; revoking the base cascades). Grant/revoke run under a per-`{role, base-key}` advisory lock.
- **Edit protection**: `can_edit_role_permissions?/2` — users cannot edit their own role; only Owner can edit Admin.

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
PhoenixKit.Activity.log_user_change("user.profile_updated", user, changeset,
  actor_uuid: admin.uuid, target_uuid: user.uuid, mode: "manual", actor_role: "admin")
```

**Conventions:** `action` = `resource.verb`; `module` = key string; `mode` = manual/auto/cron/script; `actor_role` baked at log time; `resource_type` usually equals `module`. Examples: `rg 'Activity.log' lib/phoenix_kit/users/`.

**External modules** — guard with `Code.ensure_loaded?/1`:

```elixir
if Code.ensure_loaded?(PhoenixKit.Activity) do
  PhoenixKit.Activity.log(%{action: "comment.created", module: "comments", ...})
end
```

**Cleanup:** `activity_retention_days` setting (default 90). `PhoenixKit.Activity.PruneWorker` runs daily via Oban.

## Notifications

Per-user inbox driven by the activity log. Full reference: `dev_docs/guides/2026-07-27-notifications.md`.

- **Generation:** `Activity.log/1` with `target_uuid != actor_uuid` fans out a `phoenix_kit_notifications` row via `Notifications.maybe_create_from_activity/1` — **never insert directly**. Kill switch: `notifications_enabled` (default `"true"`).
- **API:** `PhoenixKit.Notifications` — `list_for_user/2`, `recent_for_user/2`, `count_unread/1`, `mark_seen` / `mark_all_seen` / `dismiss` / `dismiss_all`, `get_notification/2` (recipient-scoped). Render via `Notifications.Render.render/1`, which honors `notification_text` / `notification_icon` / `notification_link` metadata keys.
- **UI:** embeddable `PhoenixKitWeb.Live.NotificationsBell` (sticky nested LV, owns its PubSub sub); "seen" only on explicit user action. PubSub topic: `Notifications.Events.topic_for_user(uuid)`.
- **Per-user preferences:** mute by *type*; types merge core + modules' `notification_types/0` callback. `Notifications.Prefs.user_wants?/2` is **fail-open**.
- **External delivery channels** (Telegram, Email; modules add via `notification_channels/0`): parallel routing layer — `Channel` behaviour, `Channels` registry, `ChannelConfig` under `custom_fields["notification_channel:<key>"]`, fail-closed `Routing`, Oban `DeliveryWorker` (`:notifications` queue) + `DigestWorker` cron. The inbox insert is decoupled from channel enqueue.
- **Cleanup:** `Notifications.PruneWorker` daily; retention `notifications_retention_days` → `activity_retention_days` (default 90).

## MediaBrowser Component

Embeddable media UI (folder tree, grid/list, upload, search, selection, trash): `lib/phoenix_kit_web/components/media_browser.ex`. Full attrs/behavior: `dev_docs/guides/2026-07-27-media-browser.md`.

**One-line embed** — the macro injects upload setup, the `"validate"` stub, and the `handle_info` delegator:

```elixir
use PhoenixKitWeb.Components.MediaBrowser.Embed
```

```heex
<.live_component module={PhoenixKitWeb.Components.MediaBrowser}
  id="media-browser" parent_uploads={@uploads} />
```

`parent_uploads={@uploads}` is required (LiveView `allow_upload` constraint). Key attrs: `scope_folder_id`, `on_navigate={:navigate}` (controlled mode), `initial_params`, `admin`, `select_mode`.

**URL sync (shareable folder deep links):** `use …Embed, url_sync: true` puts folder/search/page/view in the URL via lifecycle hooks (`attach_hook`, **not** injected clauses) — composes with a host LV that has its own `handle_params`/`handle_info`. The patch appends the query to the **current** path, so locale/resource segments are preserved. Reference: `lib/phoenix_kit_web/live/users/media.ex`.

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

Discovery is automatic at compile time via the `:phoenix_kit_css_sources` compiler — generates `assets/css/_phoenix_kit_sources.css`. Parent setup (one-time, by `mix phoenix_kit.install`): add the compiler to `compilers:` in `mix.exs` (before `:phoenix_live_view`) and `@import "./_phoenix_kit_sources.css";` in `app.css`. After setup, adding/removing modules is zero-config.

### JavaScript Hooks for External Modules

PhoenixKit ships hooks (RowMenu, TableCardView, SortableGrid, etc.) in `priv/static/assets/phoenix_kit.js`, exposed as `window.PhoenixKitHooks`. Parent spreads into LiveSocket:

```javascript
hooks: { ...window.PhoenixKitHooks, ...colocatedHooks }
```

**Parent setup (by `mix phoenix_kit.install`):** copy `phoenix_kit.js` to `priv/static/assets/vendor/`, add `<script src={~p"/assets/vendor/phoenix_kit.js"}></script>` **before** `app.js` in root layout. `mix phoenix_kit.update` refreshes it. External modules add hooks via inline `<script>` on `window.PhoenixKitHooks` (see hello_world).

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

### LiveView form ids

Every `<form phx-change=…>` needs a unique `id` — without it LiveView form recovery is silently disabled and host test suites warn `missing_form_id`. LiveComponent → derive from `@id`; inside a comprehension → include the row uuid; `<.form for={%{}}>` needs an explicit `id` (only `for={@changeset}` supplies one for free). Detect with a multi-line-aware scanner, not line-oriented grep. Full audit: `dev_docs/investigations/2026-07-27-missing-form-id-audit.md`.

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

Only one `live_view:` per path (core deduplicates, first wins — avoid). Fallback for failed auto-discovery:

```elixir
config :phoenix_kit, route_modules: [PhoenixKitEntities.Routes]
```

### Publishing Routing Strategy

Publishing's `/:language/:group/*path` catch-all matches every 2+ segment URL and Phoenix has no fall-through — host routes declared after `phoenix_kit_routes()` shaped `/:locale/<literal>/...` were silently shadowed. Fix: `compile_publishing_routing/1` in `integration.ex` emits an internal `__phoenix_kit_publishing_dispatch` scope plus a host-router `call/2` override that prepends the internal prefix on a `RouterDispatch.maybe_rewrite/1` cache hit (`restore_path/2` un-rewrites after route bind). Known blind spot: `mix phx.routes` shows publishing routes under the internal prefix, not the user-facing URL. The mechanism generalizes — lift to a registry shape when a second module needs it.

## daisyUI version (host-owned; advisory warnings only)

The daisyUI plugin lives in the **host** app (`assets/vendor/daisyui.js` + `daisyui-theme.js`). Core only declares a designed-for minimum (`PhoenixKit.Install.DaisyUI.minimum_version/0`, currently 5.6.0) and warns below it from `phoenix_kit.install` / `phoenix_kit.update` / `phoenix_kit.doctor` — advisory, never touching host files. Modal scrollbar-gutter compensations were removed 2026-07-12 (daisyUI ≥ 5.1 handles the gutter); **do NOT re-add `scrollbar-gutter` overrides in layouts, PkDialog, or modules**. A vendor-in-core custody design was researched and deliberately NOT implemented: `dev_docs/investigations/2026-07-12-daisyui-version-management-investigation.md`.

## TODOs

Workspace-tracked items not ready for inline `# TODO` in `lib/`.

### Component test coverage for `phoenix_kit_web/components/core/`

Partial coverage exists in `test/phoenix_kit_web/components/core/` — written for the modal-to-native-dialog sweep. Remaining gaps:

- `<.draggable_list>` — three-axis coverage: (a) `:draggable=false` → no SortableJS hook, no `cursor-grab`; (b) `:draggable=true, :sortable_handle=nil` → SortableJS hook + full-item `cursor-grab`; (c) `:draggable=true, :sortable_handle=".pk-drag-handle"` → SortableJS hook + `data-sortable-handle` attribute set, **no** `cursor-grab` on the item wrapper (caller's responsibility). All three branches need rendered-HTML asserts.
- `<.table_default>` card-view branch — `:on_reorder` / `:reorder_scope` / `:reorder_group` / `:item_id` wire card-view as sortable target. Need to pin `phx-hook="SortableGrid"`, `data-sortable-*`, `data-id`, `class="sortable-item"`, drag-handle footer.
- `<.input>`, `<.select>`, `<.textarea>` — inline error rendering, daisyUI variant classes, FormField vs raw `name=`/`value=` dispatch. (`<.checkbox>` gained a test — `checkbox_test.exs`.)
- `<.flash>` if complexity has grown.

Surfaced 2026-05-02 by C12 triage during V108 / DnD core work. Partially closed 2026-05-23 (`bulk_select`, `sortable`, `reorder_modal`, `load_more`, `sort_selector`, `modal` keep_in_dom, `table_default` row + drag_handle); `checkbox` closed since. Fold the rest into a future component-coverage sweep.

### Signed file-URL hardening (`modules/storage`)

Surfaced 2026-06-11 by an adversarial audit of `phoenix_kit_publishing` (which embeds storage URLs for public post images — low impact there, but the contract is weaker than its naming implies). In `lib/modules/storage/services/url_signer.ex` + `file_controller.ex`:

- **Token is 16-bit.** The signature is the first 4 hex chars of an MD5 — ~65k space, brute-forceable for a targeted file. Widen it (and consider HMAC over MD5).
- **Tokens never expire**, yet the 401 says *"Invalid or expired token."* Either add real expiry or fix the message so it doesn't imply time-limited capability URLs.
- **`/api/files/:uuid/info` is unauthenticated** and returns a valid signed URL for any uuid — defeats the signing scheme. Lock it down.
- **Fails open on a nil `secret_key_base`** — the token degrades to a predictable no-secret hash. Fail closed.

Not urgent (current use is public images), but record so the false sense of "capability URL" security isn't relied on for sensitive files.
