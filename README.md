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

- Add `{:phoenix_kit, "~> 3.0"}` to your `mix.exs` and fetch deps
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
If your Oban config runs on a different repo than the first of `:ecto_repos`
(`repo:` in `config :my_app, Oban`), the update checks that repo too but
writes no file for it — it prints the migration to add to that repo instead.

## Upgrading to 3.0

**New installs need nothing from this section.**

3.0 stops creating the optional modules' tables in core (each module's own chain creates them) and removes the
database layer for email templates and the deprecated shop names of the machine API. An existing install must be at
**V225 (PhoenixKit 2.65.0)** before it upgrades; 3.0 refuses a lower database. In short: pin `== 2.65.0` and run
`mix phoenix_kit.update` until it reports V225, export any email templates you edited
(`mix phoenix_kit_emails.templates.export`), then update core and all installed modules together and run
`mix phoenix_kit.update` again. The full recipe is in [Upgrading to PhoenixKit 3.0](guides/upgrading-to-3.0.md).

## Upgrading to 2.0 (historical)

The 2.0 notes below stay for installs that are still on 1.7.x; from 2.0 on, go through 2.65.0 and the 3.0 guide above.

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
✅ `mix phoenix_kit.status` and `mix phoenix_kit.doctor` — what is installed, what is out of date
✅ Tailwind and daisyUI 5 integration, your app's layout around every page
✅ Your app's database (PostgreSQL), optionally in its own schema (`--prefix`)
✅ Custom URL prefix (default: `/phoenix_kit`) and a renameable admin segment (`admin_path`)
✅ Versioned migrations: core creates its own tables; each module creates and
   migrates its own, when it is installed

✅ Sign-up and sign-in
    ✅ Registration (password, or a link sent by email), login, logout, password reset
    ✅ Magic link sign-in, QR-code sign-in from a signed-in phone
    ✅ Passkeys (Face ID, Touch ID, Windows Hello, security keys)
    ✅ OAuth (Google, GitHub, Facebook)
    ✅ Email confirmation, enforced at every entry point (`require_email_confirmation`)
    ✅ Several accounts in one browser, with an account switcher
    ✅ Admin "log in as user" (impersonation)
    ✅ Invite-only sign-up with referral codes
    ✅ Login page branding (logo, background)

✅ Protection of the public forms
    ✅ Rate limits per address, per network and for the whole site, shown live on
       Settings → Authorization → Abuse protection
    ✅ Cloudflare Turnstile on the forms that send email (optional)
    ✅ Email address check at sign-up: domains that cannot receive mail are
       refused, common typos get a "Did you mean" hint
    ✅ No automated mail to an address nobody has confirmed
    ✅ Alerts for a sign-in from a new device or country, and for repeated failed sign-ins
    ✅ A record of failed sign-ins
    ✅ A plug for your endpoint that answers scanner probes (`/.env`, `wp-login.php`) with a bare 404

✅ Users, roles and permissions
    ✅ Owner / Admin / User and custom roles, role order
    ✅ Per-role permissions for every admin section and module, with sub-permissions
    ✅ Role switcher: a person with several roles acts as one per session (optional)
    ✅ Custom user fields (JSONB), admin notes, user's timezone and locale
    ✅ Location of registration (IP, country, region, city)
    ✅ Sessions: list, end, live sessions — `/admin/users/sessions`

✅ Organizations
    ✅ Person and organization accounts, organization invitations
    ✅ Managed organizations: people act for a company through a link
       (manager, staff, or your own relationship types), with all or some of its roles

✅ Admin
    ✅ Modules — enable/disable installed modules, with a catalog of the
       companion packages on Hex.pm — `/admin/modules`
    ✅ Activity feed — audit trail of business-level actions — `/admin/activity`
    ✅ Notifications — per-user inbox driven by the activity feed, per-type
       preferences, delivery by email and Telegram, immediately or as a digest
       (hourly to weekly)
    ✅ Jobs — long background work an admin can watch, pause, resume and retry — `/admin/jobs`
    ✅ Integrations — one place for OAuth connections, API keys and bot tokens,
       for the site and per user — `/admin/settings/integrations`
    ✅ Audit log of sensitive admin actions
    ✅ Mentions — `@`-mentions and `#`-record links across modules
    ✅ Your own admin pages, declared in config (`mix phoenix_kit.gen.admin.page`)

✅ Machine API (off by default)
    ✅ REST for admins and for the public site, with OpenAPI documents
    ✅ MCP endpoints for AI agents
    ✅ API keys with scopes, personal keys, service users, key rotation
    ✅ Dry runs, confirmations and approvals for writes; idempotency keys
    ✅ Modules and your own app add tools with one callback

✅ Website access
    ✅ Maintenance mode
    ✅ Password gate for a site that is not public yet, with an allow list
    ✅ Redirect the whole site elsewhere

✅ Email
    ✅ Any Swoosh adapter (AWS SES, SMTP, SendGrid, Mailgun, Brevo, ...)
    ✅ Several named send profiles; a user's own SMTP connection
    ✅ Emails as template files you can override, per language, with a preview page
    ✅ AWS SES setup help (IAM, credentials, region checklist)

✅ Media and storage
    ✅ Libraries: the site's Media, plus libraries of users and of modules
    ✅ Local disk and S3-compatible storage: AWS S3, Cloudflare R2, Backblaze B2, Tigris
    ✅ Storage profiles: which buckets a library uses, with backups and health checks
    ✅ A user's own bucket for their own library
    ✅ Image and video sizes, image editing with the original kept
    ✅ Private files behind time-limited links
    ✅ Annotations on media (rectangle, circle, polygon, freehand)
    ✅ Each viewer sees their own files unless allowed to see everyone's

✅ Languages
    ✅ Admin languages (ten translations shipped) and site languages, by country and region
    ✅ The language lives in the URL; the default language can be prefixless

✅ Sitemap (XML and HTML) and Crawlers (robots.txt, llms.txt, bot policy)

✅ Settings
    ✅ Site title and URL, timezone, date and time formats
    ✅ Users, Authorization, Website access, Languages, Media, Email, API, Integrations, Organization

✅ UI component library
    ✅ [Draggable List](guides/draggable-list-component.md) — drag-and-drop grid/list
    ✅ Sortable tables and grids, bulk select, tree tables, reorder modal, pagination
    ✅ Embeddable media browser (folders, grid/list, upload, search, trash) and media picker
    ✅ Form components (input, select, textarea, checkbox) and translatable-field forms
```

## 🧩 Companion Modules (separate Hex packages)

These extend PhoenixKit but ship as their own Hex packages with their own version and CHANGELOG. Add one to your `mix.exs` and it is discovered automatically; `/admin/modules` shows what is installed and what else exists. Each creates and migrates its own tables. Maturity varies by package: check each one's CHANGELOG before relying on it in production.

```
Content
📦 phoenix_kit_publishing     — CMS: blog posts and pages, multi-language, scheduled
📦 phoenix_kit_entities       — Dynamic content types with flexible field schemas
📦 phoenix_kit_posts          — User posts with tags, boards, likes, media, scheduling
📦 phoenix_kit_comments       — Threaded comments, likes/dislikes, moderation
📦 phoenix_kit_knowledge_base — Linked markdown notes: vaults, tags, wiki-links, search
📦 phoenix_kit_boards         — Collaborative infinite-canvas boards
📦 phoenix_kit_photos         — A personal photo and video library, built for very large collections
📦 phoenix_kit_open_graph     — Open Graph images and templates

Commerce and operations
📦 phoenix_kit_billing        — Payments, subscriptions, invoices
📦 phoenix_kit_ecommerce      — Products, categories, cart, checkout
📦 phoenix_kit_catalogue      — Manufacturers, suppliers and product catalogues
📦 phoenix_kit_warehouse      — Inventory, stock, goods receipts and issues
📦 phoenix_kit_manufacturing  — Machines and production orders
📦 phoenix_kit_bookings       — Bookings: stays, fixed slots
📦 phoenix_kit_locations      — Physical locations with custom types

People and work
📦 phoenix_kit_crm            — Organization accounts, contacts, role-scoped views
📦 phoenix_kit_staff          — Departments, teams and people
📦 phoenix_kit_projects       — Projects, reusable tasks, assignments, dependencies
📦 phoenix_kit_calendar       — Personal calendars
📦 phoenix_kit_customer_support — Support tickets
📦 phoenix_kit_user_connections — Follows, mutual connections, blocking
📦 phoenix_kit_referrals      — Referral codes: issue, track, apply at sign-up

Email and messaging
📦 phoenix_kit_emails         — Email log, delivery tracking and analytics, AWS SES events
📦 phoenix_kit_newsletters    — Broadcasts and subscriptions
📦 phoenix_kit_inbox          — Internal mailboxes, user and shared
📦 phoenix_kit_templates_editor — Edit the email templates from the admin

AI
📦 phoenix_kit_ai             — AI endpoints, prompts, completions, usage tracking
📦 phoenix_kit_agent          — Per-user AI chats that call tools from the machine API

Insight and tooling
📦 phoenix_kit_dashboards     — Dashboards composed from widgets any module exposes
📦 phoenix_kit_stats          — Metric groups per source
📦 phoenix_kit_web_analytics  — Cookieless, privacy-first web analytics
📦 phoenix_kit_legal          — Legal pages, cookie consent, consent log (GDPR/CCPA)
📦 phoenix_kit_document_creator — Document templates and PDFs via Google Docs
📦 phoenix_kit_sync           — Two-way data sync between PhoenixKit sites
📦 phoenix_kit_db             — Database explorer: tables, rows, live changes
📦 phoenix_kit_hello_world    — A demo module to copy when you write your own
```

Writing your own module, or treating your own app as one: [Your App as a Module](guides/your-app-as-a-module.md).

## 🛣️ Roadmap / Ideas / Feature requests

Much of the earlier roadmap has shipped, in core or as a companion package:
notifications, background jobs, the machine API, passkeys, web analytics,
newsletters, legal pages, customer support, e-commerce. What is still open:

--- Next priority

- Two-factor sign-in with an authenticator app (passkeys already work as a
  phishing-resistant sign-in; a second step for password sign-ins is not built)
- Step-up confirmation and trusted devices for sensitive actions
- Live chat (`phoenix_kit_customer_support` covers ticketing, not real-time chat)

--- To sort

- Design / templates / themes
- Notification providers beyond email and Telegram (SMS, push)
- Video streaming: adaptive bitrate, HLS, transcoding (core resizes video; it has no streaming pipeline)
- Audio
- Azure Blob Storage / Google Cloud Storage (S3-compatible storage already works)
- CDN
- Site search
- Blocks, sliders, popups
- Contact Us, What's New, Feedback, Roadmap / Ideas modules
- Forms module
- Cluster module

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
    {:phoenix_kit, "~> 3.0"},
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

1. Add `{:phoenix_kit, "~> 3.0"}` to `mix.exs`
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
  region: "eu-north-1"  # or "eu-west-1", "us-east-1", etc.
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

Enable social authentication (Google, GitHub, Facebook) through the admin UI at `{prefix}/admin/settings/authorization`.
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

### Sign-up and sign-in

- `GET {prefix}/users/register` - Registration form
- `GET {prefix}/users/register/magic-link` - Registration by a link sent by email
- `GET {prefix}/users/log-in` - Login form
- `GET {prefix}/users/magic-link` - Sign in with a link sent by email
- `GET {prefix}/users/qr-login` - Sign in by scanning a QR code with a signed-in phone
- `GET {prefix}/users/reset-password` - Password reset
- `GET {prefix}/users/confirm/:token` - Email confirmation
- `DELETE {prefix}/users/log-out` - Logout endpoint

### The signed-in person

- `GET {prefix}/profile/settings` - Account settings (profile, security, passkeys, notifications)
- `GET {prefix}/profile/settings/integrations` - Their own connections
- `GET {prefix}/profile/settings/api-keys` - Their own API keys
- `GET {prefix}/dashboard` - User dashboard. New pages for signed-in people go under
  `{prefix}/admin/...`, which serves users as well as admins according to their permissions.

### Admin (by permission)

- `GET {prefix}/admin` - Admin dashboard
- `GET {prefix}/admin/users` - Users, roles (`/roles`), permissions (`/permissions`), sessions (`/sessions`)
- `GET {prefix}/admin/activity` - Activity feed
- `GET {prefix}/admin/notifications` - Notification inbox
- `GET {prefix}/admin/media` - Media browser; `{prefix}/admin/libraries` - libraries
- `GET {prefix}/admin/jobs` - Background jobs
- `GET {prefix}/admin/modules` - Enable/disable modules
- `GET {prefix}/admin/settings` - Settings (see "Built-in Admin Interface" below)

### Machine API (when switched on)

- `{prefix}/api/admin/v1`, `{prefix}/api/public/v1` - REST, each with an `openapi.json`
- `POST {prefix}/mcp/admin`, `POST {prefix}/mcp/public` - MCP for AI agents

Companion packages register their own routes under `{prefix}/admin/*` automatically through module discovery.

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

Migrations are versioned, Oban-style, and run by `mix phoenix_kit.update`
(`lib/phoenix_kit/migrations/postgres/`). Core creates only its own tables;
since 3.0 each companion package creates and migrates its own when it is
installed, so a core-only app carries no tables it does not use. The main ones:

- `phoenix_kit_users`, `phoenix_kit_users_tokens` - Accounts and their tokens (session, reset, confirm)
- `phoenix_kit_user_roles`, `phoenix_kit_user_role_assignments`, `phoenix_kit_role_permissions` - Roles and permissions
- `phoenix_kit_user_oauth_providers`, `phoenix_kit_user_passkeys`, `phoenix_kit_user_known_devices` - Sign-in methods and known devices
- `phoenix_kit_login_attempts`, `phoenix_kit_access_attempts` - Failed sign-ins and website-gate attempts
- `phoenix_kit_organization_managers`, `phoenix_kit_organization_invitations`, `phoenix_kit_relationship_types` - Organizations and who acts for them
- `phoenix_kit_settings` - Settings of the site and of modules; integration connections
- `phoenix_kit_activities`, `phoenix_kit_notifications`, `phoenix_kit_audit_logs` - Activity feed, inbox, audit trail
- `phoenix_kit_mentions`, `phoenix_kit_annotations` - Mentions and media annotations
- `phoenix_kit_files`, `phoenix_kit_file_instances`, `phoenix_kit_file_locations`, `phoenix_kit_media_folders`, `phoenix_kit_buckets`, `phoenix_kit_storage_libraries`, `phoenix_kit_storage_profiles` - Media and storage
- `phoenix_kit_api_keys`, `phoenix_kit_api_confirmations`, `phoenix_kit_api_idempotency` - Machine API
- `phoenix_kit_job_runs`, `phoenix_kit_scheduled_jobs` - Background jobs (Oban's own tables ride the same schema)
- `phoenix_kit_email_send_profiles` - Email send profiles

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

**Core section keys** ship with this package: `dashboard`, `users`, `media`, `settings`, `modules`, `jobs`, `languages`, `api`, `api_personal_keys`, plus two for integrations. Core sections have sub-permissions too (`media.view_all`, `media.manage`, `jobs.manage`, `settings.security`). Each installed companion package registers its own key and dotted sub-permission keys (e.g. `calendar.view_others`), so the total grows with the packages you add. There is also a blanket `"*"` superadmin key, honored the same as Owner.

**Access rules**:
- **Owner** bypasses all checks (full access always)
- **Admin** gets every known key by default (core + every installed feature module), except the opt-in ones: the machine API (`api`, `api_personal_keys`) and personal integrations
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

PhoenixKit uses a modular architecture where features can be enabled/disabled at runtime. **Feature modules are disabled by default** and must be enabled before use. (Core sections such as Users, Media, Languages and Jobs are always there.)

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

# Disable when no longer needed
PhoenixKitAI.disable_system()
```

**Important**: Attempting to use a disabled module's API functions or admin pages will result in errors or redirects. Always enable modules before:
- Calling their API functions (e.g., `PhoenixKitAI.ask_with_prompt/4`)
- Visiting their admin pages (e.g., `/{prefix}/admin/ai/endpoints`)

### Built-in Admin Interface

**Core administration (ships with this package):**
- `{prefix}/admin` - Overview
- `{prefix}/admin/users` - Users, with roles, permissions, sessions and relationship types beneath it
- `{prefix}/admin/activity` - Activity feed
- `{prefix}/admin/notifications` - Notification inbox and its settings
- `{prefix}/admin/media`, `{prefix}/admin/libraries` - Media browser and libraries
- `{prefix}/admin/jobs` - Background jobs
- `{prefix}/admin/approvals` - Writes of API keys that wait for a person (shown while in use)
- `{prefix}/admin/modules` - Enable/disable PhoenixKit modules

**Settings (core):**
- `{prefix}/admin/settings` - Site title and URL, timezone, date and time formats
- `{prefix}/admin/settings/users` - Registration, new-user defaults, sessions, profile sections
- `{prefix}/admin/settings/authorization` - Login page branding, sign-in methods (magic link, QR, passkeys, OAuth), sessions, abuse protection (request limits, email address check, Cloudflare Turnstile)
- `{prefix}/admin/settings/website-access` - Maintenance mode, password gate, redirect
- `{prefix}/admin/settings/organization` - The site's own organization details
- `{prefix}/admin/settings/languages` - Admin and site languages
- `{prefix}/admin/settings/media` - Buckets, storage profiles, image and video sizes, health
- `{prefix}/admin/settings/email-sending` - Send profiles, transport, email preview
- `{prefix}/admin/settings/integrations` - System-wide connections (OAuth, API keys, bot tokens)
- `{prefix}/admin/settings/api` - Machine API: keys, service users, switches and limits, a how-to-connect guide
- `{prefix}/admin/settings/sitemap`, `{prefix}/admin/settings/crawlers` - Sitemap and crawler policy
- `{prefix}/profile/settings/integrations` - A person's own connections

**Your own admin pages** are declared, not hand-routed. List them under
`config :phoenix_kit, :admin_dashboard_tabs` (with a `live_view:` field) and
the kit wires the route into its admin `live_session`, adds the sidebar entry,
applies the permission, and keeps the active state and the language switcher
working — no `url_path` or router edits on your side. `mix phoenix_kit.gen.admin.page`
writes a starting page and its config entry. Full reference:
[Custom admin pages](guides/custom-admin-pages.md).

In the page header, `page_action` is a single **navigation** chip (a real link);
anything **interactive** — a modal, a `phx-click` — goes in `page_toolbar`.

**Pages of companion packages** (`{prefix}/admin/publishing`, `{prefix}/admin/billing`, `{prefix}/admin/ai/endpoints`, ...) exist only once that package is installed and its module is enabled.

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
