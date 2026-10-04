# PhoenixKit — A Foundation for Building Your Elixir Phoenix Apps

[![Hex Version](https://img.shields.io/hexpm/v/phoenix_kit)](https://hex.pm/packages/phoenix_kit)
[![CI](https://github.com/BeamLabEU/phoenix_kit/workflows/CI/badge.svg)](https://github.com/BeamLabEU/phoenix_kit/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/BeamLabEU/phoenix_kit/branch/main/graph/badge.svg)](https://codecov.io/gh/BeamLabEU/phoenix_kit)

We are actively building PhoenixKit, a foundation for building your Elixir Phoenix apps — SaaS, social networks, ERP systems, marketplaces, internal tools, AI-powered apps, community platforms, and more. Our goal is to eliminate the need to reinvent the wheel every time you start a new project.

With PhoenixKit, you are able to create Elixir/Phoenix apps much faster and focus on your unique business logic instead of reimplementing common patterns.

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

- Add `{:phoenix_kit, "~> 2.0"}` to your `mix.exs` and fetch deps
- Auto-detect your Ecto repository
- **Validate PostgreSQL compatibility** with adapter detection
- Generate migration files for authentication tables
- **Optionally run migrations interactively** for instant setup
- Add PhoenixKit configuration to `config/config.exs`
- Configure mailer settings for development
- **Create production mailer templates** in `config/prod.exs`
- Add authentication routes to your router

See [Installation Options](#installation-options) below for advanced flags and fallback flows.

### If the build fails on `mdex` / `mdex_native`

PhoenixKit renders markdown through `mdex`, which normally downloads a
precompiled NIF. Two situations make it build from source instead, and both
need `rustler` — which is a *host* dependency, because an optional dep is not
resolved transitively:

```elixir
# mix.exs
{:rustler, ">= 0.0.0", optional: true}
```

- **Your CPU has no AVX support**, or you are on a platform with no prebuilt
  binary. Set `MDEX_NATIVE_BUILD=1` and rebuild; you will need a Rust toolchain.
- **Your environment blocks the download** (an air-gapped or proxied CI). Same
  fix.

Without `rustler` present the build fails with a compilation error from
`mdex_native` rather than anything naming PhoenixKit, which is why this is
worth stating up front.

## Updating

`mix phoenix_kit.update` migrates PhoenixKit's schema and repairs the
configuration it depends on; `mix phoenix_kit.status` and
`mix phoenix_kit.doctor` report what is out of date.

**Oban's schema follows the Oban library, not PhoenixKit's migrations.**
PhoenixKit creates Oban's tables once, at the version the Oban of that day
shipped; a newer Oban can need a newer schema (Oban 2.24's version 14 —
without it every unique job insert fails, cron included).
`mix phoenix_kit.update` compares the version on `oban_jobs` with what the
installed Oban expects and, when it is behind, adds a
`phoenix_kit_update_oban_vNN_to_vMM` migration that runs with the rest —
even when PhoenixKit itself is already current. `status` shows the version,
`doctor` warns when it is behind, and the application logs one warning at boot.

## Upgrading to 2.0

**New installs need nothing from this section.**

2.0 consolidates the migration chain: `V01`..`V134` no longer exist as
individual modules, and `V135` is a baseline that produces their cumulative
schema in one step.

- **Database already at `V135` or above** — nothing special. The baseline is
  gated by the version comment exactly like any other version, so this is an
  ordinary delta run.
- **Database below `V135`** — 2.0 **refuses to migrate it** and says so with a
  `BelowFloorError` rather than doing anything silently. Land on the last
  `1.7.x` release first, which still carries the full chain:

  ```elixir
  {:phoenix_kit, "~> 1.7.236"}   # the bridge
  ```

  Run `mix phoenix_kit.update`, confirm the version comment has reached `V135`
  or higher, and only then move the pin to `~> 2.0`.

2.0 also repairs schema damage left by a long-standing migration-ordering
defect that affected essentially every install created by
`mix phoenix_kit.install`. One consequence changes behavior you may rely on:
the comments foreign key is corrected from `ON DELETE CASCADE` to
`ON DELETE SET NULL`, so deleting a user no longer deletes their comments.

Read the full guide before upgrading a production database:
[Upgrading to PhoenixKit 2.0](https://github.com/BeamLabEU/phoenix_kit/blob/main/dev_docs/guides/2026-08-07-upgrading-to-2.0-guide.md).

## 📦 What Ships With This Package (Core)

Everything below is part of the `phoenix_kit` Hex package itself — no extra dependency needed. (PhoenixKit also has a growing family of separately-versioned companion packages — see "Companion Modules" below.)

```
✅ One-command install via Igniter (`mix igniter.install phoenix_kit`, updates via `mix phoenix_kit.update`)
✅ Tailwind and DaisyUI integration
✅ App layout integration
✅ App database integration (Postgres only for now)
✅ Custom slug prefix (default: `/phoenix_kit`)
✅ Versioned migration chain shared across the whole PhoenixKit ecosystem
   (170+ tables at V174 once every module is installed; core alone ships ~25)

✅ Backend Admin module
    ✅ Modules Manager — enable/disable installed modules at runtime, `/admin/modules`,
       backed by a live Hex.pm catalog of known companion packages
    ✅ Session Manager — active session listing/management, `/admin/users/sessions`
    ✅ Activity Feed — audit trail of business-level actions, `/admin/activity`
    ✅ Notifications — per-user inbox driven by the activity feed, mute-by-type
       preferences, external delivery channels (Email, Telegram), digest cron
    ✅ Integrations system — centralized OAuth/API-key/bot-token credential
       storage, system-wide and per-user scopes, `/admin/settings/integrations`
    ✅ Audit Log — tracks sensitive admin actions (password resets, user edits)
    ✅ Mentions — cross-module `@`-mentions and `#`-record links
    ✅ Annotations — shape overlays on media files (rectangle/circle/polygon/freehand)
    ✅ Dashboard tab system — extensible admin + user-dashboard navigation,
       `mix phoenix_kit.gen.admin.page` generator for custom pages

✅ User Module
  ✅ Registration
  ✅ Login
  ✅ Logout
  ✅ Magic link
  ✅ Email confirmation (enforced at every auth entry point; `require_email_confirmation` setting)
  ✅ Rate limiting on public auth endpoints (Hammer-backed, per-endpoint)
  ✅ New-login security alerts (unrecognized device/IP → email + activity entry)
  ✅ Password reset
  ✅ User roles
  ✅ Custom user fields
    ✅ JSONB storage for flexibility
  ✅ Location of registration (ip, country, region, city)
  ✅ User's timezone (and mismatch detection)
  ✅ User's locale
  ✅ OAuth (Google, GitHub, Facebook — Apple sign-in was removed, see CHANGELOG)
  ✅ Multi-session support, incl. admin "log in as user" (impersonation)

✅ Users Module
    ✅ Role management
    ✅ Module-level, granular per-role permissions
    ✅ Referral Program

✅ Maintenance Mode Module

✅ Email
    ✅ Pluggable delivery via any Swoosh adapter (AWS SES, SMTP, SendGrid, Mailgun, ...)
    ✅ AWS SES gets first-class setup assistance (IAM/credentials/region checklist)
    ✅ Multiple named Send Profiles

✅ Media / Storage Module
    ✅ Photos and Videos
    ✅ Local storage + cloud storage providers: AWS S3, Cloudflare R2,
       Backblaze B2, Tigris — Azure/GCS/DigitalOcean Spaces not yet supported
    ✅ Image resizing
    ✅ Video resizing

✅ Sitemap Module

✅ Crawlers Module (robots.txt, llms.txt, bot-policy configuration)

✅ Languages (Backend and frontend languages, broken down to countries and regions)
    ✅ Backend languages
    ✅ Frontend enduser languages, broken down and organized by countries and regions

✅ Settings
    ✅ General
    ✅ App title
    ✅ Global app timezone (native Elixir, no timex dependency)
    ✅ Global time format (native Elixir, no timex dependency)
    ✅ Language configuration

✅ Core UI Component Library
    ✅ [Draggable List](guides/draggable-list-component.md) - Drag-and-drop grid/list component
    ✅ Sortable tables/grids, bulk-select, tree tables, reorder-strategy modal,
       load-more & standalone pagination
    ✅ Embeddable MediaBrowser (folder tree, grid/list, upload, search, trash)
    ✅ Core form components (Input/Select/Textarea/Checkbox) and multilang
       (translatable-field) form components
```

## 🧩 Companion Modules (separate Hex packages)

These extend PhoenixKit but ship as their own Hex packages with their own version/CHANGELOG — install them alongside `phoenix_kit` when you need them (`extra_applications: [:phoenix_kit]` wires them into module discovery automatically). Maturity varies by package; check each one's own CHANGELOG before relying on it in production. Representative examples from the BeamLabEU org:

```
📦 phoenix_kit_ai            — AI Module: OpenRouter + other provider integrations
📦 phoenix_kit_entities      — Dynamic content types, 13 field types, JSONB storage
📦 phoenix_kit_publishing    — Blog/article publishing: timed + slug-based, multilingual, timezone-aware
📦 phoenix_kit_posts         — User-generated posts (UGC)
📦 phoenix_kit_billing       — Invoices, orders, subscriptions; Stripe/PayPal payment providers
📦 phoenix_kit_emails        — Email logs, delivery dashboard/analytics, SQS/Brevo event polling
📦 phoenix_kit_comments      — Threaded comments (likes/dislikes/media)
📦 phoenix_kit_newsletters   — Mailing lists and broadcasts
📦 phoenix_kit_legal         — Cookie consent, ToS, GDPR/CCPA, privacy policy, data retention
📦 phoenix_kit_ecommerce     — Storefront, physical + digital products
📦 phoenix_kit_customer_support — Support ticketing
📦 phoenix_kit_crm           — Companies, contacts, interactions, lists
📦 phoenix_kit_bookings      — Calendar-based booking
📦 phoenix_kit_catalogue     — Supplier/manufacturer catalogue, PDF extraction
📦 phoenix_kit_document_creator — Document templates/generation
📦 phoenix_kit_projects      — Projects and tasks with dependencies
📦 phoenix_kit_user_connections — User-to-user connections
📦 phoenix_kit_sync          — Cross-site data sync over WebSocket
📦 phoenix_kit_staff         — Departments, teams, skills
📦 phoenix_kit_db            — Database management tooling

... and more (open graph, SEO, web analytics, warehouse/manufacturing, calendar, message boards, and others) — see the BeamLabEU GitHub org for the current full list.
```

## 🛣️ Roadmap / Ideas / Feature requests

Notifications, background jobs (Oban), newsletters, legal/compliance, customer
support, and e-commerce are no longer just ideas — they've shipped, either
built into core or as companion packages (see "Companion Modules" above). What's still genuinely open:

--- Next priority

- Missing features for User Auth Module
  - 2FA
- Cron Module (generic admin UI for scheduling background jobs — Oban itself
  already powers core's own workers; this would be a user-facing job manager)
- Live chat (`phoenix_kit_customer_support` covers ticketing, not real-time chat)

--- To sort items

- Design / templates / themes
- Integration with notification providers (Twilio, etc...)
- Video processing/streaming: Adaptive Bitrate (ABR), HTTP Live Streaming (HLS),
  H.264/H.265/VP8/VP9 transcoding (core's Media module only resizes video, no streaming pipeline)
- Audio
- Azure Blob Storage / Google Cloud Storage support (S3-compatible storage —
  AWS S3, R2, Backblaze, Tigris, Spaces — already works via core's Media module)
- CDN
- Search (full-text/site search — distinct from Mentions' cross-module `#`-record lookup)
- Blocks
- Sliders
- Video player (mp4, youtube, etc)
- Popups Module
- Contact Us Module
- What's New Module
- Internal Chat Module (https://github.com/basecamp/once-campfire)
- Feedback Module
- Roadmap / Ideas Module
- App Analytics / BI Module
  - ClickHouse backend
  - Events
  - Charts, trends and notifications
- API Module
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

If you'd rather not use the `igniter_new` archive, add the deps yourself and
invoke the installer directly. You need **both** — PhoenixKit declares
`:igniter` as `optional: true` (so it converges with the
`{:igniter, "~> 0.6", only: [:dev, :test]}` that `mix phx.new` generates), and
an optional dep is not resolved transitively:

```elixir
# mix.exs
def deps do
  [
    {:phoenix_kit, "~> 2.0"},
    {:igniter, "~> 0.7", only: [:dev, :test]}
  ]
end
```

```bash
mix deps.get
mix phoenix_kit.install
```

`only: [:dev, :test]` is deliberate — igniter is build-time tooling and never
reaches production. Every reference to it in PhoenixKit lives in the
`mix phoenix_kit.*` tasks and their installer helpers; nothing in the
supervision tree or the request path touches it, and Mix tasks aren't part of a
release.

Without `:igniter`, the two code-patching tasks — `mix phoenix_kit.install` and
`mix phoenix_kit.update` — print these instructions instead of running. Tasks
that don't generate or patch code (`mix phoenix_kit.status`,
`mix phoenix_kit.gen.migration`, `mix phoenix_kit.assets.rebuild`) work without
it. Adding the dep to an existing project is all that's needed: PhoenixKit
detects the change and recompiles itself, so the tasks appear without a manual
`mix deps.compile phoenix_kit --force`.

### Manual Installation

For full control, skip the installer entirely:

1. Add `{:phoenix_kit, "~> 2.0"}` to `mix.exs`
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

### URLs

```elixir
config :phoenix_kit,
  url_prefix: "/phoenix_kit",  # where PhoenixKit is mounted (default)
  admin_path: "/admin"         # the admin segment inside it (default)
```

Both are optional and independent. `admin_path: "/backoffice"` serves the admin
area at `/phoenix_kit/backoffice/...` — useful when a signed-in end user would
otherwise see a URL that reads as somebody else's admin panel. Compile-time, so
they belong in `config/config.exs`, not `runtime.exs`.

In your own code always write the canonical `/admin/...` and let
`PhoenixKit.Utils.Routes.path/1` (or `<.pk_link>`) apply whatever you
configured. Full details: [Integration Guide](guides/integration.md).

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

Enable social authentication (Google, GitHub, Facebook) through admin UI at `{prefix}/admin/settings`.
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

### User Dashboard Routes

- `GET {prefix}/dashboard` - User dashboard home
- `GET {prefix}/dashboard/settings` - User settings
- `GET {prefix}/dashboard/settings/confirm-email/:token` - Email confirmation

### Admin Routes (Owner/Admin only)

- `GET {prefix}/admin` - Admin dashboard
- `GET {prefix}/admin/users` - User management
- `GET {prefix}/admin/users/permissions` - Permission matrix
- `GET {prefix}/admin/users/sessions` - Active session management
- `GET {prefix}/admin/activity` - Activity feed
- `GET {prefix}/admin/media` - Media/storage browser
- `GET {prefix}/admin/modules` - Enable/disable modules
- `GET {prefix}/admin/settings` - System settings
- `GET {prefix}/admin/settings/integrations` - System-wide integration credentials

Companion packages (if installed) register additional routes under `{prefix}/admin/*` automatically via module discovery — see "External Module Route Discovery" in this project's `AGENTS.md`.

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

The versioned migration chain (`lib/phoenix_kit/migrations/postgres/`, currently at
V174) is centralized in this package and shared across the whole PhoenixKit
ecosystem: installing just `phoenix_kit` already creates the full current
schema — 170+ tables covering every companion package's data model, not only
core's own. This keeps tables ready the moment a companion package is added,
at the cost of a wider schema than a core-only app strictly uses. Tables that
matter without any companion package installed include:

- `phoenix_kit_users` - User accounts with email, names, status
- `phoenix_kit_users_tokens` - Authentication tokens (session, reset, confirm)
- `phoenix_kit_user_roles` - System and custom roles
- `phoenix_kit_user_role_assignments` - User-role mappings with audit trail
- `phoenix_kit_role_permissions` - Module-level permission grants per role
- `phoenix_kit_user_oauth_providers` - Linked OAuth identities
- `phoenix_kit_referral_codes` / `phoenix_kit_referral_code_usage` - Referral program
- `phoenix_kit_settings` - System/module settings
- `phoenix_kit_activities` - Activity feed entries
- `phoenix_kit_notifications` - Per-user notification inbox
- `phoenix_kit_audit_logs` - Sensitive admin-action audit trail
- `phoenix_kit_annotations` / `phoenix_kit_mentions` - Media annotations, cross-module mentions
- `phoenix_kit_buckets`, `phoenix_kit_files`, `phoenix_kit_file_instances`, `phoenix_kit_file_locations` - Media/storage
- `phoenix_kit_email_logs`, `phoenix_kit_email_events`, `phoenix_kit_email_templates`, `phoenix_kit_email_blocklist` - Email tracking

The remaining tables (CRM, catalogue, publishing, warehouse, projects,
newsletters, and more) sit dormant — unused, but present — until you add the
matching companion package and enable it.

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

### Module-Level Permissions

PhoenixKit includes a granular permission system that controls which roles can access which admin sections and feature modules.

**5 core section keys** ship fixed with this package: `dashboard`, `users`, `media`, `settings`, `modules`. Each installed companion package can register its own feature-module key (and dotted sub-permission keys, e.g. `calendar.view_others`) — the total key count grows as you add companion packages, not a fixed number. There's also a blanket `"*"` superadmin key, honored the same as Owner.

**Access rules**:
- **Owner** bypasses all checks (full access always)
- **Admin** seeded with every known key (core + every installed feature module) by default
- **Custom roles** start with no permissions, assigned via matrix UI or API

```elixir
# Grant/revoke permissions for a role (role_uuid, granted_by_uuid are UUIDv7 strings)
Permissions.grant_permission(role_uuid, "billing", granted_by_uuid)
Permissions.revoke_permission(role_uuid, "billing", actor_uuid: granted_by_uuid)
Permissions.set_permissions(role_uuid, ["dashboard", "users", "billing"], granted_by_uuid)

# Query permissions
Permissions.get_permissions_for_role(role_uuid)    # ["dashboard", "users", ...]
Permissions.role_has_permission?(role_uuid, "shop") # true/false

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

Each companion package exposes `enabled?/0` and `enable_system/0` on its own top-level module — the name varies by package, so check that package's own docs. A few examples:

```elixir
# Check if a module is enabled
PhoenixKitAI.enabled?()                 # => false (default, when installed)
PhoenixKitEntities.enabled?()           # => false (default)

# Enable modules before use
PhoenixKitAI.enable_system()
PhoenixKitEntities.enable_system()
PhoenixKitPosts.enable_system()
PhoenixKit.Modules.Emails.enable_system()
PhoenixKitBilling.enable_system()

# Disable when no longer needed
PhoenixKitAI.disable_system()
```

**Important**: Attempting to use a disabled module's API functions or admin pages will result in errors or redirects. Always enable modules before:
- Calling their API functions (e.g., `PhoenixKitAI.ask_with_prompt/4`)
- Visiting their admin pages (e.g., `/{prefix}/admin/ai/endpoints`)

### Built-in Admin Interface

**Core Administration (ships with this package):**
- `{prefix}/admin` - System statistics and overview
- `{prefix}/admin/users` - User management with role controls
- `{prefix}/admin/users/permissions` - Permission matrix for all roles
- `{prefix}/admin/users/sessions` - Active session management
- `{prefix}/admin/activity` - Activity feed
- `{prefix}/admin/media` - Media/storage browser
- `{prefix}/admin/modules` - Enable/disable PhoenixKit modules
- `{prefix}/admin/settings` - System settings (timezone, date/time formats)

**Settings & Configuration (core):**
- `{prefix}/admin/settings/users` - Auth, session, and login-alert policy
- `{prefix}/admin/settings/languages` - Multi-language configuration
- `{prefix}/admin/settings/media` - Storage buckets and image dimensions
- `{prefix}/admin/settings/sitemap` - Sitemap generation settings
- `{prefix}/admin/settings/crawlers` - Crawler / bot-policy configuration
- `{prefix}/profile/settings/integrations` - Personal (per-user) integration credentials
- `{prefix}/admin/settings/integrations` - System-wide integration credentials (OAuth/API keys/bot tokens)

**Your own admin pages** are declared, not hand-routed. List them under
`config :phoenix_kit, :admin_dashboard_tabs` (with a `live_view:` field) and
the kit wires the route into its admin `live_session`, adds the sidebar entry,
applies the permission, and keeps the active state and the language switcher
working — no `url_path` or router edits on your side. `mix phoenix_kit.gen.admin.page`
writes a starting page and its config entry. Full reference:
[Custom admin pages](guides/custom-admin-pages.md).

In the page header, `page_action` is a single **navigation** chip (a real link);
anything **interactive** — a modal, a `phx-click` — goes in `page_toolbar`.

**The following require installing their companion package** (see "Companion Modules" above) — they 404 until that package is added:

- `{prefix}/admin/publishing` - Blog posts and articles management (`phoenix_kit_publishing`)
- `{prefix}/admin/posts` - User-generated content / social posts (`phoenix_kit_posts`)
- `{prefix}/admin/entities` - Dynamic content types (`phoenix_kit_entities`)
- `{prefix}/admin/emails`, `{prefix}/admin/emails/dashboard` - Email logs, delivery tracking, metrics (`phoenix_kit_emails`)
- `{prefix}/admin/ai/endpoints`, `/ai/prompts`, `/ai/usage` - AI provider endpoints, prompts, usage stats (`phoenix_kit_ai`)
- `{prefix}/admin/billing`, `/billing/orders`, `/billing/invoices`, `/billing/subscriptions` - Billing dashboard (`phoenix_kit_billing`)

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
