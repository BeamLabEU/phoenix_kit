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

### 🏷️ Version Management Protocol

**Current Version**: 1.3.3 (in mix.exs)
**Version Strategy**: Semantic versioning (MAJOR.MINOR.PATCH)
**Migration Version**: V17 (latest migration version with entities system and plural display names)

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
- ✅ Tests pass: `mix test` (run existing tests to ensure no regressions)
- ✅ Code formatted: `mix format`
- ✅ Credo passes: `mix credo --strict`
- ✅ CI checks pass: Verify GitHub Actions workflow succeeds
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

### Helper Functions: Use Components, Not Private Functions

**CRITICAL RULE**: Never create private helper functions (`defp`) that are called directly from HEEX templates.

**❌ WRONG - Compiler Cannot See Usage:**

```elixir
# lib/my_app_web/live/users_live.ex
defmodule MyAppWeb.UsersLive do
  use MyAppWeb, :live_view

  # ❌ BAD: Compiler shows "function format_date/1 is unused"
  defp format_date(date) do
    Calendar.strftime(date, "%B %d, %Y")
  end
end
```

```heex
<!-- lib/my_app_web/live/users_live.html.heex -->
{format_date(user.created_at)}  <%!-- ❌ Compiler doesn't see this call --%>
```

**✅ CORRECT - Use Phoenix Components:**

```elixir
# lib/phoenix_kit_web/components/core/time_display.ex
defmodule PhoenixKitWeb.Components.Core.TimeDisplay do
  use Phoenix.Component

  @doc """
  Displays formatted date.

  ## Examples
      <.formatted_date date={user.created_at} />
  """
  attr :date, :any, required: true
  attr :format, :string, default: "%B %d, %Y"

  def formatted_date(assigns) do
    ~H"""
    <span>{Calendar.strftime(@date, @format)}</span>
    """
  end

  # ✅ GOOD: Private helper INSIDE component
  defp format_time(time), do: ...
end
```

```heex
<!-- lib/my_app_web/live/users_live.html.heex -->
<.formatted_date date={user.created_at} />  <%!-- ✅ Compiler sees component usage --%>
```

**Why This Matters:**

1. **Compiler Visibility**: Component calls (`<.component />`) are visible to Elixir compiler, function calls in templates are not
2. **Type Safety**: Components use `attr` macros for compile-time validation
3. **Reusability**: Components work across all LiveView modules without duplication
4. **Documentation**: Components have structured `@doc` with examples
5. **No Warnings**: Prevents false-positive "unused function" warnings

**Where to Put Components:**

- **New helper component**: `lib/phoenix_kit_web/components/core/[category].ex`
- **Import in**: `lib/phoenix_kit_web.ex` → `core_components()` function
- **Available everywhere**: Automatically imported in all LiveViews

**Existing Core Component Categories:**

- `badge.ex` - Role badges, status badges, code status badges
- `time_display.ex` - Relative time, expiration dates, age badges
- `user_info.ex` - User roles, user counts, user statistics
- `button.ex`, `input.ex`, `select.ex`, etc. - Form components

**Adding New Component Category:**

1. Create file: `lib/phoenix_kit_web/components/core/my_category.ex`
2. Add import: `lib/phoenix_kit_web.ex` → `import PhoenixKitWeb.Components.Core.MyCategory`
3. Use in templates: `<.my_component attr={value} />`

**Example: Adding New Helper Component:**

```elixir
# 1. Create component file
# lib/phoenix_kit_web/components/core/currency.ex
defmodule PhoenixKitWeb.Components.Core.Currency do
  use Phoenix.Component

  attr :amount, :integer, required: true
  attr :currency, :string, default: "USD"

  def price(assigns) do
    ~H"""
    <span class="font-semibold">{format_price(@amount, @currency)}</span>
    """
  end

  defp format_price(amount, "USD"), do: "$#{amount / 100}"
  defp format_price(amount, "EUR"), do: "€#{amount / 100}"
end

# 2. Add import to lib/phoenix_kit_web.ex
def core_components do
  quote do
    # ... existing imports ...
    import PhoenixKitWeb.Components.Core.Currency  # ← Add this
  end
end

# 3. Use in any LiveView template
# <.price amount={product.price_cents} currency="USD" />
```

**Component Best Practices:**

1. **One category per file**: Group related helpers (time, currency, badges, etc.)
2. **Document everything**: Use `@doc`, `attr`, examples
3. **Private helpers OK**: Use `defp` INSIDE components for internal logic
4. **Validation**: Use `attr` with `:required`, `:default`, `:values`
5. **Naming**: Use clear, semantic names (`<.time_ago />` not `<.format_t />`)

**Migration Pattern:**

```elixir
# BEFORE (helper function)
defp format_time_ago(datetime) do
  # logic...
end

# Template: {format_time_ago(session.connected_at)}

# AFTER (component)
# Move to lib/phoenix_kit_web/components/core/time_display.ex
attr :datetime, :any, required: true
def time_ago(assigns) do
  ~H"""
  <span>{format_time_ago(@datetime)}</span>
  """
end
defp format_time_ago(datetime), do: # logic...

# Template: <.time_ago datetime={session.connected_at} />
```

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

### Rate Limiting Architecture

Protection against brute-force attacks, token enumeration, and spam using Hammer library.

**Protected Endpoints:**
- Login: 5/min per email + IP limiting
- Magic Link: 3/5min per email
- Password Reset: 3/5min per email
- Registration: 3/hour per email + 10/hour per IP

**Configuration:**
```elixir
# config/config.exs
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000, cleanup_interval_ms: 60_000]}

config :phoenix_kit, PhoenixKit.Users.RateLimiter,
  login_limit: 5, login_window_ms: 60_000,
  magic_link_limit: 3, magic_link_window_ms: 300_000,
  password_reset_limit: 3, password_reset_window_ms: 300_000,
  registration_limit: 3, registration_window_ms: 3_600_000,
  registration_ip_limit: 10, registration_ip_window_ms: 3_600_000
```

**Production:** Use `hammer_backend_redis` for distributed systems.

### Role System Architecture

- **PhoenixKit.Users.Role** - Role schema with system role protection
- **PhoenixKit.Users.RoleAssignment** - Many-to-many role assignments with audit trail
- **PhoenixKit.Users.Roles** - Role management API and business logic
- **PhoenixKitWeb.Live.Dashboard** - Admin dashboard with system statistics
- **PhoenixKitWeb.Live.Users** - User management interface with role controls
- **PhoenixKit.Users.Auth.register_user/1** - User registration with integrated role assignment

**Key Features:**

- **Three System Roles** - Owner, Admin, User with automatic assignment
- **Elixir Logic** - First user automatically becomes Owner
- **Admin Dashboard** - Built-in dashboard at `{prefix}/admin/dashboard` for system statistics
- **User Management** - Complete user management interface at `{prefix}/admin/users`
- **Role API** - Comprehensive role management with `PhoenixKit.Users.Roles`
- **Security Features** - Owner protection, audit trail, self-modification prevention
- **Scope Integration** - Role checks via `PhoenixKit.Users.Auth.Scope`

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

**Emails module:** See `lib/phoenix_kit_web/live/modules/emails/README.md` for architecture, configuration, and troubleshooting guidance.

**Blogging module:** See `lib/phoenix_kit_web/live/modules/blogging/README.md` for dual storage modes, multi-language support, and filesystem-based content management.

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
5. **Configure Layout** (Optional): Set custom layouts in `config/config.exs`
6. **Theme Support**: DaisyUI 5 theme system with 35+ themes is automatically enabled
7. **Settings Management**: Access admin settings at `{prefix}/admin/settings`
8. **Email System** (Optional): Enable email system and AWS SES integration

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
