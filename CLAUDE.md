# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## MCP Memory Knowledge Base

⚠️ **IMPORTANT**: Always start working with the project by studying data in the MCP memory storage. Use the command:

```
mcp__memory__read_graph
```

This will help understand the current state of the project, implemented and planned components, architectural decisions.

Update data in memory when discovering new components or changes in project architecture. Use:

- `mcp__memory__create_entities` - for adding new modules/components
- `mcp__memory__create_relations` - for relationships between components
- `mcp__memory__add_observations` - for supplementing information about existing components

## Project Overview

This is **PhoenixKit** - PhoenixKit is a starter kit for building modern web applications with Elixir and Phoenix with PostgreSQL support and streamlined setup. As a start it provides a complete authentication system that can be integrated into any Phoenix application without circular dependencies.

**Key Characteristics:**

- Library-first architecture (no OTP application)
- Streamlined setup with automatic repository detection
- Complete authentication system with Magic Links
- Role-based access control (Owner/Admin/User)
- Built-in admin dashboard and user management
- Modern theme system with daisyUI 5 and 35+ themes support
- Professional versioned migration system
- Layout integration with parent applications
- Ready for production use

## ⚠️ Built-in Dashboard Features (USE THESE FIRST)

**IMPORTANT**: Before implementing custom dashboard functionality, check if PhoenixKit already provides it.

**Full documentation:** See `lib/phoenix_kit/dashboard/README.md` for comprehensive dashboard documentation including tabs, subtabs, badges, context selectors, and more.

### Quick Reference

- **Tabs & Subtabs** - Configurable navigation with parent/child relationships, custom styling, animations
- **Context Selectors** - Organization/team/project switching with dependencies
- **Theme Switcher** - `dashboard_themes` config, auto-renders in header
- **Live Badges** - Real-time badge updates via PubSub
- **Role-based UI** - Use `@phoenix_kit_current_scope` for role checks

### Context Selector Quick Example

```elixir
# Single selector - config/config.exs
config :phoenix_kit, :dashboard_context_selector,
  loader: {MyApp.Orgs, :list_for_user},
  display_name: fn org -> org.name end,
  label: "Organization",
  position: :header

# Multiple selectors with dependencies
config :phoenix_kit, :dashboard_context_selectors, [
  %{key: :organization, loader: {MyApp.Orgs, :list_for_user}, ...},
  %{key: :project, depends_on: :organization, loader: {MyApp.Projects, :list_for_org}, ...}
]
```

### Subtab Styling Quick Example

```elixir
config :phoenix_kit, :user_dashboard_tabs, [
  %{
    id: :orders,
    label: "Orders",
    path: "/dashboard/orders",
    subtab_display: :when_active,  # or :always
    subtab_indent: "pl-12",        # Tailwind padding class
    subtab_icon_size: "w-3 h-3",   # Icon size
    subtab_text_size: "text-xs",   # Text size
    subtab_animation: :slide       # :none, :slide, :fade, :collapse
  },
  %{id: :pending, label: "Pending", path: "/dashboard/orders/pending", parent: :orders}
]
```

## Development Commands

### Setup and Dependencies

- `mix setup` - Complete project setup (installs deps, sets up database)
- `mix deps.get` - Install Elixir dependencies only

### Database Operations

- `mix ecto.create` - Create the database
- `mix ecto.migrate` - Run database migrations
- `mix ecto.reset` - Drop and recreate database with fresh data
- `mix ecto.setup` - Create database, run migrations, and seed data

### PhoenixKit Installation System

- `mix phoenix_kit.install` - Install PhoenixKit using igniter (for new projects)
- `mix phoenix_kit.install --help` - Show detailed installation help and options
- `mix phoenix_kit.update` - Update existing PhoenixKit installation to latest version
- `mix phoenix_kit.update --help` - Show detailed update help and options
- `mix phoenix_kit.update --status` - Check current version and available updates
- `mix phoenix_kit.gen.migration` - Generate custom migration files

**Key Features:**

- **Professional versioned migrations** - Oban-style migration system with version tracking
- **Prefix support** - Isolate PhoenixKit tables using PostgreSQL schemas
- **Idempotent operations** - Safe to run migrations multiple times
- **Multi-version upgrades** - Automatically handles upgrades across multiple versions
- **PostgreSQL Validation** - Automatic database adapter detection with warnings for non-PostgreSQL setups
- **Production Mailer Templates** - Auto-generated configuration examples for SMTP, SendGrid, Mailgun, Amazon SES
- **Interactive Migration Runner** - Optional automatic migration execution with smart CI detection
- **Built-in Help System** - Comprehensive help documentation accessible via `--help` flag

**Installation Help:**

```bash
# Show detailed installation options and examples
mix phoenix_kit.install --help

# Quick examples from help:
mix phoenix_kit.install                                   # Basic installation with auto-detection
mix phoenix_kit.install --repo MyApp.Repo                 # Specify repository
mix phoenix_kit.install --prefix auth                     # Custom schema prefix
```

**Update Help:**

```bash
# Show detailed update options and examples
mix phoenix_kit.update --help

# Quick examples from help:
mix phoenix_kit.update                                    # Update to latest version
mix phoenix_kit.update --status                           # Check current version
mix phoenix_kit.update --prefix auth                      # Update with custom prefix
mix phoenix_kit.update -y                                 # Skip confirmation prompts (CI/CD)
mix phoenix_kit.update --force -y                         # Force update with auto-migration
```

### Testing & Code Quality

- `mix test` - Run smoke tests (module loading and configuration)
- `mix format` - Format code according to .formatter.exs
- `mix credo --strict` - Static code analysis
- `mix dialyzer` - Type checking (requires PLT setup)
- `mix quality` - Run all quality checks (format, credo, dialyzer)

**Testing Philosophy for Library Modules:**

PhoenixKit is a **library module**, not a standalone application. Testing approach:

- ✅ **Smoke Tests** - Verify modules are loadable and properly structured
- ✅ **Static Analysis** - Credo and Dialyzer catch logic and type errors
- ✅ **Integration Testing** - Should be performed in parent Phoenix applications

**Why Minimal Unit Tests?**
- Library code requires database, configuration, and runtime context
- Unit tests would need complex mocking of Repo, Settings, and other dependencies
- Real-world usage testing in parent applications provides better coverage
- Smoke tests ensure library compiles and modules load correctly

**For Contributors:**
Test your changes by integrating PhoenixKit into a real Phoenix application.
See CONTRIBUTING.md for development workflow with live reloading.

### CI/CD

PhoenixKit uses GitHub Actions for continuous integration:

**Automated Checks:**
- ✅ Code formatting validation (`mix format --check-formatted`)
- ✅ Static analysis with Credo (`mix credo --strict`)
- ✅ Type checking with Dialyzer
- ✅ Compilation with warnings as errors (production code)
- ✅ Dependency audit (non-blocking for transitive deps)
- 📝 Smoke tests (optional - basic module loading verification)

**CI Workflow:**
- Runs on push to `main`, `dev`, and `claude/**` branches
- Runs on all pull requests
- Uses caching for dependencies and PLT files
- Parallel execution for faster feedback

**View CI Status:**
- GitHub Actions: Check the "Actions" tab in the repository
- Badge: See README.md for CI status badge

### ⚠️ IMPORTANT: Pre-commit Checklist

**ALWAYS run before git commit:**

```bash
mix format
git add -A  # Add formatted files
git commit -m "your message"
```

This ensures consistent code formatting across the project.

### 📝 Commit Message Rules

**ALWAYS start commit messages with action verbs:**

- `Add` - for new features, files, or functionality
- `Update` - for modifications to existing code or features
- `Merge` - for merge commits or combining changes
- `Fix` - for bug fixes
- `Remove` - for deletions

**Important commit message restrictions:**

- ❌ **NEVER mention Claude or AI assistance** in commit messages
- ❌ Avoid phrases like "Generated with Claude", "AI-assisted", etc.
- ✅ Focus on **what** was changed and **why**

**Examples:**

- ✅ `Add role system for user authorization management`
- ✅ `Update rollback logic to handle single version migrations`
- ✅ `Fix merge conflict markers in installation file`
- ❌ `Enhanced migration system` (no action verb)
- ❌ `migration fixes` (not descriptive enough)
- ❌ `Add new feature with Claude assistance` (mentions AI)

### 🏷️ Version Management

**Current Version**: 1.7.0 (mix.exs) | **Migration Version**: V31

**Version updates require:** Update `mix.exs` (@version), `CHANGELOG.md`, and optionally `README.md`. Always run `mix compile`, `mix test`, `mix format`, `mix credo --strict` before committing.

### Publishing

- `mix hex.build` - Build package for Hex.pm
- `mix hex.publish` - Publish to Hex.pm (requires auth)
- `mix docs` - Generate documentation with ExDoc

## Code Style Guidelines

### Template Comments

**Use EEx comments in .heex templates:** `<%!-- comment --%>` (server-side, not sent to client)
**Avoid HTML comments:** `<!-- comment -->` (sent to browser)

### URL Prefix and Navigation (IMPORTANT)

**NEVER hardcode PhoenixKit paths.** PhoenixKit uses a configurable URL prefix (default: `/phoenix_kit`). Always use the provided helpers to ensure paths work correctly regardless of prefix configuration.

**Available Helpers:**

1. **`Routes.path/1`** - Build prefix-aware paths in Elixir code
2. **`<.pk_link>`** - Prefix-aware link component for templates

**✅ CORRECT - Using Routes.path:**

```elixir
# In any LiveView or Controller (Routes is auto-imported)
def handle_event("save", _params, socket) do
  {:noreply, push_navigate(socket, to: Routes.path("/dashboard"))}
end

# Building URLs for emails
url = Routes.url("/users/confirm/#{token}")
```

**✅ CORRECT - Using pk_link component:**

```heex
<%!-- Navigate with automatic prefix --%>
<.pk_link navigate="/dashboard">Dashboard</.pk_link>

<%!-- Patch for LiveView updates --%>
<.pk_link patch="/dashboard/settings">Settings</.pk_link>

<%!-- Button-styled link --%>
<.pk_link_button navigate="/admin/users" variant="primary">
  Manage Users
</.pk_link_button>
```

**❌ WRONG - Hardcoded paths:**

```heex
<%!-- DON'T DO THIS - breaks when prefix changes --%>
<.link navigate="/phoenix_kit/dashboard">Dashboard</.link>
<.link navigate="/dashboard">Dashboard</.link>
```

**When to use which:**

| Scenario | Use |
|----------|-----|
| Template navigation links | `<.pk_link navigate="/path">` |
| Template patch links | `<.pk_link patch="/path">` |
| `push_navigate` in LiveView | `Routes.path("/path")` |
| `push_patch` in LiveView | `Routes.path("/path")` |
| Redirect in Controller | `Routes.path("/path")` |
| Email URLs | `Routes.url("/path")` |

**Note:** `Routes` is automatically aliased in all LiveViews, LiveComponents, Controllers, and HTML modules via `PhoenixKitWeb`.

### Route Path Convention (Hyphens)

PhoenixKit uses **hyphens** in route paths, not underscores:

| Correct (PhoenixKit) | Common Convention |
|---------------------|-------------------|
| `/users/log-in` | `/users/log_in` |
| `/users/log-out` | `/users/log_out` |
| `/users/reset-password` | `/users/reset_password` |
| `/users/magic-link` | `/users/magic_link` |

This matches URL conventions (hyphens are more readable in URLs) but differs from the typical Elixir/Phoenix underscore convention. If you get 404 errors, check that you're using hyphens.

### Helper Functions: Use Components, Not Private Functions

**CRITICAL**: Never use `defp` helpers called from HEEX templates - compiler can't see usage.

**❌ WRONG:** `defp format_date(date)` called as `{format_date(@date)}` in template
**✅ CORRECT:** Create Phoenix Component in `lib/phoenix_kit_web/components/core/` and use as `<.formatted_date date={@date} />`

**Existing components:** `badge.ex`, `time_display.ex`, `user_info.ex`, `button.ex`, `input.ex`, `select.ex`, `draggable_list.ex`

**To add new:** Create in `components/core/`, import in `phoenix_kit_web.ex` → `core_components()`

## Architecture

### Config Architecture

- PhoenixKit basic configuration via default Config module in a parent project
- **PhoenixKit.Config** - Used to work with static configuration instead of `Application.get_env/3`

### Settings System Architecture

- **PhoenixKit.Settings** - Settings context for system-wide configuration management
- **PhoenixKit.Settings.Setting** - Settings schema with key/value storage and timestamps
- **PhoenixKitWeb.Live.Settings** - Settings management interface at `{prefix}/admin/settings`

**Core Settings:**

- **time_zone** - System timezone offset (UTC-12 to UTC+12)
- **date_format** - Date display format (Y-m-d, m/d/Y, d/m/Y, d.m.Y, d-m-Y, F j, Y)
- **time_format** - Time display format (H:i for 24-hour, h:i A for 12-hour)

**Email Settings:**

- **email_enabled** - Enable/disable email system (default: false)
- **email_save_body** - Save full email content vs preview only (default: false)
- **email_ses_events** - Enable AWS SES event processing (default: false)
- **email_retention_days** - Data retention period (default: 90 days)
- **email_sampling_rate** - Percentage of emails to fully track (default: 100%)

**Key Features:**

- **Database Storage** - Settings persisted in phoenix_kit_settings table
- **Admin Interface** - Complete settings management at `{prefix}/admin/settings`
- **Default Values** - Fallback defaults for all settings (UTC+0, Y-m-d, H:i)
- **Validation** - Form validation with real-time preview examples
- **Integration** - Automatic integration with date formatting utilities
- **Email System UI** - Dedicated section for email system configuration

### Authentication Structure

- **PhoenixKit.Users.Auth** - Main authentication context with public interface
- **PhoenixKit.Users.Auth.User** - User schema with validations, authentication, and role helpers
- **PhoenixKit.Users.Auth.UserToken** - Token management for email confirmation and password reset
- **PhoenixKit.Users.MagicLink** - Magic link authentication system
- **PhoenixKit.Users.Auth.Scope** - Authentication scope management with role integration
- **PhoenixKit.Users.RateLimiter** - Rate limiting protection for authentication endpoints

### Rate Limiting

Uses Hammer library. Protected: Login (5/min), Magic Link (3/5min), Password Reset (3/5min), Registration (3/hour). Config via `PhoenixKit.Users.RateLimiter`. Use `hammer_backend_redis` in production.

### Session Fingerprinting

Tracks IP and user agent to detect session hijacking. Config: `session_fingerprint_enabled: true`, `session_fingerprint_strict: false`. Non-strict logs warnings; strict forces re-auth on mismatch.

### Role System

Three system roles: Owner, Admin, User. First user becomes Owner. API: `PhoenixKit.Users.Roles`. Admin UI at `{prefix}/admin/users`. Role checks via `PhoenixKit.Users.Auth.Scope`.

### Date Formatting

Use `PhoenixKit.Utils.Date` (aliased as `UtilsDate`). Settings-aware: `format_datetime_with_user_format/1`, `format_date_with_user_format/1`, `format_time_with_user_format/1`. Manual: `format_date/2`, `format_time/2` with PHP-style codes.

### Module Folder Structure (IMPORTANT)

**All modules MUST be placed in `lib/modules/`** - this is the only correct location for module code.

**Namespace convention:** All modules must use the `PhoenixKit.Modules.<ModuleName>` namespace prefix.

**Example module structure:**
```
lib/modules/db/
├── db.ex                    # PhoenixKit.Modules.DB (main context)
├── listener.ex              # PhoenixKit.Modules.DB.Listener
└── web/
    ├── index.ex             # PhoenixKit.Modules.DB.Web.Index (LiveView)
    ├── index.html.heex
    ├── show.ex              # PhoenixKit.Modules.DB.Web.Show (LiveView)
    └── show.html.heex
```

**Key rules:**
- Backend logic AND web/LiveView code go in the same `lib/modules/<name>/` folder
- Main context module: `PhoenixKit.Modules.<Name>`
- Sub-modules: `PhoenixKit.Modules.<Name>.<SubModule>`
- Web/LiveView code: `PhoenixKit.Modules.<Name>.Web.<Component>` (recommended but flexible)
- Each module is self-contained for future plugin system compatibility

**DO NOT use these legacy locations for new modules:**
- ❌ `lib/phoenix_kit/modules/` - Legacy, being migrated
- ❌ `lib/phoenix_kit_web/live/modules/` - Legacy, being migrated
- ❌ `lib/phoenix_kit/<module_name>.ex` - Legacy location

**Module Documentation:**

- **AI module:** See `lib/modules/ai/README.md` for API usage, endpoint management, prompts, and usage tracking.
- **Emails module:** See `lib/modules/emails/README.md` for architecture, configuration, and troubleshooting guidance.
- **Publishing module:** See `lib/modules/publishing/README.md` for dual storage modes, multi-language support, and filesystem-based content management.
- **Sync module:** See `lib/modules/sync/README.md` for peer-to-peer data sync, programmatic API, conflict strategies, and remote operations.
- **Entities module:** See `lib/modules/entities/README.md` for dynamic content types.
- **Billing module:** See `lib/modules/billing/README.md` for payment providers, subscriptions, invoices.

### ⚠️ CRITICAL: Enabling Modules Before Use

**All PhoenixKit modules are DISABLED by default.** Before using any module programmatically, you MUST enable it first. Attempting to use a disabled module will result in errors or no-ops.

**Enable a module using its `enable_system/0` function:**

```elixir
# Check if module is enabled
PhoenixKit.Modules.Entities.enabled?()        # => false (default)
PhoenixKit.Modules.AI.enabled?()              # => false (default)

# Enable modules before use
PhoenixKit.Modules.Entities.enable_system()   # Enables entities module
PhoenixKit.Modules.AI.enable_system()         # Enables AI module
PhoenixKit.Modules.Posts.enable_system()      # Enables posts module
PhoenixKit.Emails.enable_system()     # Enables email tracking
PhoenixKit.Billing.enable_system()    # Enables billing module
PhoenixKit.Sitemap.enable_system()    # Enables sitemap generation
PhoenixKit.Modules.Sync.enable_system()     # Enables DB sync
PhoenixKit.Modules.Languages.enable_system() # Enables multi-language
PhoenixKit.Pages.enable_system()      # Enables pages module
PhoenixKit.Modules.Referrals.enable_system() # Enables referrals

# Disable when no longer needed
PhoenixKit.Modules.Entities.disable_system()
```

**Alternatively, enable via Admin UI:** Navigate to `/{prefix}/admin/modules` or each module's settings page.

**Common pattern:**

```elixir
# WRONG - Will fail if module is disabled
PhoenixKit.Entities.create_entity(%{name: "products", ...})

# CORRECT - Check/enable first
unless PhoenixKit.Entities.enabled?() do
  PhoenixKit.Entities.enable_system()
end
PhoenixKit.Entities.create_entity(%{name: "products", ...})
```

### Migration Architecture

- **PhoenixKit.Migrations.Postgres** - PostgreSQL-specific migrator with Oban-style versioning
- **PhoenixKit.Migrations.Postgres.V01** - Version 1: Basic authentication tables with role system
- **Mix.Tasks.PhoenixKit.Install** - Igniter-based installation for new projects
- **Mix.Tasks.PhoenixKit.Update** - Versioned updates for existing installations
- **Mix.Tasks.PhoenixKit.Gen.Migration** - Custom migration generator
- **Mix.Tasks.PhoenixKit.MigrateToDaisyui5** - Migration tool for daisyUI 5 upgrade

### Key Design Principles

- **No Circular Dependencies** - Optional Phoenix deps prevent import cycles
- **Library-First Architecture** - No OTP application, no supervision tree, can be used as dependency
  - No `Application.start/2` callback
  - No Telemetry supervisor (uses `Plug.Telemetry` in endpoint)
  - No dev-only routes (PageController removed)
  - Parent apps provide their own home pages and layouts
- **Professional Testing** - DataCase pattern with database sandbox
- **Production Ready** - Complete authentication system with security best practices
- **Clean Codebase** - Removed standard Phoenix template boilerplate (telemetry.ex, page controllers, API pipeline)

### Database Integration

- **PostgreSQL** - Primary database with Ecto integration
- **Repository Pattern** - Auto-detection or explicit configuration
- **Migration Support** - V01 migration with authentication, role, and settings tables
- **Role System Tables** - phoenix_kit_user_roles, phoenix_kit_user_role_assignments
- **Settings Table** - phoenix_kit_settings with key/value/timestamp storage
- **Race Condition Protection** - FOR UPDATE locking in Ecto transactions
- **Test Database** - Separate test database with sandbox

### Professional Features

- **Hex Publishing** - Complete package.exs configuration
- **Documentation** - ExDoc ready with comprehensive docs
- **Quality Tools** - Credo, Dialyzer, code formatting configured
- **Testing Framework** - Complete test suite with fixtures

## PhoenixKit Integration

### Setup Steps

1. **Install PhoenixKit**: Run `mix phoenix_kit.install --repo YourApp.Repo`
2. **Run Migrations**: Database tables created automatically (V16 includes OAuth providers and magic link registration)
3. **Add Routes**: Use `phoenix_kit_routes()` macro in your router
4. **Configure Mailer**: PhoenixKit auto-detects and uses your app's mailer, or set up email delivery in `config/config.exs`
5. **Configure Branding**: Set `project_title`, `project_logo`, and/or `project_icon` in `config/config.exs`
6. **Configure Layout** (Optional): Set custom layouts in `config/config.exs`
7. **Theme Support**: DaisyUI 5 theme system with 35+ themes is automatically enabled
8. **Settings Management**: Access admin settings at `{prefix}/admin/settings`
9. **Email System** (Optional): Enable email system and AWS SES integration

> **Note**: `{prefix}` represents your configured PhoenixKit URL prefix (default: `/phoenix_kit`).
> This can be customized via `config :phoenix_kit, url_prefix: "/your_custom_prefix"`.

### Integration Pattern

```elixir
# In your Phoenix app's config/config.exs
config :phoenix_kit,
  repo: MyApp.Repo,
  mailer: MyApp.Mailer  # Optional: Use your app's mailer (auto-detected by installer)

# Configure your app's mailer (PhoenixKit will use it automatically if mailer is set)
config :my_app, MyApp.Mailer, adapter: Swoosh.Adapters.Local

# Alternative: Configure PhoenixKit's built-in mailer (legacy approach)
# config :phoenix_kit, PhoenixKit.Mailer, adapter: Swoosh.Adapters.Local

# Configure Dashboard Branding (IMPORTANT for customization)
config :phoenix_kit,
  project_title: "My App",              # Displayed in dashboard header
  project_title_suffix: "",             # Suffix after title (default: "Dashboard", "" to remove)
  project_logo: "/images/logo.svg",     # URL/path to logo image (see theme-aware logos below)
  project_icon: "hero-cube",            # Heroicon name when no logo image (default: "hero-home")
  project_logo_height: "h-10",          # Tailwind height class (default: "h-8")
  project_logo_class: "rounded",        # Additional CSS classes for logo image
  project_home_url: "~/dashboard",      # Where logo links to (default: "/", see below)
  show_title_with_logo: false           # Show title text alongside logo (default: true)
```

### Logo Link URL Prefix Convention

The `project_home_url` supports a `~/` prefix for automatic URL prefix application:

- `"~/dashboard"` → `/phoenix_kit/dashboard` (prefix applied)
- `"/"` → `/` (no prefix, goes to site root)
- `"https://example.com"` → external URL (no change)

Use `~/` when linking to PhoenixKit routes, omit it for external URLs or site root.

### Theme-Aware Logos

Use SVG logos with `currentColor` for automatic theme adaptation. Use `project_logo_class: "text-base-content"` or `"text-primary"`. Theme stored in localStorage as `phx:theme`, applied via `data-theme` attribute.

### Dashboard Color Scheme Guide

**NEVER use hardcoded colors** (`bg-white`, `text-gray-800`, `bg-blue-500`). Use daisyUI semantic classes:

- **Base:** `bg-base-100/200/300`, `text-base-content`, `border-base-300`
- **Semantic:** `bg-primary`, `text-error`, `btn btn-primary`, `badge badge-success`
- **Opacity:** `text-base-content/70`, `bg-primary/10`

### Dashboard Theme Switcher

Config: `dashboard_themes: :all` (default) or `["system", "light", "dark", "nord", "dracula"]`

### Dashboard (Tabs, Subtabs, Context Selectors)

See `lib/phoenix_kit/dashboard/README.md` for full documentation. Quick access in LiveViews:
- Single context: `socket.assigns.current_context`
- Multi context: `socket.assigns.current_contexts_map[:key]`

### Dashboard Layout Performance (IMPORTANT)

**Do not pass all assigns to the dashboard layout.** Use `dashboard_assigns/1`:

```heex
<%!-- ❌ BAD - triggers layout diff on ANY assign change --%>
<PhoenixKitWeb.Layouts.dashboard {assigns}>

<%!-- ✅ GOOD - only passes assigns the layout uses --%>
<PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
```

Without this, a LiveView receiving 7 updates/second sends ~84KB/sec of redundant layout HTML. The `dashboard_assigns/1` function (auto-imported in LiveViews) extracts only layout-relevant assigns.

```elixir
# Configure Layout Integration (optional - defaults to PhoenixKit layouts)
config :phoenix_kit,
  layout: {MyAppWeb.Layouts, :app},        # Use your app's layout
  root_layout: {MyAppWeb.Layouts, :root},  # Optional: custom root layout
  page_title_prefix: "Auth"                # Optional: page title prefix

# Configure DaisyUI 5 Theme System (optional)
config :phoenix_kit,
  theme: %{
    theme: "auto",                   # Any of 35+ daisyUI themes or "auto"
    primary_color: "#3b82f6",       # Primary brand color (OKLCH format supported)
    storage: :local_storage,        # :local_storage, :session, :cookie
    theme_controller: true,         # Enable theme-controller integration
    categories: [:light, :dark, :colorful]  # Theme categories to show in switcher
  }

# Migrate existing installations to daisyUI 5
# Run: mix phoenix_kit.migrate_to_daisyui5

# Settings System Configuration (optional defaults)
config :phoenix_kit,
  default_settings: %{
    time_zone: "0",          # UTC+0 (GMT)
    date_format: "Y-m-d",    # ISO format: 2025-09-03
    time_format: "H:i"       # 24-hour format: 15:30
  }

# Password Requirements Configuration (optional)
# Configure password strength requirements for user registration and password changes
config :phoenix_kit, :password_requirements,
  min_length: 8,            # Minimum password length (default: 8)
  max_length: 72,           # Maximum password length (default: 72, bcrypt limit)
  require_uppercase: false, # Require at least one uppercase letter (default: false)
  require_lowercase: false, # Require at least one lowercase letter (default: false)
  require_digit: false,     # Require at least one digit (default: false)
  require_special: false    # Require at least one special character (!?@#$%^&*_) (default: false)

# Example: Strong password requirements for production
# config :phoenix_kit, :password_requirements,
#   min_length: 12,
#   require_uppercase: true,
#   require_lowercase: true,
#   require_digit: true,
#   require_special: true

# In your Phoenix app's mix.exs
def deps do
  [
    {:phoenix_kit, "~> 1.2"}
  ]
end

### Date Formatting Helpers

- Use `UtilsDate.format_datetime_with_user_format/1`, `format_date_with_user_format/1`, and
  `format_time_with_user_format/1` in templates to respect admin-configured formats.
- For hard-coded output, `UtilsDate.format_date/2` and `format_time/2` accept PHP-style format
  strings such as `"F j, Y"` or `"h:i A"`.

### Optional Authentication Modules

- **OAuth & Magic Link registration:** Setup instructions, environment variables, and feature
  details now live in `guides/oauth_and_magic_link_setup.md`. Review that guide when enabling the
  optional authentication flows in a host application.



## Key File Structure

### Core Files

- `lib/phoenix_kit.ex` - Main API module
- `lib/phoenix_kit/users/auth.ex` - Authentication context
- `lib/phoenix_kit/users/auth/user.ex` - User schema
- `lib/phoenix_kit/users/auth/user_token.ex` - Token management
- `lib/phoenix_kit/users/magic_link.ex` - Magic link authentication
- `lib/phoenix_kit/users/magic_link_registration.ex` - Magic link registration (V16+)
- `lib/phoenix_kit/users/oauth.ex` - OAuth authentication context (V16+)
- `lib/phoenix_kit/users/oauth_provider.ex` - OAuth provider schema (V16+)
- `lib/phoenix_kit/users/role*.ex` - Role system (Role, RoleAssignment, Roles)
- `lib/phoenix_kit/settings.ex` - Settings context and management
- `lib/phoenix_kit/utils/date.ex` - Date formatting utilities with Settings integration
- `lib/phoenix_kit/emails/*.ex` - Email system modules
- `lib/phoenix_kit/mailer.ex` - Mailer with automatic email system integration

### Web Integration

- `lib/phoenix_kit_web/router.ex` - Library router (dev/test only, parent apps use `phoenix_kit_routes()`)
- `lib/phoenix_kit_web/integration.ex` - Router integration macro for parent applications
- `lib/phoenix_kit_web/endpoint.ex` - Phoenix endpoint (uses `Plug.Telemetry`, no custom supervisor)
- `lib/phoenix_kit_web/users/oauth_controller.ex` - OAuth authentication controller (V16+)
- `lib/phoenix_kit_web/users/magic_link_registration_controller.ex` - Magic link registration controller (V16+)
- `lib/phoenix_kit_web/users/magic_link_registration.ex` - Registration completion LiveView (V16+)
- `lib/phoenix_kit_web/users/auth.ex` - Web authentication plugs
- `lib/phoenix_kit_web/users/*.ex` - LiveView components (login, registration, settings, etc.)
- `lib/phoenix_kit_web/live/*.ex` - Admin interfaces (dashboard, users, sessions, settings, modules)
- `lib/phoenix_kit_web/live/settings.ex` - Settings management interface
- `lib/phoenix_kit_web/live/modules/emails/*.ex` - Email system LiveView interfaces
- `lib/phoenix_kit_web/components/core_components.ex` - UI components
- `lib/phoenix_kit_web/components/layouts.ex` - Layout module (fallback for parent apps)
- `lib/phoenix_kit_web/controllers/error_html.ex` - HTML error rendering
- `lib/phoenix_kit_web/controllers/error_json.ex` - JSON error rendering

### Migration & Config

- `lib/phoenix_kit/migrations/postgres/v01.ex` - V01 migration (basic auth)
- `lib/phoenix_kit/migrations/postgres/v07.ex` - V07 migration (email system tables)
- `lib/phoenix_kit/migrations/postgres/v09.ex` - V09 migration (email blocklist)
- `lib/phoenix_kit/migrations/postgres/v16.ex` - V16 migration (OAuth providers table)
- `lib/mix/tasks/phoenix_kit.migrate_to_daisyui5.ex` - DaisyUI 5 migration tool
- `config/config.exs` - Library configuration
- `mix.exs` - Project and package configuration
- `scripts/aws_ses_sqs_setup.sh` - AWS SES infrastructure automation

### DaisyUI 5 Assets

- `priv/static/assets/phoenix_kit_daisyui5.css` - Modern CSS with @plugin directives
- `priv/static/assets/phoenix_kit_daisyui5.js` - Enhanced theme system with controller integration
- `priv/static/examples/tailwind_config_daisyui5.js` - Tailwind CSS 3 example config
- `priv/static/examples/tailwind_css4_config.css` - Tailwind CSS 4 example config

## Development Workflow

PhoenixKit supports a complete professional development workflow:

1. **Development** - Local development with PostgreSQL
2. **Testing** - Comprehensive test suite with database integration
3. **Quality** - Static analysis and type checking
4. **Documentation** - Generated docs with usage examples
5. **Publishing** - Ready for Hex.pm with proper versioning
```
