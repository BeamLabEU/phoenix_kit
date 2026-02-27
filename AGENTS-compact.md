# AGENTS.md

**PhoenixKit** — Elixir/Phoenix starter kit: auth (Magic Links), RBAC (Owner/Admin/User), admin dashboard, daisyUI 5 themes, versioned migrations.

## Commands

- `mix quality` — format + credo + dialyzer + compile + tests (use before committing)
- `mix quality.ci` — same but strict formatting
- `mix test` — smoke tests (library, not integration)
- `mix format` — format code
- `mix credo --strict` — static analysis

## Code Search

- **`ast-grep`** for structural patterns: `ast-grep --lang elixir --pattern 'def $FUNC($$$)' lib/`
- **`rg`** for text/regex/strings/comments

## Git & CI

- CI runs on `main`, `dev`, `claude/**` branches and all PRs
- Pre-commit: `mix format && git add -A && git commit`
- Commit verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`. **Never mention AI in commits.**
- Version: `mix.exs` @version + `CHANGELOG.md`. Current: **1.7.51** | Migration: **V67**

## PR Reviews

Place in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` — see `dev_docs/pull_requests/README.md`.

## Database

- All schemas: `@primary_key {:uuid, UUIDv7, autogenerate: true}`
- New migrations **must use** `uuid_generate_v7()` (not `gen_random_uuid()`)
- Oban-style versioned migrations in `lib/phoenix_kit/migrations/postgres/`

## Layout

PhoenixKit LiveViews use `LayoutWrapper.app_layout` instead of `Layouts.app`:

```heex
<PhoenixKitWeb.Components.LayoutWrapper.app_layout
  flash={@flash} page_title={@page_title} url_path={@url_path}
  project_title={@project_title} phoenix_kit_current_scope={@phoenix_kit_current_scope}
  current_locale={assigns[:current_locale]} current_locale_base={assigns[:current_locale_base]}
>
  <!-- content -->
</PhoenixKitWeb.Components.LayoutWrapper.app_layout>
```

## URL Routing

**Never hardcode paths.** Use prefix-aware helpers:

| Context | Use |
|---------|-----|
| Templates | `<.pk_link navigate="/path">` or `patch` |
| LiveView/Controller | `Routes.path("/path")` |
| Emails | `Routes.url("/path")` |

## Parent App Install

- `mix phoenix_kit.install` / `mix phoenix_kit.update` / `mix phoenix_kit.status`
