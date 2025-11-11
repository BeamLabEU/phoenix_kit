# PhoenixKit Usage Rules

PhoenixKit is a comprehensive SaaS starter kit for Phoenix applications that provides authentication, authorization, admin interfaces, and email tracking out of the box.

## What PhoenixKit Provides

### User Authentication & Authorization
- Complete user registration, login, and logout flows
- Password and magic link (passwordless) authentication
- Email confirmation workflow
- Password reset functionality
- Session management with secure tokens
- Role-based access control with Owner, Admin, and User roles
- Custom role creation and management

### Database Tables
- Uses `phoenix_kit_users` table (not `users`) for all user data
- Manages `phoenix_kit_users_tokens` for authentication tokens (supports magic link registration with null user_id)
- Provides `phoenix_kit_user_roles` and `phoenix_kit_user_role_assignments` for RBAC
- Includes `phoenix_kit_referral_codes` and `phoenix_kit_referral_code_usages` for referral programs
- Handles email tracking with `phoenix_kit_email_logs`, `phoenix_kit_email_events`, and `phoenix_kit_email_blocklist`
- Stores email templates in `phoenix_kit_email_templates` and `phoenix_kit_email_template_variables`
- Manages OAuth providers with `phoenix_kit_user_oauth_providers` (V16+)
- System settings in `phoenix_kit_settings` table with key/value storage

### Admin Backend
- Built-in admin dashboard at `/phoenix_kit/admin/dashboard`
- User management interface at `/phoenix_kit/admin/users`
- Role management at `/phoenix_kit/admin/users/roles`
- Session management at `/phoenix_kit/admin/users/sessions` and `/phoenix_kit/admin/users/live_sessions`
- Global settings at `/phoenix_kit/admin/settings`
- Modules manager at `/phoenix_kit/admin/modules`
- Referral codes management at `/phoenix_kit/admin/users/referral-codes`
- Referral codes settings at `/phoenix_kit/admin/settings/referral-codes`
- Languages management at `/phoenix_kit/admin/modules/languages`
- Email system interfaces:
  - Email logs: `/phoenix_kit/admin/emails`
  - Email details: `/phoenix_kit/admin/emails/email/:id`
  - Email metrics: `/phoenix_kit/admin/emails/dashboard`
  - Email queue: `/phoenix_kit/admin/emails/queue`
  - Email blocklist: `/phoenix_kit/admin/emails/blocklist`
  - Email templates: `/phoenix_kit/admin/emails/templates`
  - Email settings: `/phoenix_kit/admin/settings/emails`

### Referral Program
- Complete referral code creation, validation, and usage tracking
- Admin interface for referral code management at `/phoenix_kit/admin/users/referral-codes`
- Flexible expiration system with optional "no expiration" support
- Beneficiary system allowing referral codes to be assigned to specific users
- Professional referral code generation with confusion-resistant character set
- User search functionality with real-time filtering for beneficiary assignment
- Configurable limits for maximum uses per code and maximum codes per user
- Automatic usage tracking with audit trail (created_at, used_at, beneficiary)
- Integration with user registration flow
- Database tables: `phoenix_kit_referral_codes`, `phoenix_kit_referral_code_usages`

### Email Template System
- Database-driven email templates with CRUD operations
- Template editor interface with HTML structure, preview, and test functionality
- Template list interface with search, filtering, and status management
- Automatic variable extraction and substitution in templates
- Smart variable descriptions for common template variables
- Template categories (authentication, notifications, marketing, transactional)
- Template status management (draft, active, inactive)
- System template protection (prevents deletion of critical templates)
- Default templates for authentication flows (confirmation, password reset, magic link)
- Test send functionality for template validation
- Database table: `phoenix_kit_email_templates`
- Admin interface at `/phoenix_kit/admin/modules/emails/templates`

### Languages Module
- Complete multilingual support system with database-driven language configuration
- Language management with enable/disable functionality per language
- Default language configuration with automatic fallback
- Language codes support (en, es, fr, etc.)
- Locale-aware routing with dynamic locale prefixes
- Integration with PhoenixKit router for automatic locale scope generation
- Database-stored language configuration using JSON settings
- Admin interface for language management at `/phoenix_kit/admin/modules/languages`
- Functions: `enabled?/0`, `get_languages/0`, `get_enabled_languages/0`, `get_default_language/0`
- Module: `PhoenixKit.Module.Languages`

### Emails
- Email tracking with delivery status and events
- Rate limiting and archival capabilities
- Support for multiple email providers (AWS SES, SendGrid, Mailgun, SMTP)
- Email interception for development/testing
- Comprehensive email metrics and logging

### Settings Management
- Global application settings storage
- Timezone and time format configuration
- Extensible key-value settings system

### Authentication Scopes
PhoenixKit provides three authentication levels via `on_mount` hooks:
- `:phoenix_kit_mount_current_scope` - Loads user if authenticated, allows anonymous
- `:phoenix_kit_redirect_if_authenticated_scope` - Redirects authenticated users away
- `:phoenix_kit_ensure_authenticated_scope` - Requires authentication, redirects to login if not authenticated
- `:phoenix_kit_ensure_admin` - Requires admin role
- `:phoenix_kit_ensure_owner` - Requires owner role

### Integration Points
- Uses your existing Ecto repository
- Integrates with Phoenix router via `phoenix_kit_routes()`
- Optional layout integration with your app's layouts
- Configurable URL prefix for all routes

### Caching System
- Built-in caching functionality for frequently accessed data
- Module-based cache organization

### Utilities
- Repository helpers for common database operations
- Location tracking for user registrations (IP, country, region, city)
- Referral code generation and tracking
- PubSub integration for real-time updates

## Important Conventions

### Database References
- Always reference `phoenix_kit_users` when creating foreign keys to users
- Use `references(:phoenix_kit_users, on_delete: :delete_all)` in migrations

### OAuth Authentication (V16+)
- OAuth providers support (Google, Apple, GitHub) using Ueberauth
- All OAuth dependencies included automatically with PhoenixKit
- Runtime control via admin settings (`oauth_enabled`)
- Automatic account linking by email address
- OAuth provider management per user in database
- Access routes: `/phoenix_kit/users/auth/:provider`
- Token storage for future API calls
- Referral code support via query params: `/phoenix_kit/users/auth/google?referral_code=ABC123`
- OAuth buttons automatically hide when disabled in settings
- Database table: `phoenix_kit_user_oauth_providers`

### Magic Link Registration (V16+)
- Passwordless two-step registration via email
- Magic link request at `/phoenix_kit/users/register/magic-link`
- Registration completion at `/phoenix_kit/users/register/complete/:token`
- Configurable expiry time (default: 30 minutes)
- Automatic email verification on completion
- Referral code support in registration flow
- Modified tokens table to allow null user_id for magic_link_registration context

### User Access
- Access current user via `@phoenix_kit_current_scope` assign in LiveViews
- Use `PhoenixKit.Users.Auth.Scope` module for scope queries
- Never create custom authentication - always use PhoenixKit

### Role Management
- Check roles with `PhoenixKit.Users.Roles.user_has_role?/2`
- Assign roles with `PhoenixKit.Users.Roles.promote_to_admin/1` and similar functions
- First registered user automatically becomes Owner

## Component-Based Helpers (CRITICAL RULE)

### ❌ NEVER Use Private Helper Functions in Templates

**Problem**: Elixir compiler cannot see function calls made from HEEX templates, resulting in false "unused function" warnings.

```elixir
# ❌ WRONG - Creates compiler warnings
defmodule MyLive do
  defp format_date(date), do: Calendar.strftime(date, "%Y-%m-%d")
end

# Template: {format_date(user.created_at)}  ← Compiler doesn't see this
```

### ✅ ALWAYS Use Phoenix Components

**Solution**: Create reusable Phoenix Components that compiler can track.

```elixir
# ✅ CORRECT - Compiler sees component usage
defmodule PhoenixKitWeb.Components.Core.TimeDisplay do
  use Phoenix.Component

  attr :date, :any, required: true
  def formatted_date(assigns) do
    ~H"""<span>{Calendar.strftime(@date, "%Y-%m-%d")}</span>"""
  end
end

# Template: <.formatted_date date={user.created_at} />  ← Compiler tracks this
```

### How to Add New Helper Components

1. **Create component file**: `lib/phoenix_kit_web/components/core/[category].ex`
2. **Add import**: Edit `lib/phoenix_kit_web.ex` → `core_components()` function
3. **Use in templates**: `<.component_name attr={value} />`

**Existing component categories:**
- `badge.ex` - Role/status badges (`<.role_badge />`, `<.user_status_badge />`)
- `time_display.ex` - Time formatting (`<.time_ago />`, `<.expiration_date />`)
- `user_info.ex` - User data (`<.primary_role />`, `<.users_count />`)
- Form components: `button.ex`, `input.ex`, `select.ex`, `checkbox.ex`

### Component Best Practices

1. ✅ **Group related helpers** - One category per file (time, currency, badges)
2. ✅ **Document with `@doc`** - Include examples and attribute descriptions
3. ✅ **Use `attr` validation** - Specify `:required`, `:default`, `:values`
4. ✅ **Private helpers OK** - Use `defp` INSIDE components for internal logic
5. ✅ **Semantic naming** - `<.time_ago />` not `<.fmt_t />`

### Migration Pattern

```elixir
# STEP 1: Move helper to component
# From: lib/my_live.ex
defp user_status_text(active, confirmed) do
  case {active, confirmed} do
    {false, _} -> "Inactive"
    {true, nil} -> "Unconfirmed"
    {true, _} -> "Active"
  end
end

# To: lib/phoenix_kit_web/components/core/badge.ex
attr :is_active, :boolean, required: true
attr :confirmed_at, :any, default: nil

def user_status_badge(assigns) do
  ~H"""
  <span class="badge">{status_text(@is_active, @confirmed_at)}</span>
  """
end

defp status_text(false, _), do: "Inactive"
defp status_text(true, nil), do: "Unconfirmed"
defp status_text(true, _), do: "Active"

# STEP 2: Update template
# From: {user_status_text(user.is_active, user.confirmed_at)}
# To: <.user_status_badge is_active={user.is_active} confirmed_at={user.confirmed_at} />

# STEP 3: Add import to lib/phoenix_kit_web.ex
import PhoenixKitWeb.Components.Core.Badge
```

### Why This Matters

- ✅ **Zero compiler warnings** - All component usage is tracked
- ✅ **Type safety** - Attributes validated at compile time
- ✅ **Reusability** - Use same component across all LiveViews

## UI/UX Best Practices

### Confirmation Dialogs in Phoenix LiveView

**CRITICAL**: Never use `data-confirm` attribute with Phoenix LiveView. It causes browser compatibility issues, especially in Safari where it may trigger multiple confirmation dialogs.

**❌ WRONG - Causes Safari Issues:**
```heex
<button
  phx-click="delete_item"
  data-confirm="Are you sure?"
>
  Delete
</button>
```

**✅ CORRECT - Use Phoenix LiveView Modal:**

#### Template Implementation
```heex
<%!-- Button triggers modal (no data-confirm) --%>
<button
  phx-click="request_delete"
  phx-value-id={item.id}
  phx-value-name={item.name}
>
  Delete
</button>

<%!-- Confirmation Modal --%>
<%= if assigns[:confirmation_modal] && @confirmation_modal.show do %>
  <div class="modal modal-open">
    <div class="modal-box">
      <h3 class="font-bold text-lg">{@confirmation_modal.title}</h3>
      <p class="py-4">{@confirmation_modal.message}</p>
      <div class="modal-action">
        <button class="btn btn-ghost" phx-click="cancel_confirmation">
          Cancel
        </button>
        <button
          class="btn btn-primary"
          phx-click="confirm_action"
          phx-value-action={@confirmation_modal.action}
          phx-value-id={@confirmation_modal.id}
        >
          {@confirmation_modal.button_text}
        </button>
      </div>
    </div>
  </div>
<% end %>
```

#### LiveView Handler Pattern
```elixir
def mount(params, _session, socket) do
  socket = assign(socket, :confirmation_modal, %{show: false})
  {:ok, socket}
end

# Request confirmation
def handle_event("request_delete", %{"id" => id, "name" => name}, socket) do
  modal = %{
    show: true,
    title: "Confirm Delete",
    message: "Are you sure you want to delete #{name}?",
    button_text: "Delete",
    action: "delete_item",
    id: id
  }
  {:noreply, assign(socket, :confirmation_modal, modal)}
end

# Cancel confirmation
def handle_event("cancel_confirmation", _params, socket) do
  {:noreply, assign(socket, :confirmation_modal, %{show: false})}
end

# Execute confirmed action
def handle_event("confirm_action", %{"action" => action, "id" => id}, socket) do
  socket = assign(socket, :confirmation_modal, %{show: false})

  case action do
    "delete_item" -> handle_delete(id, socket)
    _ -> {:noreply, socket}
  end
end
```

### Benefits

- ✅ **Cross-browser compatibility** - Works in all browsers including Safari
- ✅ **Better UX** - Customizable modal design matching your theme
- ✅ **Flexible** - Can include additional information in confirmation dialog
- ✅ **Testable** - Can be tested with LiveView testing helpers
- ✅ **No JavaScript** - Pure Phoenix LiveView solution
- ✅ **Documentation** - Self-documenting with `@doc` and examples
- ✅ **Maintainability** - Single source of truth for formatting logic

### Protected Routes
- Wrap protected LiveView routes in `live_session` with appropriate `on_mount` hooks
- Use scope-based authentication for fine-grained access control

## Installation
PhoenixKit uses Igniter for semi-automatic installation, handling migration generation, configuration, and router integration automatically.

## Architecture
- Library-first design (not an OTP application)
- PostgreSQL-only for production optimization
- Versioned schema migrations with forward compatibility
- Minimal dependencies, uses your existing infrastructure