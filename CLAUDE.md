# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## MCP Memory Knowledge Base

Always start by reading MCP memory: `mcp__memory__read_graph`. Update with `mcp__memory__create_entities`, `mcp__memory__create_relations`, `mcp__memory__add_observations`.

## Project Overview

**PhoenixKit** - A starter kit for building modern web apps with Elixir/Phoenix/PostgreSQL. Library-first architecture (no OTP application), complete auth system with Magic Links, role-based access control (Owner/Admin/User), built-in admin dashboard, daisyUI 5 theme system, professional versioned migrations, layout integration with parent apps.

## Built-in Dashboard Features (USE THESE FIRST)

Before implementing custom dashboard functionality, check if PhoenixKit already provides it.

**Full documentation:** `lib/phoenix_kit/dashboard/README.md` (tabs, subtabs, badges, context selectors, and more).

**Quick Reference:** Tabs & Subtabs, Admin Navigation (registry-driven, see `ADMIN_README.md`), Context Selectors, Theme Switcher (`dashboard_themes` config), Live Badges (PubSub), Role-based UI (`@phoenix_kit_current_scope`).

## Development Commands

### Setup and Dependencies

- `mix setup` - Complete project setup
- `mix deps.get` - Install Elixir dependencies only

### Database Operations

- `mix ecto.create` / `mix ecto.migrate` / `mix ecto.reset` / `mix ecto.setup`

### PhoenixKit Installation System

- `mix phoenix_kit.install` - Install PhoenixKit (use `--help` for options)
- `mix phoenix_kit.update` - Update existing installation (use `--help` or `--status`)
- `mix phoenix_kit.gen.migration` - Generate custom migration files

Features: Oban-style versioned migrations, prefix support, idempotent operations, PostgreSQL validation, production mailer templates.

### Code Search with ast-grep

**Prefer `ast-grep` over text-based grep for structural code searches.**

```bash
ast-grep --lang elixir --pattern 'load_filter_data($$$)' lib/
ast-grep --lang elixir --pattern 'def $FUNC($$$ARGS) do $$$BODY end' lib/
```

Use `ast-grep` for structural patterns/function calls/refactoring; `Grep` (ripgrep) for text/regex/strings/comments.

### Testing & Code Quality

- `mix test` - Smoke tests (module loading)
- `mix format` - Format code
- `mix credo --strict` - Static analysis
- `mix dialyzer` - Type checking
- `mix quality` - Run all quality checks

PhoenixKit is a library module. Smoke tests + static analysis here; integration testing in parent apps. See CONTRIBUTING.md for dev workflow.

### CI/CD

GitHub Actions on push to `main`, `dev`, `claude/**` and all PRs. Checks: formatting, credo, dialyzer, compilation (warnings as errors), dependency audit, smoke tests.

### Pre-commit Checklist

**ALWAYS run before git commit:** `mix format` then `git add` then `git commit`.

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`. **NEVER mention Claude or AI assistance** in commit messages.

### Version Management

**Current Version**: 1.7.48 (mix.exs) | **Migration Version**: V62

Updates require: `mix.exs` (@version), `CHANGELOG.md`. Run `mix compile`, `mix test`, `mix format`, `mix credo --strict` before committing.

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/CLAUDE_REVIEW.md`. See `dev_docs/pull_requests/README.md`.

### Publishing

- `mix hex.build` / `mix hex.publish` / `mix docs`

## Code Style Guidelines

### Template Comments

Use EEx comments: `<%!-- comment --%>` (server-side). Avoid HTML comments: `<!-- -->` (sent to browser).

### Table Row Actions: Inline Buttons, Not Dropdowns

Use inline icon buttons (`flex gap-1`, `btn btn-xs btn-ghost` with `title` tooltips) for table/list row actions. Dropdown menus OK for selectors only.

### Structs Over Plain Maps

Prefer structs when a type exists: `Tab.new/1`, `Badge.new/1`, `ContextSelector`. Exception: plain maps in `config/config.exs` are idiomatic.

### DateTime: Always Use `UtilsDate.utc_now()`

**Always use `:utc_datetime` schema fields and `UtilsDate.utc_now()` for DB writes.** Never `NaiveDateTime` in new code.

| Context | Use | Never Use |
|---------|-----|-----------|
| Schema timestamps | `timestamps(type: :utc_datetime)` | `timestamps()` or `timestamps(type: :naive_datetime)` |
| Datetime fields | `field :name, :utc_datetime` | `field :name, :naive_datetime` |
| DB writes (changesets, update_all) | `UtilsDate.utc_now()` | Bare `DateTime.utc_now()` (has microseconds, will crash) |
| Non-DB (assigns, logs, queries) | `DateTime.utc_now()` is fine | `NaiveDateTime.utc_now()` |

```elixir
alias PhoenixKit.Utils.Date, as: UtilsDate

# Changesets
put_change(changeset, :updated_at, UtilsDate.utc_now())

# Bulk updates
Repo.update_all(query, set: [updated_at: UtilsDate.utc_now()])
```

**Why:** `:utc_datetime` fields reject microseconds. `DateTime.utc_now()` returns microsecond precision. `UtilsDate.utc_now()` truncates to seconds automatically. See `dev_docs/2026-02-17-datetime-standardization-plan.md` for full context.

### URL Prefix and Navigation (IMPORTANT)

**NEVER hardcode PhoenixKit paths.** Use configurable prefix helpers:

1. **`Routes.path/1`** - Prefix-aware paths in Elixir code
2. **`<.pk_link>`** - Prefix-aware link component for templates

```elixir
# In LiveView/Controller (Routes is auto-imported)
push_navigate(socket, to: Routes.path("/dashboard"))
url = Routes.url("/users/confirm/#{token}")
```

```heex
<.pk_link navigate="/dashboard">Dashboard</.pk_link>
<.pk_link patch="/dashboard/settings">Settings</.pk_link>
<.pk_link_button navigate="/admin/users" variant="primary">Manage Users</.pk_link_button>
```

| Scenario | Use |
|----------|-----|
| Template links | `<.pk_link navigate="/path">` or `patch` |
| LiveView navigate/patch | `Routes.path("/path")` |
| Controller redirect | `Routes.path("/path")` |
| Email URLs | `Routes.url("/path")` |

### Route Path Convention (Hyphens)

PhoenixKit uses **hyphens** in route paths: `/users/log-in`, `/users/reset-password`, `/users/magic-link`. If you get 404s, check for hyphens vs underscores.

### Helper Functions: Use Components, Not Private Functions

**Never use `defp` helpers called from HEEX templates** - compiler can't see usage. Create Phoenix Components in `lib/phoenix_kit_web/components/core/` instead. Existing: `badge.ex`, `time_display.ex`, `user_info.ex`, `button.ex`, `input.ex`, `select.ex`, `draggable_list.ex`. Import in `phoenix_kit_web.ex` → `core_components()`.

## Architecture

### Config & Settings

- **PhoenixKit.Config** - Static configuration (instead of `Application.get_env/3`)
- **PhoenixKit.Settings** - DB-persisted settings (time_zone, date_format, time_format, email_*)
- Admin UI at `{prefix}/admin/settings`

### Authentication Structure

- **PhoenixKit.Users.Auth** - Main auth context
- **PhoenixKit.Users.Auth.User** - User schema with role helpers
- **PhoenixKit.Users.Auth.UserToken** - Token management
- **PhoenixKit.Users.MagicLink** - Magic link auth
- **PhoenixKit.Users.Auth.Scope** - Auth scope with role integration
- **PhoenixKit.Users.RateLimiter** - Rate limiting (Hammer library)

Rate limits: Login 5/min, Magic Link 3/5min, Password Reset 3/5min, Registration 3/hour.

### Session Fingerprinting

Tracks IP/user agent. Config: `session_fingerprint_enabled: true`, `session_fingerprint_strict: false`.

### Role System

Three system roles: Owner, Admin, User. First user = Owner. Custom roles via admin UI. API: `PhoenixKit.Users.Roles`. Admin UI at `{prefix}/admin/users`.

### Module-Level Permissions (V53)

Allowlist model for admin sections and feature modules. See `lib/phoenix_kit/dashboard/ADMIN_README.md` for custom tab permissions.

**25 permission keys:** 5 core (`dashboard`, `users`, `media`, `settings`, `modules`) + 20 feature modules.

**Rules:** Owner = full access (hard-coded). Admin = all 25 by default. Custom roles = no permissions initially.

**Key APIs:**
- `Scope.has_module_access?(scope, "billing")` - Check access
- `Permissions.set_permissions(role_id, ["dashboard", "users"], granted_by_id)` - Grant
- `Permissions.copy_permissions(source_id, target_id)` - Copy
- `Permissions.register_custom_key("analytics", label: "Analytics", icon: "hero-chart-bar")` - Custom keys

**Route enforcement:** `:phoenix_kit_ensure_admin` and `:phoenix_kit_ensure_module_access` on_mount hooks. Custom roles fail-closed; Owner/Admin fail-open and bypass module-enabled checks.

**Edit protection:** Users can't edit own role. Only Owner edits Admin role. System roles can't change `is_system_role`.

### Date Formatting

Use `PhoenixKit.Utils.Date` (aliased as `UtilsDate`). Settings-aware: `format_datetime_with_user_format/1`, `format_date_with_user_format/1`, `format_time_with_user_format/1`. Manual: `format_date/2`, `format_time/2` with PHP-style codes.

### Module Folder Structure (IMPORTANT)

**All modules MUST be placed in `lib/modules/`** with `PhoenixKit.Modules.<ModuleName>` namespace.

```
lib/modules/db/
├── db.ex                    # PhoenixKit.Modules.DB (main context)
├── listener.ex              # PhoenixKit.Modules.DB.Listener
└── web/
    ├── index.ex             # PhoenixKit.Modules.DB.Web.Index (LiveView)
    └── show.ex
```

Backend + web code in same folder. Self-contained for future plugin system.

**DO NOT use legacy locations:** `lib/phoenix_kit/modules/`, `lib/phoenix_kit_web/live/modules/`, `lib/phoenix_kit/<name>.ex`

**Module docs:** Each module has a README.md in its folder (AI, Emails, Publishing, Sync, Entities, Languages, Billing, Comments).

### Enabling Modules Before Use

**All modules are DISABLED by default.** Enable with `enable_system/0`:

```elixir
PhoenixKit.Modules.Entities.enable_system()
PhoenixKit.Modules.AI.enable_system()
# ... same pattern for all modules
```

Or enable via Admin UI at `/{prefix}/admin/modules`.

### Migration Architecture

- **PhoenixKit.Migrations.Postgres** - Oban-style versioned migrator
- **Mix.Tasks.PhoenixKit.Install/Update/Gen.Migration** - Mix tasks

### UUIDv7

See `dev_docs/uuid_migration_instructions_v3.md` for full guide.

- Integer `id` is **deprecated** (V56+) — use `.uuid` for new code
- `belongs_to` with UUID FKs **MUST** include `references: :uuid`
- SQL: `uuid_generate_v7()`, Elixir: `UUIDv7.generate()`

```elixir
# CORRECT
belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7
# WRONG — bigint = uuid type mismatch
belongs_to :user, User, foreign_key: :user_uuid, type: UUIDv7
```

### Key Design Principles

Library-first (no OTP app, no supervision tree), no circular dependencies, parent apps provide layouts/home pages. PostgreSQL with Ecto, auto-detection or explicit repo config.

## PhoenixKit Integration

### Setup Steps

1. `mix phoenix_kit.install --repo YourApp.Repo`
2. Run migrations (auto-created)
3. Add `phoenix_kit_routes()` to router
4. Configure mailer (auto-detected or explicit)
5. Configure branding: `project_title`, `project_logo`, `project_icon`
6. Optional: custom layouts, theme config, email system

`{prefix}` = configured URL prefix (default: `/phoenix_kit`, set via `url_prefix` config).

### Core Integration Config

```elixir
config :phoenix_kit,
  repo: MyApp.Repo,
  mailer: MyApp.Mailer,  # Optional, auto-detected
  project_title: "My App",
  project_logo: "/images/logo.svg",  # SVG with currentColor for theme-aware
  project_icon: "hero-cube",         # Heroicon when no logo
  project_home_url: "~/dashboard",   # ~/ prefix auto-applies URL prefix
  layout: {MyAppWeb.Layouts, :app},  # Optional custom layout
  dashboard_themes: :all             # or ["system", "light", "dark", ...]
```

### Dashboard Color Scheme

**NEVER use hardcoded colors.** Use daisyUI semantic classes: `bg-base-100/200/300`, `text-base-content`, `bg-primary`, `btn btn-primary`, `badge badge-success`, `text-base-content/70`.

### Dashboard Layout Performance

Use `dashboard_assigns/1` not raw `assigns`:

```heex
<%!-- ✅ GOOD --%>
<PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
<%!-- ❌ BAD - ~84KB/sec redundant diffs --%>
<PhoenixKitWeb.Layouts.dashboard {assigns}>
```

### Admin Dashboard Customization

Registry-driven admin sidebar. See `lib/phoenix_kit/dashboard/ADMIN_README.md`.

```elixir
config :phoenix_kit, :admin_dashboard_tabs, [
  %{id: :analytics, label: "Analytics", icon: "hero-chart-bar", path: "/admin/analytics",
    permission: "dashboard", priority: 150, group: :admin_main,
    live_view: {MyAppWeb.PhoenixKitLive.AdminAnalyticsLive, :index}}
]
```

Custom admin LiveViews must use `LayoutWrapper.app_layout` and `@url_path`.

### Password Config

```elixir
config :phoenix_kit, :password_requirements,
  min_length: 8, max_length: 72,
  require_uppercase: false, require_lowercase: false,
  require_digit: false, require_special: false
```

### Optional Auth

OAuth & Magic Link registration: See `dev_docs/guides/oauth_and_magic_link_setup.md`.

## Key File Structure

### Core

- `lib/phoenix_kit.ex` - Main API
- `lib/phoenix_kit/users/auth.ex` - Auth context
- `lib/phoenix_kit/users/auth/user.ex` - User schema
- `lib/phoenix_kit/users/auth/user_token.ex` - Token management
- `lib/phoenix_kit/users/magic_link.ex` - Magic link auth
- `lib/phoenix_kit/users/role*.ex` - Role system
- `lib/phoenix_kit/users/permissions.ex` - Permissions (V53+)
- `lib/phoenix_kit/settings.ex` - Settings context
- `lib/phoenix_kit/utils/date.ex` - Date formatting

### Web

- `lib/phoenix_kit_web/router.ex` - Library router
- `lib/phoenix_kit_web/integration.ex` - Router integration macro
- `lib/phoenix_kit_web/users/*.ex` - Auth LiveViews and controllers
- `lib/phoenix_kit_web/live/*.ex` - Admin interfaces
- `lib/phoenix_kit_web/components/core_components.ex` - UI components
- `lib/phoenix_kit_web/components/layouts.ex` - Layouts

### Config

- `lib/phoenix_kit/migrations/postgres/v*.ex` - Versioned migrations
- `config/config.exs` - Library configuration
- `mix.exs` - Package configuration
