# Phoenix Kit Authentication Header Integration Guide

This guide documents the steps to add authentication status display to your Phoenix application header when using the `phoenix_kit` library.

## Prerequisites
- Phoenix application with `phoenix_kit` installed and configured
- `phoenix_kit_routes()` already added to your router

## Integration Steps

### Step 1: Mount Authentication Scope in Router

Update your router to mount the authentication scope for your main live sessions. This makes `@phoenix_kit_current_scope` available in all LiveViews and layouts.

**File:** `lib/your_app_web/router.ex`

```elixir
# Before
live_session :default, layout: {YourAppWeb.Layouts, :app} do
  live "/", HomeLive
  # ... other routes
end

# After
live_session :default,
  layout: {YourAppWeb.Layouts, :app},
  on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
  live "/", HomeLive
  # ... other routes
end
```

### Step 2: Import Authentication Helpers in Layout

Add the Scope alias to your layouts module to access authentication helper functions.

**File:** `lib/your_app_web/components/layouts.ex`

```elixir
defmodule YourAppWeb.Layouts do
  use YourAppWeb, :html
  
  # Add this line
  alias PhoenixKit.Users.Auth.Scope
  
  embed_templates "layouts/*"
  # ... rest of module
end
```

### Step 3: Add Authentication UI to Header

Update your header navigation to conditionally display authentication status and actions.

**File:** `lib/your_app_web/components/layouts.ex` (in the `app/1` function)

```heex
<div class="flex-none">
  <ul class="flex flex-row px-1 space-x-4 items-center">
    <!-- Your existing navigation items -->
    
    <%= if assigns[:phoenix_kit_current_scope] && Scope.authenticated?(assigns.phoenix_kit_current_scope) do %>
      <!-- Logged in: Show user info and actions -->
      <li class="hidden sm:flex items-center text-sm text-base-content/70">
        <.icon name="hero-user-circle" class="size-4 mr-1" />
        <%= Scope.user_email(assigns.phoenix_kit_current_scope) %>
      </li>
      <li>
        <.link href={PhoenixKit.Utils.Routes.path("/dashboard/settings")} class="btn btn-ghost btn-sm">
          <.icon name="hero-user" class="size-4" />
          <span class="hidden sm:inline ml-1">Account</span>
        </.link>
      </li>
      <li>
        <.link href={PhoenixKit.Utils.Routes.path("/users/log-out")} method="delete" class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-right-on-rectangle" class="size-4" />
          <span class="hidden sm:inline ml-1">Log out</span>
        </.link>
      </li>
    <% else %>
      <!-- Logged out: Show login/signup options -->
      <li>
        <.link href={PhoenixKit.Utils.Routes.path("/users/log-in")} class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-left-on-rectangle" class="size-4" />
          <span class="hidden sm:inline ml-1">Log in</span>
        </.link>
      </li>
      <li>
        <.link href={PhoenixKit.Utils.Routes.path("/users/register")} class="btn btn-primary btn-sm">
          <.icon name="hero-user-plus" class="size-4" />
          <span class="hidden sm:inline ml-1">Sign up</span>
        </.link>
      </li>
    <% end %>
    
    <!-- Your other navigation items like theme toggle -->
  </ul>
</div>
```

## Available Phoenix Kit Routes

After integration, these authentication routes are available:

### User Authentication Routes
- `{prefix}/users/log-in` - User login page
- `{prefix}/users/register` - User registration page
- `{prefix}/users/log-out` - Logout endpoint (DELETE method)
- `{prefix}/users/magic-link` - Passwordless login
- `{prefix}/users/reset-password` - Password reset flow
- `{prefix}/users/confirm/:token` - Email confirmation

### User Dashboard Routes (when enabled)
- `{prefix}/dashboard/settings` - User account settings
- `{prefix}/dashboard` - User dashboard home

Where `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

## Authentication Helpers

Once the scope is mounted, you can use these helpers in your templates:

```elixir
# Check if user is authenticated
Scope.authenticated?(@phoenix_kit_current_scope)

# Get user information
Scope.user(@phoenix_kit_current_scope)        # Full user struct
Scope.user_email(@phoenix_kit_current_scope)   # User's email
Scope.user_uuid(@phoenix_kit_current_scope)    # User's UUID

# Check user status
Scope.anonymous?(@phoenix_kit_current_scope)   # Is anonymous?
Scope.admin?(@phoenix_kit_current_scope)       # Has admin role?
Scope.owner?(@phoenix_kit_current_scope)       # Has owner role?
```

## Styling Notes

The example uses:
- DaisyUI button classes (`btn`, `btn-ghost`, `btn-primary`, `btn-sm`)
- Heroicons for icons (`hero-user`, `hero-arrow-left-on-rectangle`, etc.)
- Responsive utilities to hide/show elements on mobile

Adjust the styling to match your application's design system.

## Testing

After implementation:
1. Visit your application homepage - you should see "Log in" and "Sign up" buttons
2. Click "Sign up" to create an account
3. After logging in, the header should display your email and show "Account" and "Log out" options
4. The logout button should properly end your session

## Troubleshooting

**No authentication UI showing:**
- Verify `on_mount` is added to your live_session
- Check that `phoenix_kit_routes()` is called in your router
- Ensure the Scope alias is imported in your layouts module

**Routes not found:**
- Confirm routes with `mix phx.routes | grep phoenix_kit`
- Verify `phoenix_kit` is properly installed in your dependencies

**Logout not working:**
- Ensure you're using `method="delete"` on the logout link
- The logout route requires a DELETE HTTP method, not GET