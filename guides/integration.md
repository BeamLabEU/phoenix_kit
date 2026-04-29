# PhoenixKit Integration Guide

**For developers using PhoenixKit as a Hex dependency in their Phoenix application.**

This guide is designed to help both developers and AI assistants (Claude, Cursor, Copilot, Tidewave MCP, etc.) understand how to integrate and use PhoenixKit effectively.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Installation](#installation)
3. [Configuration Reference](#configuration-reference)
4. [Authentication Integration](#authentication-integration)
5. [Troubleshooting](#troubleshooting)

---

## Quick Start

```bash
# 1. Verify database is prepared
mix ecto.migrations

# 2. Install PhoenixKit (adds dep, fetches, configures, generates migrations)
mix igniter.install phoenix_kit

# 3. Create database if needed
mix ecto.create

# 4. Run migrations
mix ecto.migrate

# 5. Start your server
mix phx.server
# Visit /phoenix_kit/admin
```

> Requires the `igniter_new` archive — install once with `mix archive.install hex igniter_new`. If you'd rather not, see the [two-step fallback](#step-2-install) below.

---

## Installation

### Step 1: Run the Installer

```bash
mix igniter.install phoenix_kit
```

The installer will:
- Add `{:phoenix_kit, "~> 1.7"}` to your `mix.exs` and fetch deps
- Detect your Repo automatically (or use `--repo` to specify)
- Add configuration to `config/config.exs`
- Generate migrations
- Set up mailer integration

> Requires the `igniter_new` archive — `mix archive.install hex igniter_new` if you don't already have it.

### Step 2: Install (two-step fallback)

If you can't or don't want to use the `igniter_new` archive, add the dep manually and run the installer directly:

```elixir
# mix.exs
defp deps do
  [
    {:phoenix_kit, "~> 1.7"}
  ]
end
```

```bash
mix deps.get
mix phoenix_kit.install
```

`:igniter` is pulled in transitively, so this works on any Phoenix project.

### Step 3: Configure

The installer adds this to your config. Customize as needed:

```elixir
# config/config.exs
config :phoenix_kit,
  parent_app_name: :my_app,
  parent_module: MyApp,
  url_prefix: "/phoenix_kit",
  repo: MyApp.Repo,
  mailer: MyApp.Mailer,
  layouts_module: MyApp.Layouts,
  phoenix_version_strategy: :modern
```

### Step 4: Add Routes

The installer adds something like this to your router.ex. Customize as needed:

```elixir
# lib/my_app_web/router.ex
import PhoenixKitWeb.Integration

scope "/" do
  pipe_through :browser
  phoenix_kit_routes()
end
```

### Step 5: Run Migrations

```bash
mix ecto.migrate
```

---

## Configuration Reference

### Core Settings

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `repo` | module | auto-detected | Your Ecto Repo module |
| `mailer` | module | nil | Your Swoosh Mailer module |
| `url_prefix` | string | "/phoenix_kit" | URL prefix for all routes |
| `layout` | tuple | PhoenixKit default | `{LayoutModule, :template}` |
| `root_layout` | tuple | PhoenixKit default | Root layout for pages |

### Authentication Settings

```elixir
config :phoenix_kit, :password_requirements,
  min_length: 8,
  max_length: 72,
  require_uppercase: false,
  require_lowercase: false,
  require_digit: false,
  require_special: false
```

### Rate Limiting

```elixir
# Hammer 7.x uses ETS backend via PhoenixKit.Users.RateLimiter.Backend
# No additional :hammer config needed

config :phoenix_kit, PhoenixKit.Users.RateLimiter,
  login_limit: 5,                      # Max login attempts per window
  login_window_ms: 60_000,             # 1 minute window
  magic_link_limit: 3,                 # Max magic link requests per window
  magic_link_window_ms: 300_000,       # 5 minute window
  password_reset_limit: 3,             # Max password reset requests per window
  password_reset_window_ms: 300_000,   # 5 minute window
  registration_limit: 3,               # Max registration attempts per window
  registration_window_ms: 3_600_000,   # 1 hour window
  registration_ip_limit: 10,           # Max registrations per IP per window
  registration_ip_window_ms: 3_600_000 # 1 hour window
```

---

## Authentication Integration

### Access Current User

```elixir
# In a LiveView
def mount(_params, _session, socket) do
  current_user = socket.assigns[:current_user]
  {:ok, socket}
end

# In a Controller
def index(conn, _params) do
  current_user = conn.assigns[:current_user]
  render(conn, :index)
end
```

### Require Authentication

```elixir
# In your router
import PhoenixKitWeb.Users.Auth

scope "/", MyAppWeb do
  pipe_through [:browser, :require_authenticated_user]

  live "/dashboard", DashboardLive
end
```

### Check User Roles

```elixir
# Check if user has a role
PhoenixKit.Users.Roles.user_has_role?(user, "Admin")
PhoenixKit.Users.Roles.user_has_role?(user, "Owner")

# Get user's roles
roles = PhoenixKit.Users.Roles.get_user_roles(user)

# Check in templates
<%= if PhoenixKit.Users.Roles.user_has_role?(@current_user, "Admin") do %>
  <.link navigate="/admin">Admin Panel</.link>
<% end %>
```

### Check Module-Level Permissions

PhoenixKit V53+ includes granular permissions that control which admin sections each role can access.

```elixir
# In a LiveView, use the scope from assigns
scope = socket.assigns.phoenix_kit_current_scope

# Check single permission
Scope.has_module_access?(scope, "billing")        # true/false

# Check multiple permissions
Scope.has_any_module_access?(scope, ["billing", "shop"])  # any granted?
Scope.has_all_module_access?(scope, ["billing", "shop"])  # all granted?

# Check system role (Owner or Admin, not custom roles)
Scope.system_role?(scope)

# Get all granted keys
Scope.accessible_modules(scope)  # MapSet of granted permission keys
```

**Route enforcement**: PhoenixKit's `phoenix_kit_ensure_admin` and `phoenix_kit_ensure_module_access` on_mount hooks automatically enforce permissions on admin routes. Sidebar navigation is gated per-user.

### User Registration

```elixir
# Register a new user
{:ok, user} = PhoenixKit.Users.Auth.register_user(%{
  email: "user@example.com",
  password: "securepassword123"
})

# First user automatically becomes Owner
```

---

## Troubleshooting

### "Repo not configured"

```elixir
# Ensure config is set
config :phoenix_kit, repo: MyApp.Repo
```

### "Routes not found"

```elixir
# Ensure you imported and called the macro
import PhoenixKitWeb.Integration
phoenix_kit_routes()
```

### "Mailer not sending emails"

```elixir
# Check your mailer is configured
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.SMTP,
  # ... your SMTP settings

# And PhoenixKit knows about it
config :phoenix_kit, mailer: MyApp.Mailer
```

### "Rate limiting not working"

PhoenixKit uses Hammer 7.x with ETS backend via `PhoenixKit.Users.RateLimiter.Backend`. No additional Hammer configuration is required. If you need to adjust rate limits:

```elixir
config :phoenix_kit, PhoenixKit.Users.RateLimiter,
  login_limit: 5,
  login_window_ms: 60_000
```

---

## Further Reading

- **[Custom Admin Pages](custom-admin-pages.md)** - Add pages to the admin sidebar
- **[Admin Dashboard Reference](dashboard/ADMIN_README.md)** - Admin navigation and tabs system
- **[Dashboard Components](dashboard/README.md)** - Tabs, subtabs, badges, and more

---

## For AI Assistants

When helping a developer with PhoenixKit:

1. **PhoenixKit is a Hex dependency** - Code lives in `deps/phoenix_kit/`
2. **Don't modify PhoenixKit files** - Create code in the user's app that calls PhoenixKit APIs
3. **Entity names are snake_case** - e.g., `"contact_form"`, not `"Contact Form"`
4. **Field keys are snake_case** - e.g., `"full_name"`, not `"Full Name"`
5. **First user is Owner** - First registered user gets the Owner role automatically
6. **Routes are prefixed** - Default is `/phoenix_kit/`, configurable via `url_prefix`
7. **Permissions are cached in Scope** - Use `Scope.has_module_access?/2` not raw DB queries
8. **Owner bypasses all permission checks** - No DB rows needed for Owner access
9. **Entities use `created_by_uuid`** - The field is `created_by_uuid`, not `created_by`
10. **Always use `entity.uuid`** - Never use `entity.id` for entity operations

---

**Last Updated**: 2026-03-02
