# AGENTS.md

**PhoenixKit** - A starter kit for building modern web apps with Elixir/Phoenix/PostgreSQL. Library-first architecture, complete auth system with Magic Links, role-based access control (Owner/Admin/User), built-in admin dashboard, daisyUI 5 theme system, professional versioned migrations, layout integration with parent apps.


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

## Development Commands

### Setup and Dependencies

- `mix setup` - Complete project setup
- `mix deps.get` - Install Elixir dependencies only

### Database Operations

- `mix ecto` - Print list of ecto commands

### Testing & Code Quality

PhoenixKit is a library module. Smoke tests + static analysis here; integration testing in parent apps.

- `mix test` - Smoke tests (module loading)
- `mix format` - Format code
- `mix credo --strict` - Static analysis
- `mix dialyzer` - Type checking
- `mix quality` - Run all quality checks
- `mix quality.ci` - Run all quality checks for CI (strict formatting check)

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

GitHub Actions on push to `main`, `dev`, `claude/**` and all PRs. Checks: formatting, credo, dialyzer, compilation (warnings as errors), dependency audit, smoke tests.

### Pre-commit Checklist

**ALWAYS run before git commit:** `mix format` then `git add` then `git commit`.

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`. **NEVER mention Claude or AI assistance** in commit messages.

### Version Management

**Current Version**: 1.2.34 (mix.exs) | **Migration Version**: V90

Updates require: `mix.exs` (@version), `CHANGELOG.md`. Run `mix compile`, `mix test`, `mix format`, `mix credo --strict` before committing.

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GPT_REVIEW.md`). See `dev_docs/pull_requests/README.md`.

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


## Guidelines

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

