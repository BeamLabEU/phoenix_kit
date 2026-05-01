# PhoenixKit — A Foundation for Building Your Elixir Phoenix Apps

[![Hex Version](https://img.shields.io/hexpm/v/phoenix_kit)](https://hex.pm/packages/phoenix_kit)
[![CI](https://github.com/BeamLabEU/phoenix_kit/workflows/CI/badge.svg)](https://github.com/BeamLabEU/phoenix_kit/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/BeamLabEU/phoenix_kit/branch/main/graph/badge.svg)](https://codecov.io/gh/BeamLabEU/phoenix_kit)

We are actively building PhoenixKit, a foundation for building your Elixir Phoenix apps — SaaS, social networks, ERP systems, marketplaces, internal tools, AI-powered apps, community platforms, and more. Our goal is to eliminate the need to reinvent the wheel every time you start a new project.

**🚧 Early Access - We Need Your Feedback!**

PhoenixKit is under heavy development and we're looking for early adopters to test, provide feedback, and help shape the future of this toolkit. If you're building with Phoenix and want to skip the boilerplate setup, we'd love to have you try it out and share your experience.

With PhoenixKit, you will be able to create Elixir/Phoenix apps much faster and focus on your unique business logic instead of reimplementing common patterns.

## 📖 Documentation

- **[Integration Guide](guides/integration.md)** - Complete guide for using PhoenixKit as a dependency, with API reference and examples. Optimized for AI assistants (Claude, Cursor, Copilot, Tidewave MCP).
- **[All Guides](guides/README.md)** - Full list of development guides

## Installation

One command sets up the dependency, configuration, routes, mailer, and migrations:

```bash
mix igniter.install phoenix_kit
```

> **Prerequisite:** the `igniter_new` archive (one-time setup, same as `phx_new`):
>
> ```bash
> mix archive.install hex igniter_new
> ```

This will automatically:

- Add `{:phoenix_kit, "~> 1.7"}` to your `mix.exs` and fetch deps
- Auto-detect your Ecto repository
- **Validate PostgreSQL compatibility** with adapter detection
- Generate migration files for authentication tables
- **Optionally run migrations interactively** for instant setup
- Add PhoenixKit configuration to `config/config.exs`
- Configure mailer settings for development
- **Create production mailer templates** in `config/prod.exs`
- Add authentication routes to your router

See [Installation Options](#installation-options) below for advanced flags and fallback flows.

## 📦 Current PhoenixKit Features / Modules:

```
✅ One-command install via Igniter (`mix igniter.install phoenix_kit`, updates via `mix phoenix_kit.update`) 
✅ Tailwind and DaisyUI integration
✅ App layout integration
✅ App database integration (Postgres only for now)
✅ Custom slug prefix (default: `/phoenix_kit`)

✅ Backend Admin module

✅ User Module
  ✅ Registration
  ✅ Login
  ✅ Logout
  ✅ Magic link
  ✅ Email confirmation (waiting Email Module)
  ✅ Fail2ban (userbased, ip based, region based)
  ✅ Password reset
  ✅ User roles
  ✅ Custom user fields
    ✅ JSONB storage for flexibility
  ✅ Location of registration (ip, country, region, city)
  ✅ User's timezone (and mismatch detection)
  ✅ User's locale
  ✅ OAuth (google, facebook)


✅ Modules Manager

✅ Session Manager Module

✅ Settings
    ✅ General
    ✅ App title
    ✅ Global app timezone (switched from timex to native elixir)
    ✅ Global time format (switched from timex to native elixir)
    ✅ Language configuration

✅ Languages (Backend and frontend languages, broken down to countries and regions)
    ✅ Backend languages
    ✅ Frontend enduser languages, broken down and organized by countries and regions

✅ Users Module
    ✅ Role management
    ✅ Referral Program

✅ User Relationship Module (for User Generated Content/UGC)

✅ Maintenance Mode Module

✅ Email Module
    ✅ AWS SES integration

✅ Entities Module (dynamic content types)
    ✅ Dynamic entity type creation
    ✅ Flexible field schemas (13 field types)
    ✅ JSONB storage for flexibility
    ✅ Full CRUD interfaces
    ✅ Settings management

✅ Media Module
    ✅ Photos and Videos
    ✅ Local and cloud multiple storages
    ✅ Image resizing 
    ✅ Video resizing
✅ Publishing Module
     ✅ 2 types supported: timed and slug based
     ✅ Multilingual publishing
     ✅ Timezone support

✅ Posts Module (for User Generated Content/UGC)

✅ Sitemap Module

✅ AI Module
     ✅ OpenRouter Integration

✅ Billing Module
    - Invoices
    - Payment
      - Integration
        - Stripe
        - PayPal
    - Orders
  - Membership / Subscription Module

✅ Basic UI Components
    ✅ [Draggable List](guides/draggable_list_component.md) - Drag-and-drop grid/list component
```


## 🛣️ Roadmap / Ideas / Feature requests

--- Next priority

- Newsletter Module
- Notifications Module
- Cookies Module
- Complience and Legal Module
    - Cookies usage
    - Terms Of Service
    - Acceptable Use
    - GDPR (General Data Protection Regulation) for EU users
    - CCPA (California Consumer Privacy Act) for California users
    - Data Retention Policy
    - Privacy Policy
- Customer service Module
    - Chat
- Jobs Module (Oban powered)
- E-commerce Module
    - E-commerce Storefront
    - Physical products
    - Digital and downloadable products
- Missing features for User Auth Module
  - 2FA
  - User impersonation
  - New device notification

--- To sort items

- Design / templates / themes
- Integration with notification providers (Twilio, etc...)
- Media / Gallery (with s3 backend)
- Video (Video processing, streaming, Adaptive Bitrate (ABR): stream in multiple bitrates and resolutions for difference devices, HTTP Live Streaming (HLS): reduce bandwidth usage, playback latency, and buffering, H.264, H.265, VP8 & VP9: optimized next-generation video codecs)
- Audio
- Media / Gallery
- Local / External storage support (AWS S3, Azure Storage, Google Storage, Cloudflare R2, and DigitalOcean Spaces)
- CDN
- Comments
- Search
- Blocks
- Sliders
- Video player (mp4, youtube, etc)
- Booking Module (Calendar based)
- Popups Module
- Contact Us Module
- SEO Module (sitemap, open graph)
- What’s New Module
- Internal Chat Module (https://github.com/basecamp/once-campfire)
- DB Manager Module
    - Export / Import
    - Snapshots
    - Backups (onsite/offsite)
- Feedback Module
- Roadmap / Ideas Module
- CRM Module
- App Analytics / BI Module
  - ClickHouse backend
  - Events
  - Charts, trends and notifications
- API Module
- Cron Modules
- Forms Module
- Cluster Module

💡 Send your ideas and suggestions about any existing modules and features our way. Start building your apps today!

## Installation Options

The recommended path is `mix igniter.install phoenix_kit` (see the [quick install](#installation) at the top of this README). The sections below cover advanced options and fallback flows.

### Installer options

```bash
# Specify custom repository
mix igniter.install phoenix_kit --repo MyApp.Repo

# Use PostgreSQL schema prefix for table isolation
mix igniter.install phoenix_kit --prefix "auth" --create-schema

# Specify custom router file path
mix igniter.install phoenix_kit --router-path lib/my_app_web/router.ex
```

The same flags work with `mix phoenix_kit.install` if the dep is already in your project.

### Fallback: two-step install

If you'd rather not use the `igniter_new` archive, add the dep yourself and invoke the installer directly — `:igniter` is already pulled in transitively, so this works on any Phoenix project:

```elixir
# mix.exs
def deps do
  [
    {:phoenix_kit, "~> 1.7"}
  ]
end
```

```bash
mix deps.get
mix phoenix_kit.install
```

### Manual Installation

For full control, skip the installer entirely:

1. Add `{:phoenix_kit, "~> 1.7"}` to `mix.exs`
2. Run `mix deps.get && mix phoenix_kit.gen.migration`
3. Configure repository: `config :phoenix_kit, repo: MyApp.Repo`
4. Add `phoenix_kit_routes()` to your router
5. Run `mix ecto.migrate`

## Quick Start

Visit these URLs after installation:

- `http://localhost:4000/{prefix}/users/register` - User registration
- `http://localhost:4000/{prefix}/users/log-in` - User login

Where `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

## Configuration

### Basic Setup

```elixir
# config/config.exs (automatically added by installer)
config :phoenix_kit,
  repo: YourApp.Repo,
  from_email: "noreply@yourcompany.com",  # Required for email notifications
  from_name: "Your Company Name"          # Optional, defaults to "PhoenixKit"

# Production mailer (see config/prod.exs for more options)
config :phoenix_kit, PhoenixKit.Mailer,
  adapter: Swoosh.Adapters.SMTP,
  relay: "smtp.your-provider.com",
  username: System.get_env("SMTP_USERNAME"),
  password: System.get_env("SMTP_PASSWORD"),
  port: 587
```

### Layout Integration

```elixir
# Use your app's layout (optional)
config :phoenix_kit,
  layout: {YourAppWeb.Layouts, :app},
  root_layout: {YourAppWeb.Layouts, :root}
```

### Email Configuration

PhoenixKit supports multiple email providers with automatic setup assistance:

#### AWS SES (Complete Setup)

For AWS SES, PhoenixKit automatically configures required dependencies and HTTP client:

```elixir
# Add to mix.exs dependencies (done automatically by installer when needed)
{:gen_smtp, "~> 1.2"}

# Application supervisor includes Finch automatically
{Finch, name: Swoosh.Finch}

# Production configuration
config :phoenix_kit, PhoenixKit.Mailer,
  adapter: Swoosh.Adapters.AmazonSES,
  region: "eu-north-1"  # or "eu-north-1", "eu-west-1", etc.
```

**AWS SES Checklist:**

- ✅ Create AWS IAM user with SES permissions (`ses:*`)
- ✅ Verify sender email address in AWS SES Console
- ✅ Verify recipient emails (if in sandbox mode)
- ✅ Ensure AWS region matches your verification region
- ✅ Request production access to send to any email
- ✅ Configure AWS credentials in Settings UI or via config

#### Other Email Providers

```elixir
# SendGrid
config :phoenix_kit, PhoenixKit.Mailer,
  adapter: Swoosh.Adapters.Sendgrid,
  api_key: System.get_env("SENDGRID_API_KEY")

# Mailgun
config :phoenix_kit, PhoenixKit.Mailer,
  adapter: Swoosh.Adapters.Mailgun,
  api_key: System.get_env("MAILGUN_API_KEY"),
  domain: System.get_env("MAILGUN_DOMAIN")
```

**Note:** Run `mix deps.compile phoenix_kit --force` after changing configuration.

### OAuth Configuration

Enable social authentication (Google, Apple, GitHub) through admin UI at `{prefix}/admin/settings`.
Built-in setup instructions included. For reverse proxy deployments, ensure `X-Forwarded-Proto` header is set:

```nginx
proxy_set_header X-Forwarded-Proto $scheme;
```

See [OAuth Setup Guide](guides/oauth-and-magic-link-setup.md) for details.

### Advanced Options

- Custom URL prefix: `phoenix_kit_routes("/authentication")`
- PostgreSQL schemas: `mix phoenix_kit.install --prefix "auth" --create-schema`
- Custom repository: `mix phoenix_kit.install --repo MyApp.CustomRepo`

## Routes

### User Authentication Routes

- `GET {prefix}/users/register` - Registration form
- `GET {prefix}/users/log-in` - Login form
- `GET {prefix}/users/reset-password` - Password reset
- `GET {prefix}/users/confirm/:token` - Email confirmation
- `DELETE {prefix}/users/log-out` - Logout endpoint

### User Dashboard Routes (when enabled)

- `GET {prefix}/dashboard` - User dashboard home
- `GET {prefix}/dashboard/settings` - User settings
- `GET {prefix}/dashboard/settings/confirm-email/:token` - Email confirmation

### Admin Routes (Owner/Admin only)

- `GET {prefix}/admin` - Admin dashboard
- `GET {prefix}/admin/users` - User management

## API Usage

### Current User Access

```elixir
# In your controller or LiveView
user = conn.assigns[:phoenix_kit_current_user]

# Or using Scope system
scope = socket.assigns[:phoenix_kit_current_scope]
PhoenixKit.Users.Auth.Scope.authenticated?(scope)
```

### Role-Based Access

```elixir
# Check user roles
PhoenixKit.Users.Roles.user_has_role?(user, "Admin")

# Promote user to admin
{:ok, _} = PhoenixKit.Users.Roles.promote_to_admin(user)

# Use in LiveView sessions
on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}]
```

### Authentication Helpers

```elixir
# In your LiveView sessions
on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}]
on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}]
```

## Database Schema

PhoenixKit creates these PostgreSQL tables:

- `phoenix_kit_users` - User accounts with email, names, status
- `phoenix_kit_users_tokens` - Authentication tokens (session, reset, confirm)
- `phoenix_kit_user_roles` - System and custom roles
- `phoenix_kit_user_role_assignments` - User-role mappings with audit trail
- `phoenix_kit_role_permissions` - Module-level permission grants per role (V53)
- `phoenix_kit_schema_versions` - Migration version tracking

## Role-Based Access Control

### System Roles

- **Owner** - Full system access (first user)
- **Admin** - Management privileges
- **User** - Standard access (default)

### Role Management

```elixir
# Check roles
PhoenixKit.Users.Roles.get_user_roles(user)
# => ["Admin", "User"]

# Role promotion/demotion
PhoenixKit.Users.Roles.promote_to_admin(user)
PhoenixKit.Users.Roles.demote_to_user(user)

# Create custom roles
PhoenixKit.Users.Roles.create_role(%{name: "Manager", description: "Team lead"})
```

### Module-Level Permissions (V53)

PhoenixKit includes a granular permission system that controls which roles can access which admin sections and feature modules.

**24 permission keys**: 5 core sections (dashboard, users, media, settings, modules) + 19 feature modules

**Access rules**:
- **Owner** bypasses all checks (full access always)
- **Admin** seeded with all 24 keys by default
- **Custom roles** start with no permissions, assigned via matrix UI or API

```elixir
# Grant/revoke permissions for a role
Permissions.grant_permission(role_id, "billing", admin_id)
Permissions.revoke_permission(role_id, "billing")
Permissions.set_permissions(role_id, ["dashboard", "users", "billing"], admin_id)

# Query permissions
Permissions.get_permissions_for_role(role_id)    # ["dashboard", "users", ...]
Permissions.role_has_permission?(role_id, "shop") # true/false

# Check access via Scope (in LiveViews)
Scope.has_module_access?(scope, "billing")       # true/false
Scope.has_any_module_access?(scope, ["billing", "shop"])
Scope.system_role?(scope)                        # Owner or Admin?
```

**Admin UI**: Interactive permission matrix at `{prefix}/admin/users/permissions` and inline editor on the Roles page.

**Route enforcement**: `phoenix_kit_ensure_admin` and `phoenix_kit_ensure_module_access` on_mount hooks enforce permissions at the route level. Sidebar navigation is gated per-user based on granted permissions.

### Module System

PhoenixKit uses a modular architecture where features can be enabled/disabled at runtime. **All modules are disabled by default** and must be enabled before use.

**Enable via Admin UI:**
Visit `{prefix}/admin/modules` to toggle modules on/off.

**Enable via Code:**
```elixir
# Check if a module is enabled
PhoenixKit.Modules.AI.enabled?()        # => false (default)
PhoenixKit.Modules.Entities.enabled?()  # => false (default)

# Enable modules before use
PhoenixKit.Modules.AI.enable_system()
PhoenixKit.Modules.Entities.enable_system()
PhoenixKit.Modules.Posts.enable_system()
PhoenixKit.Emails.enable_system()
PhoenixKit.Billing.enable_system()

# Disable when no longer needed
PhoenixKit.Modules.AI.disable_system()
```

**Important**: Attempting to use a disabled module's API functions or admin pages will result in errors or redirects. Always enable modules before:
- Calling their API functions (e.g., `PhoenixKit.Modules.AI.ask/3`)
- Visiting their admin pages (e.g., `/{prefix}/admin/ai/endpoints`)

### Built-in Admin Interface

**Core Administration:**
- `{prefix}/admin` - System statistics and overview
- `{prefix}/admin/users` - User management with role controls
- `{prefix}/admin/users/permissions` - Permission matrix for all roles
- `{prefix}/admin/sessions` - Active session management
- `{prefix}/admin/modules` - Enable/disable PhoenixKit modules
- `{prefix}/admin/settings` - System settings (timezone, date/time formats)

**Content & Data:**
- `{prefix}/admin/publishing` - Blog posts and articles management
- `{prefix}/admin/posts` - User-generated content (social posts)
- `{prefix}/admin/entities` - Dynamic content types

**Communication:**
- `{prefix}/admin/emails` - Email logs and delivery tracking
- `{prefix}/admin/emails/dashboard` - Email metrics and analytics

**AI Module:**
- `{prefix}/admin/ai/endpoints` - AI provider endpoints
- `{prefix}/admin/ai/prompts` - Reusable prompt templates
- `{prefix}/admin/ai/usage` - AI usage statistics

**Billing & Payments:**
- `{prefix}/admin/billing` - Billing dashboard
- `{prefix}/admin/billing/orders` - Order management
- `{prefix}/admin/billing/invoices` - Invoice management
- `{prefix}/admin/billing/subscriptions` - Subscription management

**Settings & Configuration:**
- `{prefix}/admin/settings/languages` - Multi-language configuration
- `{prefix}/admin/settings/media` - Storage buckets and image dimensions
- `{prefix}/admin/settings/sitemap` - Sitemap generation settings
- `{prefix}/admin/settings/seo` - SEO configuration

## Architecture

PhoenixKit follows professional library patterns:

- **OTP Application**: Ships with its own supervision tree (`PhoenixKit.Application`) for background workers, caching, and scheduled jobs
- **Dynamic Repository**: Uses your existing Ecto repo
- **Versioned Migrations**: Oban-style schema management
- **PostgreSQL Only**: Optimized for production databases

## Contributing

See [CONTRIBUTING.md](https://github.com/BeamLabEU/phoenix_kit/blob/main/CONTRIBUTING.md) for detailed instructions on setting up a development environment and contributing to PhoenixKit.

## License

MIT License - see [CHANGELOG.md](CHANGELOG.md) for version history.

---

Built in 🇪🇺🇪🇪 with ❤️ for the Elixir Phoenix community.
