# PhoenixKit Integration Guide

**For developers using PhoenixKit as a Hex dependency in their Phoenix application.**

This guide is designed to help both developers and AI assistants (Claude, Cursor, Copilot, Tidewave MCP, etc.) understand how to integrate and use PhoenixKit effectively.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Installation](#installation)
3. [Configuration Reference](#configuration-reference)
4. [Using the Entities System](#using-the-entities-system)
5. [Public Forms](#public-forms)
6. [Authentication Integration](#authentication-integration)
7. [Common Tasks](#common-tasks)
8. [API Reference](#api-reference)
9. [Troubleshooting](#troubleshooting)

---

## Quick Start

```elixir
# 1. Add to mix.exs
{:phoenix_kit, "~> 1.6"}

# 2. Run installation
mix deps.get
mix phoenix_kit.install

# 3. Run migrations
mix ecto.migrate

# 4. Add routes to your router.ex
import PhoenixKitWeb.Integration
phoenix_kit_routes()

# 5. Start your server
mix phx.server
# Visit /phoenix_kit/admin/dashboard
```

---

## Installation

### Step 1: Add Dependency

```elixir
# mix.exs
defp deps do
  [
    {:phoenix_kit, "~> 1.6"}
  ]
end
```

### Step 2: Install

```bash
mix deps.get
mix phoenix_kit.install --repo MyApp.Repo
```

The installer will:
- Detect your Repo automatically (or use `--repo` to specify)
- Add configuration to `config/config.exs`
- Generate migrations
- Set up mailer integration

### Step 3: Configure

The installer adds this to your config. Customize as needed:

```elixir
# config/config.exs
config :phoenix_kit,
  repo: MyApp.Repo,
  mailer: MyApp.Mailer,  # Uses your app's mailer
  url_prefix: "/phoenix_kit"  # URL prefix for all routes

# Optional: Use your app's layouts
config :phoenix_kit,
  layout: {MyAppWeb.Layouts, :app},
  root_layout: {MyAppWeb.Layouts, :root}
```

### Step 4: Add Routes

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
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000, cleanup_interval_ms: 60_000]}

config :phoenix_kit, PhoenixKit.Users.RateLimiter,
  login_limit: 5,
  login_window_ms: 60_000,
  magic_link_limit: 3,
  magic_link_window_ms: 300_000
```

---

## Using the Entities System

The Entities system lets you create custom content types without database migrations.

### Enable the System

```elixir
# Via code
PhoenixKit.Entities.enable_system()

# Or via admin UI at /phoenix_kit/admin/modules
```

### Create an Entity Programmatically

```elixir
{:ok, entity} = PhoenixKit.Entities.create_entity(%{
  name: "contact_form",
  display_name: "Contact Form",
  description: "Contact form submissions",
  icon: "hero-envelope",
  status: "published",
  created_by: admin_user.id,
  fields_definition: [
    %{
      "type" => "text",
      "key" => "name",
      "label" => "Full Name",
      "required" => true
    },
    %{
      "type" => "email",
      "key" => "email",
      "label" => "Email Address",
      "required" => true
    },
    %{
      "type" => "textarea",
      "key" => "message",
      "label" => "Message",
      "required" => true
    }
  ]
})
```

### Create Data Records

```elixir
{:ok, record} = PhoenixKit.Entities.EntityData.create(%{
  entity_id: entity.id,
  title: "New Contact",
  status: "published",
  created_by: user.id,
  data: %{
    "name" => "John Doe",
    "email" => "john@example.com",
    "message" => "Hello!"
  }
})
```

### Query Records

```elixir
# All records for an entity
records = PhoenixKit.Entities.EntityData.list_by_entity(entity.id)

# Search by title
results = PhoenixKit.Entities.EntityData.search_by_title(entity.id, "John")

# Get entity by name
entity = PhoenixKit.Entities.get_entity_by_name("contact_form")
```

### Available Field Types

| Type | Description | Requires Options |
|------|-------------|------------------|
| `text` | Single-line text | No |
| `textarea` | Multi-line text | No |
| `email` | Email with validation | No |
| `url` | URL with validation | No |
| `number` | Numeric input | No |
| `boolean` | True/false toggle | No |
| `date` | Date picker | No |
| `rich_text` | WYSIWYG editor | No |
| `select` | Dropdown | Yes |
| `radio` | Radio buttons | Yes |
| `checkbox` | Multiple checkboxes | Yes |
| `image` | Image upload (placeholder) | No |
| `file` | File upload (placeholder) | No |
| `relation` | Link to other entity | Yes |

---

## Public Forms

Embed entity-based forms on public pages for contact forms, surveys, lead capture, etc.

### Enable Public Form for an Entity

```elixir
# Via admin UI: /phoenix_kit/admin/entities/:id/edit
# Or programmatically:
PhoenixKit.Entities.update_entity(entity, %{
  settings: %{
    "public_form_enabled" => true,
    "public_form_fields" => ["name", "email", "message"],
    "public_form_title" => "Contact Us",
    "public_form_description" => "We'll get back to you within 24 hours.",
    "public_form_submit_text" => "Send Message",
    "public_form_success_message" => "Thank you! We received your message."
  }
})
```

### Embed in Your Templates

```heex
<%# In any .heex template %>
<.live_component
  module={PhoenixKitWeb.Components.Blogging.EntityForm}
  id="contact-form"
  entity_slug="contact_form"
/>

<%# Or use the function component %>
<PhoenixKitWeb.Components.Blogging.EntityForm.render entity_slug="contact_form" />
```

### Security Options

Configure in entity settings or admin UI:

| Setting | Default | Description |
|---------|---------|-------------|
| `public_form_honeypot` | false | Hidden field to catch bots |
| `public_form_time_check` | false | Reject submissions < 3 seconds |
| `public_form_rate_limit` | false | 5 submissions/minute per IP |
| `public_form_debug_mode` | false | Show detailed error messages |
| `public_form_collect_metadata` | true | Capture IP, browser, device |

### Security Actions

Each security check can be configured with an action:

| Action | Behavior |
|--------|----------|
| `reject_silent` | Show fake success, don't save |
| `reject_error` | Show error message, don't save |
| `save_suspicious` | Save with "draft" status, flag in metadata |
| `save_log` | Save normally, log warning |

### Form Submission Route

Forms POST to: `POST /phoenix_kit/entities/:entity_slug/submit`

This is handled by `PhoenixKitWeb.EntityFormController`.

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
PhoenixKit.Users.Roles.has_role?(user, "admin")
PhoenixKit.Users.Roles.has_role?(user, "owner")

# Get user's roles
roles = PhoenixKit.Users.Roles.list_user_roles(user.id)

# Check in templates
<%= if PhoenixKit.Users.Roles.has_role?(@current_user, "admin") do %>
  <.link navigate="/admin">Admin Panel</.link>
<% end %>
```

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

## Common Tasks

### Task: Add PhoenixKit Navigation to Your Layout

```heex
<%# In your app's layout %>
<nav>
  <%= if @current_user do %>
    <.link navigate="/phoenix_kit/admin/dashboard">Admin</.link>
    <.link href="/phoenix_kit/users/log_out" method="delete">Log out</.link>
  <% else %>
    <.link navigate="/phoenix_kit/users/log_in">Log in</.link>
  <% end %>
</nav>
```

### Task: Create a Contact Form Entity

```elixir
# In a migration or seeds.exs
admin = PhoenixKit.Users.Auth.get_user_by_email("admin@example.com")

{:ok, _entity} = PhoenixKit.Entities.create_entity(%{
  name: "contact",
  display_name: "Contact Submission",
  status: "published",
  created_by: admin.id,
  fields_definition: [
    %{"type" => "text", "key" => "name", "label" => "Name", "required" => true},
    %{"type" => "email", "key" => "email", "label" => "Email", "required" => true},
    %{"type" => "select", "key" => "subject", "label" => "Subject", "required" => true,
      "options" => ["General Inquiry", "Support", "Sales", "Partnership"]},
    %{"type" => "textarea", "key" => "message", "label" => "Message", "required" => true}
  ],
  settings: %{
    "public_form_enabled" => true,
    "public_form_fields" => ["name", "email", "subject", "message"],
    "public_form_title" => "Contact Us",
    "public_form_honeypot" => true,
    "public_form_time_check" => true,
    "public_form_rate_limit" => true
  }
})
```

### Task: List All Contact Submissions

```elixir
entity = PhoenixKit.Entities.get_entity_by_name("contact")
submissions = PhoenixKit.Entities.EntityData.list_by_entity(entity.id)

for submission <- submissions do
  IO.puts("#{submission.data["name"]} - #{submission.data["email"]}")
end
```

### Task: Export Entity Data

```elixir
entity = PhoenixKit.Entities.get_entity_by_name("contact")
records = PhoenixKit.Entities.EntityData.list_by_entity(entity.id)

# Convert to list of maps
data = Enum.map(records, fn r ->
  Map.merge(r.data, %{
    "id" => r.id,
    "created_at" => r.date_created,
    "status" => r.status
  })
end)

# Export as JSON
Jason.encode!(data)
```

---

## API Reference

### PhoenixKit.Entities

```elixir
# Check if system is enabled
PhoenixKit.Entities.enabled?() :: boolean()

# Enable/disable
PhoenixKit.Entities.enable_system() :: {:ok, Setting.t()}
PhoenixKit.Entities.disable_system() :: {:ok, Setting.t()}

# Get by ID
PhoenixKit.Entities.get_entity(id) :: Entity.t() | nil        # Returns nil if not found
PhoenixKit.Entities.get_entity!(id) :: Entity.t()             # Raises if not found
PhoenixKit.Entities.get_entity_by_name(name) :: Entity.t() | nil

# List
PhoenixKit.Entities.list_entities() :: [Entity.t()]
PhoenixKit.Entities.list_active_entities() :: [Entity.t()]    # Only status: "published"

# Create/Update/Delete
PhoenixKit.Entities.create_entity(attrs) :: {:ok, Entity.t()} | {:error, Changeset.t()}
PhoenixKit.Entities.update_entity(entity, attrs) :: {:ok, Entity.t()} | {:error, Changeset.t()}
PhoenixKit.Entities.delete_entity(entity) :: {:ok, Entity.t()} | {:error, Changeset.t()}

# Changeset (for forms)
PhoenixKit.Entities.change_entity(entity, attrs \\ %{}) :: Changeset.t()

# Stats
PhoenixKit.Entities.get_system_stats() :: %{
  total_entities: integer(),
  active_entities: integer(),
  total_data_records: integer()
}
```

### PhoenixKit.Entities.EntityData

```elixir
# Get by ID
EntityData.get(id) :: EntityData.t() | nil           # Returns nil if not found
EntityData.get!(id) :: EntityData.t()                # Raises if not found
EntityData.get_by_slug(entity_id, slug) :: EntityData.t() | nil

# List/Query
EntityData.list_all() :: [EntityData.t()]
EntityData.list_by_entity(entity_id) :: [EntityData.t()]
EntityData.list_by_entity_and_status(entity_id, status) :: [EntityData.t()]
EntityData.search_by_title(entity_id, query) :: [EntityData.t()]

# Create/Update/Delete
EntityData.create(attrs) :: {:ok, EntityData.t()} | {:error, Changeset.t()}
EntityData.update(record, attrs) :: {:ok, EntityData.t()} | {:error, Changeset.t()}
EntityData.delete(record) :: {:ok, EntityData.t()} | {:error, Changeset.t()}

# Changeset (for forms)
EntityData.change(record, attrs \\ %{}) :: Changeset.t()
```

### PhoenixKit.Users.Auth

```elixir
# User management
Auth.get_user!(id) :: User.t()
Auth.get_user_by_email(email) :: User.t() | nil
Auth.register_user(attrs) :: {:ok, User.t()} | {:error, Changeset.t()}

# Authentication
Auth.authenticate_user(email, password) :: {:ok, User.t()} | {:error, :invalid_credentials}

# Session
Auth.generate_user_session_token(user) :: binary()
Auth.get_user_by_session_token(token) :: User.t() | nil
Auth.delete_user_session_token(token) :: :ok
```

### PhoenixKit.Users.Roles

```elixir
Roles.has_role?(user, role_name) :: boolean()
Roles.list_user_roles(user_id) :: [Role.t()]
Roles.assign_role(user_id, role_name, assigned_by) :: {:ok, RoleAssignment.t()} | {:error, term()}
Roles.remove_role(user_id, role_name) :: :ok | {:error, term()}
```

### PhoenixKit.Settings

```elixir
Settings.get(key) :: String.t() | nil
Settings.get(key, default) :: String.t()
Settings.set(key, value) :: {:ok, Setting.t()}
Settings.get_boolean(key) :: boolean()
Settings.get_integer(key) :: integer()
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

### "Entities menu not showing"

The Entities module must be enabled:
```elixir
PhoenixKit.Entities.enable_system()
# Or visit /phoenix_kit/admin/modules and enable it
```

### "Public form shows 'unavailable'"

Check that:
1. Entity status is "published"
2. `public_form_enabled` is true
3. `public_form_fields` has at least one field

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

Ensure Hammer is configured:
```elixir
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000, cleanup_interval_ms: 60_000]}
```

---

## File Locations

When working with PhoenixKit source (for debugging or understanding):

| Purpose | Location |
|---------|----------|
| Entities core logic | `deps/phoenix_kit/lib/phoenix_kit/entities/` |
| Entity data schema | `deps/phoenix_kit/lib/phoenix_kit/entities/entity_data.ex` |
| Field types | `deps/phoenix_kit/lib/phoenix_kit/entities/field_types.ex` |
| Public form controller | `deps/phoenix_kit/lib/phoenix_kit_web/controllers/entity_form_controller.ex` |
| Public form component | `deps/phoenix_kit/lib/phoenix_kit_web/components/blogging/entity_form.ex` |
| Authentication | `deps/phoenix_kit/lib/phoenix_kit/users/auth.ex` |
| User schema | `deps/phoenix_kit/lib/phoenix_kit/users/auth/user.ex` |
| Roles | `deps/phoenix_kit/lib/phoenix_kit/users/roles.ex` |
| Settings | `deps/phoenix_kit/lib/phoenix_kit/settings.ex` |
| Router integration | `deps/phoenix_kit/lib/phoenix_kit_web/integration.ex` |

---

## For AI Assistants

When helping a developer with PhoenixKit:

1. **PhoenixKit is a Hex dependency** - Code lives in `deps/phoenix_kit/`
2. **Don't modify PhoenixKit files** - Create code in the user's app that calls PhoenixKit APIs
3. **Check if Entities is enabled** - `PhoenixKit.Entities.enabled?()`
4. **Entity names are snake_case** - e.g., `"contact_form"`, not `"Contact Form"`
5. **Field keys are snake_case** - e.g., `"full_name"`, not `"Full Name"`
6. **Public forms need fields selected** - Both `public_form_enabled` and `public_form_fields` must be set
7. **First user is Owner** - First registered user gets the Owner role automatically
8. **Routes are prefixed** - Default is `/phoenix_kit/`, configurable via `url_prefix`

### Common Patterns

```elixir
# Get current user in LiveView
@current_user = socket.assigns[:current_user]

# Check admin access
if PhoenixKit.Users.Roles.has_role?(user, "admin"), do: ...

# Create entity with public form
PhoenixKit.Entities.create_entity(%{
  name: "...",
  fields_definition: [...],
  settings: %{"public_form_enabled" => true, "public_form_fields" => [...]}
})

# Query submissions
entity = PhoenixKit.Entities.get_entity_by_name("contact")
records = PhoenixKit.Entities.EntityData.list_by_entity(entity.id)
```

---

**Last Updated**: 2025-12-03
