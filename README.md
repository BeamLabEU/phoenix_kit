# PhoenixKit - The Elixir Phoenix Starter Kit for SaaS apps

[![Hex Version](https://img.shields.io/hexpm/v/phoenix_kit)](https://hex.pm/packages/phoenix_kit)

We are actively building PhoenixKit, a comprehensive SaaS starter kit for the Elixir/Phoenix ecosystem. Our goal is to eliminate the need to reinvent the wheel every time we all start a new SaaS project.

**🚧 Early Access - We Need Your Feedback!**

PhoenixKit is under heavy development and we're looking for early adopters to test, provide feedback, and help shape the future of this toolkit. If you're building with Phoenix and want to skip the boilerplate setup, we'd love to have you try it out and share your experience.

With PhoenixKit, you will be able to create production-ready Elixir/Phoenix apps much faster and focus on your unique business logic instead of reimplementing common SaaS patterns.

## Semi-Automatic Installation

PhoenixKit provides pretty simple installation method, powered by igniter library, which takes care of all configuration needs.

Add both `phoenix_kit` and `igniter` to your project dependencies:

```elixir
# mix.exs
def deps do
  [
    {:phoenix_kit, "~> 1.4"},
    {:igniter, "~> 0.6.30", only: [:dev]}
  ]
end
```

Then run the PhoenixKit installer:

```bash
mix deps.get
mix phoenix_kit.install
```

This will automatically:
- ✅ Auto-detect your Ecto repository
- ✅ **Validate PostgreSQL compatibility** with adapter detection
- ✅ Generate migration files for authentication tables
- ✅ **Optionally run migrations interactively** for instant setup
- ✅ Add PhoenixKit configuration to `config/config.exs`
- ✅ Configure mailer settings for development
- ✅ **Create production mailer templates** in `config/prod.exs`
- ✅ Add authentication routes to your router
- ✅ Provide detailed setup instructions

## 📦 Current PhoenixKit Features / Modules:
- [x] Simple installation using Igniter
- [x] Tailwind and DaisyUI integration
- [x] App layout integration
- [x] App database integration (Postgres only for now)
- [x] Custom slug prefix (default: `/phoenix_kit`)
- [x] User Module
  - [x] Registration
  - [x] Login
    - [ ] Login screen customizations
  - [x] Logout
  - [x] Magic link
  - [x] Email confirmation (waiting Email Module)
  - [x] Password reset
  - [x] User roles
  - [x] Custom user fields
    - [x] JSONB storage for flexibility
  - [x] Location of registration (ip, country, region, city)
  - [x] User's timezone (and mismatch detection)
  - [x] User's locale
  - [x] OAuth (google, facebook)

- [ ] Backend Admin module
  - [x] Modules Manager
  - [x] Session Manager Module
  - [x] Settings
    - [x] Global app title
    - [x] Global app timezone (using timex)
    - [x] Global time format (using timex)
  - [x] User management
  - [x] Role management
  - [x] Referral Program
  - [x] Maintenance Mode Module
  - [x] Email Module
    - [x] AWS SES integration
  - [x] Entities Module (WordPress ACF-like dynamic content types)
    - [x] Dynamic entity type creation
    - [x] Flexible field schemas (13 field types)
    - [x] JSONB storage for flexibility
    - [x] Full CRUD interfaces
    - [x] Settings management
  - [x] Pages Module

## 🛣️ Roadmap / Ideas / Feature requests
- User module
  - 2FA
  - Fail2ban
- Backend admin
  - Design / templates / themes
  - Settings
    - General
    - Languages
  - Email Module
    - Email templates
  - Notifications Module
    - Integration with notification providers (Twilio, etc...)
  - Content publishing Module
    - Media / Gallery (with s3 backend)
    - Video (Video processing, streaming, Adaptive Bitrate (ABR): stream in multiple bitrates and resolutions for difference devices, HTTP Live Streaming (HLS): reduce bandwidth usage, playback latency, and buffering, H.264, H.265, VP8 & VP9: optimized next-generation video codecs)
    - Audio
    - Media / Gallery
    - Local / External storage support (AWS S3, Azure Storage, Google Storage, Cloudflare R2, and DigitalOcean Spaces)
    - CDN
    - Static pages
    - Legal (Cookies, Terms Of Service, Acceptable Use, GDPR, Privacy & Data Policy)
    - Blog
    - Comments
    - Search
    - Blocks
      - Sliders
      - Video player (mp4, youtube, etc)
  - Billing System Module
    - Invoices
    - Payment
      - Integration
        - Stripe
        - PayPal
        - Crypto
    - Orders
  - Membership Module
  - Newsletter Module
  - E-commerce Module
    - Digital products
    - Physical products
  - Cookies Module
  - Popups Module
  - Contact Us Module
  - SEO Module
  - AI Module
    - Integration with AI providers
  - What’s New Module
  - Chat Module (https://github.com/basecamp/once-campfire)
  - DB Manager Module
    - Export / Import
    - Snapshots
    - Backups
  - Customer service Module
    - Chat
  - Feedback Module
  - Roadmap / Ideas Module
  - CRM Module
  - Analytics / BI Module
    - ClickHouse backend
    - Events
  - API Module
  - Cron Modules
  - Jobs Module (Oban)
  - Testimonials Module
  - Team Module
  - FAQ
  - Forms Module
  - Cluster Module

💡 Send your ideas and suggestions about any existing modules and features our way. Start building your apps today!

## Installation

PhoenixKit provides multiple installation methods to suit different project needs and developer preferences.

### Semi-Automatic Installation

**Recommended for most projects**

Add both `phoenix_kit` and `igniter` to your project dependencies:

```elixir
# mix.exs
def deps do
  [
    {:phoenix_kit, "~> 1.4.3"},
    {:igniter, "~> 0.6.0", only: [:dev]}
  ]
end
```

Then run the PhoenixKit installer:

```bash
mix deps.get
mix phoenix_kit.install
```

This will automatically:
- ✅ Auto-detect your Ecto repository
- ✅ **Validate PostgreSQL compatibility** with adapter detection
- ✅ Generate migration files for authentication tables
- ✅ **Optionally run migrations interactively** for instant setup
- ✅ Add PhoenixKit configuration to `config/config.exs`
- ✅ Configure mailer settings for development
- ✅ **Create production mailer templates** in `config/prod.exs`
- ✅ Add authentication routes to your router
- ✅ Provide detailed setup instructions

**Optional parameters:**

```bash
# Specify custom repository
mix phoenix_kit.install --repo MyApp.Repo

# Use PostgreSQL schema prefix for table isolation
mix phoenix_kit.install --prefix "auth" --create-schema

# Specify custom router file path
mix phoenix_kit.install --router-path lib/my_app_web/router.ex
```

## Manual Installation

1. Add `{:phoenix_kit, "~> 1.4"}` to `mix.exs`
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
  region: "eu-north-1",  # or "eu-north-1", "eu-west-1", etc.
  access_key: System.get_env("AWS_ACCESS_KEY_ID"),
  secret: System.get_env("AWS_SECRET_ACCESS_KEY")
```

**AWS SES Checklist:**
- ✅ Create AWS IAM user with SES permissions (`ses:*`)
- ✅ Verify sender email address in AWS SES Console
- ✅ Verify recipient emails (if in sandbox mode)
- ✅ Ensure AWS region matches your verification region
- ✅ Request production access to send to any email
- ✅ Set environment variables: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`

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

See [OAuth Setup Guide](guides/oauth_and_magic_link_setup.md) for details.

### Advanced Options
- Custom URL prefix: `phoenix_kit_routes("/authentication")`
- PostgreSQL schemas: `mix phoenix_kit.install --prefix "auth" --create-schema`
- Custom repository: `mix phoenix_kit.install --repo MyApp.CustomRepo`

## Routes

### Public Routes
- `GET {prefix}/users/register` - Registration form
- `GET {prefix}/users/log-in` - Login form
- `GET {prefix}/users/reset-password` - Password reset
- `GET {prefix}/users/confirm/:token` - Email confirmation

### Authenticated Routes
- `GET {prefix}/users/settings` - User settings

### Admin Routes (Owner/Admin only)
- `GET {prefix}/admin/dashboard` - Admin dashboard
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

### Built-in Admin Interface
- `{prefix}/admin/dashboard` - System statistics
- `{prefix}/admin/users` - User management with role controls

## Architecture

PhoenixKit follows professional library patterns:
- **Library-First**: No OTP application, minimal dependencies
- **Dynamic Repository**: Uses your existing Ecto repo
- **Versioned Migrations**: Oban-style schema management
- **PostgreSQL Only**: Optimized for production databases

## Contributing

See [CONTRIBUTING.md](https://github.com/BeamLabEU/phoenix_kit/blob/main/CONTRIBUTING.md) for detailed instructions on setting up a development environment and contributing to PhoenixKit.

## License

MIT License - see [CHANGELOG.md](CHANGELOG.md) for version history.

---

Built in 🇪🇺🇪🇪 with ❤️ for the Elixir Phoenix community.
