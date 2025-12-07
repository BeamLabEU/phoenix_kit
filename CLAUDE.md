# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**PhoenixKit** - a comprehensive starter kit for building modern web applications with Elixir and Phoenix. It provides authentication, content management, email system, and admin tools.

**Key Characteristics:**

- Library-first architecture (no OTP application)
- Complete authentication system with Magic Links & OAuth
- Role-based access control (Owner/Admin/User)
- Built-in admin dashboard and user management
- Modern theme system with daisyUI 5 (35+ themes)
- Professional versioned migration system (V01-V28)

**Content Management:** Blogging, Entities, Pages, Sitemap

**Email System:** AWS SES/SNS/SQS integration, templates, delivery tracking

**Additional Features:** Multi-language support, Maintenance mode, Referral codes, Audit logging, Session fingerprinting, Rate limiting

## Development Guidelines

### Keep It Simple

- Only make changes that are directly requested or clearly necessary
- Don't add features, refactor code, or make "improvements" beyond what was asked
- Don't add error handling for scenarios that can't happen
- Don't create helpers or abstractions for one-time operations
- The right amount of complexity is the minimum needed for the current task

### Code Reading First

Read and understand relevant files before proposing code edits. Don't speculate about code you haven't inspected. If the user references a specific file/path, open and inspect it first.

## Development Commands

### PhoenixKit Installation System

**Key Features:**

- **Professional versioned migrations** - Oban-style migration system with version tracking
- **Prefix support** - Isolate PhoenixKit tables using PostgreSQL schemas
- **Idempotent operations** - Safe to run migrations multiple times
- **Multi-version upgrades** - Automatically handles upgrades across multiple versions

**Commands:**

```bash
# Installation
mix phoenix_kit.install                      # Basic with auto-detection
mix phoenix_kit.install --repo MyApp.Repo    # Specify repository
mix phoenix_kit.install --prefix auth        # Custom schema prefix

# Setup (after installation)
mix setup                                    # Complete project setup (deps + database)

# Update (when needed)
mix phoenix_kit.update                       # Update to latest version
mix phoenix_kit.update --status              # Check current version (alt: mix phoenix_kit.status)
mix phoenix_kit.update --prefix auth         # Update with custom prefix
mix phoenix_kit.update -y                    # Skip prompts (CI/CD)

# Migrations
mix phoenix_kit.gen.migration                # Generate custom migration
```

### Testing & Code Quality

- `mix quality` - Run all checks (format + credo --strict + dialyzer)
- `mix test` - Run smoke tests (optional)

### Commit Message Rules

Commits should focus on implemented functionality, not process.

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`

**Restrictions:**
- Don't mention Claude or AI assistance
- Avoid phrases like "Generated with Claude", "AI-assisted", etc.
- Focus on **what** was changed and **why**

**Examples:**
- ✅ `Add role system for user authorization management`
- ✅ `Fix merge conflict markers in installation file`
- ❌ `Enhanced migration system` (no action verb)
- ❌ `Add new feature with Claude assistance` (mentions AI)

### Version Management

**Current Version**: 1.6.15 (in mix.exs)
**Migration Version**: V28 (sitemap tables)

**Update locations:** `mix.exs`, `CHANGELOG.md`, `README.md` (if needed)

**Before committing:**
- Mix compiles without errors
- Code formatted
- Credo passes
- CHANGELOG.md updated

### Publishing

- `mix hex.build` - Build package for Hex.pm
- `mix hex.publish` - Publish to Hex.pm
- `mix docs` - Generate documentation

## Code Style Guidelines

### Template Comments

Use EEx comments in Phoenix templates:

```heex
<%!-- EEx comments (correct - server-side only) --%>
<!-- HTML comments (avoid - sent to client) -->
```

### Helper Functions: Use Components, Not Private Functions

**CRITICAL RULE**: Never create private helper functions (`defp`) that are called directly from HEEX templates.

**❌ Wrong - Compiler Cannot See Usage:**
```elixir
defp format_date(date) do
  Calendar.strftime(date, "%B %d, %Y")
end
```
```heex
{format_date(user.created_at)}  <%!-- Compiler shows "unused function" warning --%>
```

**✅ Correct - Use Phoenix Components:**
```elixir
# lib/phoenix_kit_web/components/core/time_display.ex
attr :date, :any, required: true
attr :format, :string, default: "%B %d, %Y"

def formatted_date(assigns) do
  ~H"<span>{Calendar.strftime(@date, @format)}</span>"
end
```
```heex
<.formatted_date date={user.created_at} />  <%!-- Compiler sees component usage --%>
```

**Why This Matters:**
1. **Compiler Visibility** - Component calls (`<.component />`) are visible to compiler, function calls in templates are not
2. **Type Safety** - Components use `attr` macros for compile-time validation
3. **Reusability** - Components work across all LiveView modules without duplication
4. **No Warnings** - Prevents false-positive "unused function" warnings

**Existing Core Components:**
- `badge.ex` - Role badges, status badges
- `time_display.ex` - Relative time, expiration dates
- `user_info.ex` - User roles, counts, statistics
- `button.ex`, `input.ex`, `select.ex`, `textarea.ex`, `checkbox.ex` - Form components
- `pagination.ex`, `stat_card.ex`, `flash.ex`, `theme_switcher.ex`

**Adding New Component:**
1. Create file: `lib/phoenix_kit_web/components/core/my_category.ex`
2. Add import: `lib/phoenix_kit_web.ex` → `import PhoenixKitWeb.Components.Core.MyCategory`
3. Use in templates: `<.my_component attr={value} />`

## Architecture

### Config & Settings

- **PhoenixKit.Config** - Static configuration
- **PhoenixKit.Settings** - Database-stored system settings (admin UI at `{prefix}/admin/settings`)

**Core Settings:** `time_zone`, `date_format`, `time_format`

**Email Settings:** `email_enabled`, `email_save_body`, `email_ses_events`, `email_retention_days`, `email_sampling_rate`

### Authentication Structure

- **PhoenixKit.Users.Auth** - Main authentication context
- **PhoenixKit.Users.Auth.User** - User schema
- **PhoenixKit.Users.Auth.UserToken** - Token management
- **PhoenixKit.Users.Auth.Scope** - Authentication scope with role integration
- **PhoenixKit.Users.MagicLink** - Magic link authentication
- **PhoenixKit.Users.RateLimiter** - Rate limiting protection

### Rate Limiting

Protection against brute-force attacks using Hammer library (use `hammer_backend_redis` for production):
- Login: 5/min per email + IP limiting
- Magic Link: 3/5min per email
- Password Reset: 3/5min per email
- Registration: 3/hour per email + 10/hour per IP

### Session Fingerprinting

- IP Address Tracking
- User Agent Hashing
- Configurable strictness (log warnings or force re-auth)

```elixir
config :phoenix_kit,
  session_fingerprint_enabled: true,
  session_fingerprint_strict: false
```

**Verification Behavior:**
- **Non-strict (default)** - Logs warnings but allows access when fingerprints change
- **Strict mode** - Forces re-authentication if both IP and user agent change

### Role System

- **PhoenixKit.Users.Role** - Role schema
- **PhoenixKit.Users.RoleAssignment** - Role assignments with audit trail
- **PhoenixKit.Users.Roles** - Role management API

Three system roles: Owner, Admin, User (first user becomes Owner)

Admin interfaces: `{prefix}/admin/dashboard`, `{prefix}/admin/users`

### Date Formatting

```heex
{UtilsDate.format_datetime_with_user_format(user.inserted_at)}
{UtilsDate.format_date(Date.utc_today(), "F j, Y")}
{UtilsDate.format_time(Time.utc_now(), "h:i A")}
```

### Content Modules

**Blogging:** See `lib/phoenix_kit_web/live/modules/blogging/README.md`
**Emails:** See `lib/phoenix_kit_web/live/modules/emails/README.md`

### Migration Architecture

- **PhoenixKit.Migrations.Postgres** - PostgreSQL migrator with Oban-style versioning
- **Mix.Tasks.PhoenixKit.Install** - Igniter-based installation
- **Mix.Tasks.PhoenixKit.Update** - Versioned updates

### Key Design Principles

- **No Circular Dependencies** - Optional Phoenix deps prevent import cycles
- **Library-First Architecture** - No OTP application, no supervision tree
- **Production Ready** - Complete authentication with security best practices

## PhoenixKit Integration

### Setup Steps

1. Run `mix phoenix_kit.install --repo YourApp.Repo`
2. Add `phoenix_kit_routes()` macro to router
3. Configure mailer in `config/config.exs`
4. Access admin at `{prefix}/admin/dashboard`

### Configuration

```elixir
# config/config.exs
config :phoenix_kit,
  repo: MyApp.Repo,
  mailer: MyApp.Mailer

# Layout Integration (optional)
config :phoenix_kit,
  layout: {MyAppWeb.Layouts, :app},
  root_layout: {MyAppWeb.Layouts, :root}

# DaisyUI 5 Theme System (optional)
config :phoenix_kit,
  theme: %{
    theme: "auto",
    primary_color: "#3b82f6",
    storage: :local_storage,
    categories: [:light, :dark, :colorful]
  }

# Password Requirements (optional)
config :phoenix_kit, :password_requirements,
  min_length: 8,
  max_length: 72,
  require_uppercase: false,
  require_lowercase: false,
  require_digit: false,
  require_special: false

# mix.exs
{:phoenix_kit, "~> 1.6"}
```

### Date Formatting Helpers

Use `UtilsDate.format_datetime_with_user_format/1`, `format_date_with_user_format/1`, and `format_time_with_user_format/1` in templates to respect admin-configured formats.

### Optional Authentication

OAuth & Magic Link setup: See `guides/oauth_and_magic_link_setup.md`

## Key File Structure

### Core Files

- `lib/phoenix_kit.ex` - Main API module
- `lib/phoenix_kit/users/auth.ex` - Authentication context
- `lib/phoenix_kit/users/auth/user.ex` - User schema
- `lib/phoenix_kit/users/magic_link.ex` - Magic link authentication
- `lib/phoenix_kit/users/oauth.ex` - OAuth authentication
- `lib/phoenix_kit/users/roles.ex` - Role management API
- `lib/phoenix_kit/settings/settings.ex` - Settings context
- `lib/phoenix_kit/emails/*.ex` - Email system (16 modules)
- `lib/phoenix_kit/mailer.ex` - Mailer

### Content Management

- `lib/phoenix_kit/blogging/renderer.ex` - Blog post rendering
- `lib/phoenix_kit/entities/*.ex` - Entities system
- `lib/phoenix_kit/pages/*.ex` - Pages system
- `lib/phoenix_kit/sitemap/*.ex` - Sitemap generation

### Web Integration

- `lib/phoenix_kit_web/router.ex` - Library router
- `lib/phoenix_kit_web/plugs/integration.ex` - Router integration macro
- `lib/phoenix_kit_web/live/` - LiveView modules
- `lib/phoenix_kit_web/components/core/` - 30+ components

### Migrations (V01-V28)

Key versions: V01 (auth), V07 (email), V16 (OAuth), V17 (blogging/entities), V22 (audit), V23 (fingerprinting), V28 (sitemap)

## Additional Documentation

- **Emails:** `lib/phoenix_kit_web/live/modules/emails/README.md`
- **Blogging:** `lib/phoenix_kit_web/live/modules/blogging/README.md`
- **OAuth/Magic Link:** `guides/oauth_and_magic_link_setup.md`
