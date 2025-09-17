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
- `mix phoenix_kit.update` - Update existing PhoenixKit installation to latest version
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

### Testing & Code Quality

- `mix test` - Run all tests (52 tests, no database required)
- `mix format` - Format code according to .formatter.exs
- `mix credo --strict` - Static code analysis
- `mix dialyzer` - Type checking (requires PLT setup)
- `mix quality` - Run all quality checks (format, credo, dialyzer, test)

⚠️ Ecto warnings are normal for library - tests focus on API validation

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

### 🏷️ Version Management Protocol

**Current Version**: 1.2.3 (in mix.exs)
**Version Strategy**: Semantic versioning (MAJOR.MINOR.PATCH)
**Migration Version**: V07 (latest migration version with comprehensive features)

**MANDATORY steps for version updates:**

#### 1. Version Update Requirements

```bash
# Current version locations to update:
# - mix.exs (@version constant)
# - CHANGELOG.md (new version entry)
# - README.md (if version mentioned in examples)
```

#### 2. Version Number Schema

- **MAJOR**: Breaking changes, backward incompatibility
- **MINOR**: New features, backward compatible
- **PATCH**: Bug fixes, backward compatible

#### 3. Update Process Checklist

**Step 1: Update mix.exs**
```elixir
@version "1.0.1"  # Increment from current version
```

**Step 2: Update CHANGELOG.md**
```markdown
## [1.0.1] - 2025-08-20

### Added
- Description of new features

### Changed  
- Description of modifications

### Fixed
- Description of bug fixes

### Removed
- Description of deletions
```

**Step 3: Commit Version Changes**
```bash
git add mix.exs CHANGELOG.md README.md
git commit -m "Update version to 1.0.1 with comprehensive changelog"
```

#### 4. Version Validation

**Before committing version changes:**
- ✅ Mix compiles without errors: `mix compile`
- ✅ Tests pass: `mix test`
- ✅ Code formatted: `mix format`
- ✅ CHANGELOG.md includes current date
- ✅ Version number incremented correctly

**⚠️ Critical Notes:**
- **NEVER ship without updating CHANGELOG.md**
- **ALWAYS validate version number increments**  
- **NEVER reference old version in new documentation**

### Publishing

- `mix hex.build` - Build package for Hex.pm
- `mix hex.publish` - Publish to Hex.pm (requires auth)
- `mix docs` - Generate documentation with ExDoc

## Code Style Guidelines

### Template Comments

**ALWAYS use EEx comments in Phoenix templates and components:**

```heex
<%!-- EEx comments (CORRECT) --%>
<div class="container">
  <%!-- This is the preferred way to comment in .heex templates --%>
  <h1>My App</h1>
</div>

<!-- HTML comments (AVOID) -->
<div class="container">
  <!-- This should be avoided in Phoenix templates -->
  <h1>My App</h1>
</div>
```

**Why EEx comments are preferred:**

- ✅ **Server-side processing** - EEx comments (`<%!-- --%>`) are processed server-side and never sent to the client
- ✅ **Performance** - Reduces HTML payload size since comments don't appear in browser
- ✅ **Security** - Internal comments and notes remain private on the server
- ✅ **Consistency** - Matches Phoenix LiveView and EEx template conventions

**When to use:**

- ✅ All `.heex` template files
- ✅ LiveView components
- ✅ Phoenix templates and layouts
- ✅ Documentation and section dividers in templates
- ✅ Temporary code comments during development

**Template Comment Examples:**

```heex
<%!-- Header Section --%>
<header class="w-full relative mb-6">
  <%!-- Back Button (Left aligned) --%>
  <.link navigate="/dashboard" class="btn btn-outline">
    Back to Dashboard
  </.link>

  <%!-- Title Section --%>
  <div class="text-center">
    <h1>Page Title</h1>
  </div>
</header>

<%!-- Main Content Area --%>
<main class="container mx-auto">
  <%!-- TODO: Add pagination controls --%>
  <div class="content">
    <!-- This HTML comment will appear in browser source -->
    <%!-- This EEx comment stays on the server --%>
  </div>
</main>
```

**Code Comments in Elixir Files:**

For regular Elixir code (`.ex` files), continue using standard Elixir comments:

```elixir
# Standard Elixir comment for code documentation
def my_function do
  # Inline comment explaining logic
  :ok
end
```

## Architecture

### Authentication Structure

- **PhoenixKit.Users.Auth** - Main authentication context with public interface
- **PhoenixKit.Users.Auth.User** - User schema with validations, authentication, and role helpers
- **PhoenixKit.Users.Auth.UserToken** - Token management for email confirmation and password reset
- **PhoenixKit.Users.MagicLink** - Magic link authentication system
- **PhoenixKit.Users.Auth.Scope** - Authentication scope management with role integration

### Role System Architecture

- **PhoenixKit.Users.Role** - Role schema with system role protection
- **PhoenixKit.Users.RoleAssignment** - Many-to-many role assignments with audit trail
- **PhoenixKit.Users.Roles** - Role management API and business logic
- **PhoenixKitWeb.Live.DashboardLive** - Admin dashboard with system statistics
- **PhoenixKitWeb.Live.UsersLive** - User management interface with role controls
- **PhoenixKit.Users.Auth.register_user/1** - User registration with integrated role assignment

**Key Features:**
- **Three System Roles** - Owner, Admin, User with automatic assignment
- **Elixir Logic** - First user automatically becomes Owner
- **Admin Dashboard** - Built-in dashboard at `{prefix}/admin/dashboard` for system statistics
- **User Management** - Complete user management interface at `{prefix}/admin/users`
- **Role API** - Comprehensive role management with `PhoenixKit.Users.Roles`
- **Security Features** - Owner protection, audit trail, self-modification prevention
- **Scope Integration** - Role checks via `PhoenixKit.Users.Auth.Scope`

### Settings System Architecture

- **PhoenixKit.Settings** - Settings context for system-wide configuration management
- **PhoenixKit.Settings.Setting** - Settings schema with key/value storage and timestamps
- **PhoenixKitWeb.Live.SettingsLive** - Settings management interface at `{prefix}/admin/settings`

**Core Settings:**
- **time_zone** - System timezone offset (UTC-12 to UTC+12)
- **date_format** - Date display format (Y-m-d, m/d/Y, d/m/Y, d.m.Y, d-m-Y, F j, Y)
- **time_format** - Time display format (H:i for 24-hour, h:i A for 12-hour)

**Key Features:**
- **Database Storage** - Settings persisted in phoenix_kit_settings table
- **Admin Interface** - Complete settings management at `{prefix}/admin/settings`
- **Default Values** - Fallback defaults for all settings (UTC+0, Y-m-d, H:i)
- **Validation** - Form validation with real-time preview examples
- **Integration** - Automatic integration with date formatting utilities

### Date Formatting Architecture

- **PhoenixKit.Utils.Date** - Date and time formatting utilities using Timex
- **Settings Integration** - Automatic user preference loading from Settings system
- **Template Integration** - Direct usage in LiveView templates with UtilsDate alias

**Core Functions:**
- **format_date/2** - Format dates with PHP-style format codes
- **format_time/2** - Format times with PHP-style format codes
- **format_datetime/2** - Format datetime values with date formats
- **format_datetime_with_user_format/1** - Auto-load user's date_format setting
- **format_date_with_user_format/1** - Auto-load user's date_format setting
- **format_time_with_user_format/1** - Auto-load user's time_format setting

**Supported Formats:**
- **Date Formats** - Y-m-d (ISO), m/d/Y (US), d/m/Y (European), d.m.Y (German), d-m-Y, F j, Y (Long)
- **Time Formats** - H:i (24-hour), h:i A (12-hour with AM/PM)
- **Examples** - Dynamic format preview with current date/time examples
- **Timex Integration** - Robust internationalized formatting with extensive format support

**Template Usage:**
```heex
<!-- Settings-aware formatting (recommended) -->
{UtilsDate.format_datetime_with_user_format(user.inserted_at)}
{UtilsDate.format_date_with_user_format(user.confirmed_at)}
{UtilsDate.format_time_with_user_format(Time.utc_now())}

<!-- Manual formatting -->
{UtilsDate.format_date(Date.utc_today(), "F j, Y")}
{UtilsDate.format_time(Time.utc_now(), "h:i A")}
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
- **Library-First** - No OTP application, can be used as dependency
- **Professional Testing** - DataCase pattern with database sandbox
- **Production Ready** - Complete authentication system with security best practices

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
2. **Configure Layout**: Optionally set custom layouts in `config/config.exs`
3. **Add Routes**: Use `phoenix_kit_routes()` macro in your router
4. **Configure Mailer**: PhoenixKit auto-detects and uses your app's mailer, or set up email delivery in `config/config.exs`
5. **Run Migrations**: Database tables created automatically
6. **Theme Support**: Optionally enable with `--theme-enabled` flag
7. **Settings Management**: Access admin settings at `{prefix}/admin/settings`

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

# Configure Layout Integration (optional - defaults to PhoenixKit layouts)
config :phoenix_kit,
  layout: {MyAppWeb.Layouts, :app},        # Use your app's layout
  root_layout: {MyAppWeb.Layouts, :root},  # Optional: custom root layout
  page_title_prefix: "Auth"                # Optional: page title prefix

# Configure DaisyUI 5 Theme System (optional)
config :phoenix_kit,
  theme_enabled: true,
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

# In your Phoenix app's mix.exs
def deps do
  [
    {:phoenix_kit, "~> 1.2"}
  ]
end

# Date Formatting in Templates
# Use Settings-aware functions for automatic user preference integration:
{UtilsDate.format_datetime_with_user_format(user.inserted_at)}
{UtilsDate.format_date_with_user_format(user.confirmed_at)}
{UtilsDate.format_time_with_user_format(Time.utc_now())}

# Manual formatting for specific use cases:
{UtilsDate.format_date(Date.utc_today(), "F j, Y")}  # "September 3, 2025"
{UtilsDate.format_time(Time.utc_now(), "h:i A")}     # "3:30 PM"
```

## Key File Structure

### Core Files

- `lib/phoenix_kit.ex` - Main API module
- `lib/phoenix_kit/users/auth.ex` - Authentication context
- `lib/phoenix_kit/users/auth/user.ex` - User schema
- `lib/phoenix_kit/users/auth/user_token.ex` - Token management
- `lib/phoenix_kit/users/magic_link.ex` - Magic link authentication
- `lib/phoenix_kit/users/role*.ex` - Role system (Role, RoleAssignment, Roles)
- `lib/phoenix_kit/settings.ex` - Settings context and management
- `lib/phoenix_kit/utils/date.ex` - Date formatting utilities with Settings integration

### Web Integration

- `lib/phoenix_kit_web/integration.ex` - Router integration macro
- `lib/phoenix_kit_web/users/auth.ex` - Web authentication plugs
- `lib/phoenix_kit_web/users/*_live.ex` - LiveView components
- `lib/phoenix_kit_web/live/*_live.ex` - Admin interfaces (Dashboard, Users, Sessions, Settings)
- `lib/phoenix_kit_web/live/settings_live.ex` - Settings management interface
- `lib/phoenix_kit_web/components/core_components.ex` - UI components

### Migration & Config

- `lib/phoenix_kit/migrations/postgres/v01.ex` - V01 migration
- `lib/mix/tasks/phoenix_kit.migrate_to_daisyui5.ex` - DaisyUI 5 migration tool
- `config/config.exs` - Library configuration
- `mix.exs` - Project and package configuration

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