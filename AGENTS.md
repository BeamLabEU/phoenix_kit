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

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`). See `dev_docs/pull_requests/README.md`.

### Publishing commands

- `mix hex.build`
- `mix hex.publish`
- `mix docs`


## Database

- All schemas use `@primary_key {:uuid, UUIDv7, autogenerate: true}`
- **New migrations must use** `uuid_generate_v7()` (NOT `gen_random_uuid()`)
- The migration system uses Oban-style versioned migrations (see `lib/phoenix_kit/migrations/postgres/`)


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

### PhoenixKit Layout Guidelines

PhoenixKit uses its own layout wrapper component instead of the standard Phoenix `Layouts.app`:

- **Always** begin PhoenixKit LiveView templates with `<PhoenixKitWeb.Components.LayoutWrapper.app_layout ...>` which wraps all inner content
- Required attributes: `flash`, `page_title`, `url_path`, `project_title`, `phoenix_kit_current_scope`
- Optional: `current_locale`, `current_locale_base`

Example:

```heex
<PhoenixKitWeb.Components.LayoutWrapper.app_layout
  flash={@flash}
  page_title={@page_title}
  url_path={@url_path}
  project_title={@project_title}
  phoenix_kit_current_scope={@phoenix_kit_current_scope}
  current_locale={assigns[:current_locale]}
  current_locale_base={assigns[:current_locale_base]}
>
  <!-- Your content here -->
</PhoenixKitWeb.Components.LayoutWrapper.app_layout>
```

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

