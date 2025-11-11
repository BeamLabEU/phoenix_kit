# Maintenance Mode Module

The Maintenance module provides a system-wide maintenance mode that allows you to temporarily show a maintenance page to non-admin users while you work on the site. Admins and owners can still access the site normally.

## Overview

This is a true maintenance mode system - not just a component you add to pages, but a system-wide feature that intercepts all page loads and conditionally shows maintenance content based on user permissions.

## Quick Start (Parent App Setup)

The maintenance mode module is automatically configured when you install PhoenixKit:

```bash
# Run the PhoenixKit installer
mix phoenix_kit.install
```

The installer automatically adds the required integration plug to your browser pipeline, so maintenance mode will work immediately after installation.

**That's it!** Now when you enable maintenance mode from `/admin/modules`, non-admin users will see the maintenance page on ALL pages of your site.

### What the Installer Does

The installer automatically adds this line to your `lib/your_app_web/router.ex`:

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {YourAppWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
  plug PhoenixKitWeb.Plugs.Integration  # ← Added automatically
end
```

No manual configuration required!

## Core Features

- **System-Wide Protection** – When enabled, ALL pages show maintenance content to non-admin users
- **Role-Based Bypass** – Admins and owners can access the site normally while maintenance mode is active
- **Conditional Rendering** – No redirects - page content is replaced inline for seamless experience
- **Live Refresh** – When maintenance mode is disabled, users just refresh and see real content
- **Customizable Content** – Configure header and subtext via database settings
- **Database Storage** – Settings persisted in `phoenix_kit_settings` table

## Module Structure

```
lib/modules/maintenance/
├── README.md                     # This documentation
├── maintenance.ex               # Main context module (pure Elixir)
├── settings.ex                   # Settings interface (pure Elixir)
└── web/                          # Web-specific code
    ├── plugs/
    │   └── maintenance_mode.ex   # Maintenance mode plug
    ├── components/
    │   └── maintenance_page.ex   # Maintenance page component
    └── settings.html.heex        # Settings UI template
```

## Integration Points

- **Plug:** `PhoenixKitWeb.Plugs.Integration` (main entry point that internally calls `PhoenixKitWeb.Plugs.MaintenanceMode` at `lib/modules/maintenance/web/plugs/maintenance_mode.ex`)
- **Context module:** `PhoenixKit.Maintenance` (at `lib/modules/maintenance/maintenance.ex`)
- **Settings interface:** `PhoenixKit.Maintenance` settings API (at `lib/modules/maintenance/settings.ex`)
- **Component:** `MaintenancePage.maintenance_page/1` (at `lib/modules/maintenance/web/components/maintenance_page.ex`)
- **Auth integration:** Checks user session for admin/owner role
- **Module card:** Displayed in Modules dashboard at `{prefix}/admin/modules`
- **Settings storage:** Database-backed via `phoenix_kit_settings` table

## How It Works

### 1. Plug Intercepts Request

When a request comes in, the `MaintenanceMode` plug runs early in the browser pipeline:

```elixir
def call(conn, _opts) do
  if UnderConstruction.enabled?() do
    user = get_user_from_session(conn)
    scope = Scope.for_user(user)

    if scope && (Scope.admin?(scope) || Scope.owner?(scope)) do
      conn  # Admin/Owner bypasses - continue to route normally
    else
      render_maintenance_page(conn)  # Non-admin sees maintenance page
    end
  else
    conn  # Maintenance disabled - continue normally
  end
end
```

### 2. Role Check

The plug:
1. Gets user from session token (if exists)
2. Creates scope for the user
3. Checks if user is admin or owner
4. Returns maintenance page HTML for non-admin users
5. Halts connection so request never reaches routes

### 3. Maintenance Page Rendering

For non-admin users, the plug renders a complete HTML page directly:

```elixir
defp render_maintenance_page(conn) do
  config = UnderConstruction.get_config()

  html = """
  <!DOCTYPE html>
  <html>
    <head>
      <title>#{config.header}</title>
      <link rel="stylesheet" href="/assets/app.css" />
    </head>
    <body>
      <!-- Full maintenance page with header, subtext, animation -->
    </body>
  </html>
  """

  conn
  |> send_resp(:service_unavailable, html)
  |> halt()
end
```

## Context API

### `PhoenixKit.Maintenance`

**Available functions:**

- `enabled?/0` – Check if maintenance mode is active (returns boolean)
- `enable_system/0` – Enable maintenance mode
- `disable_system/0` – Disable maintenance mode
- `get_header/0` – Get maintenance page header text
- `get_subtext/0` – Get maintenance page subtext
- `update_header/1` – Update header text
- `update_subtext/1` – Update subtext
- `get_config/0` – Get full configuration map

**Examples:**

```elixir
# Check if maintenance mode is enabled
if PhoenixKit.Maintenance.enabled?() do
  # Maintenance mode is active
end

# Enable maintenance mode
{:ok, setting} = PhoenixKit.Maintenance.enable_system()

# Disable maintenance mode
{:ok, setting} = PhoenixKit.Maintenance.disable_system()

# Update maintenance page content
PhoenixKit.Maintenance.update_header("Coming Soon!")
PhoenixKit.Maintenance.update_subtext("We're launching something amazing...")

# Get full configuration
config = PhoenixKit.Maintenance.get_config()
# => %{
#      enabled: true,
#      header: "Maintenance Mode",
#      subtext: "We'll be back soon..."
#    }
```

## Component Reference

### `MaintenancePage.maintenance_page/1`

Renders a full-page maintenance message with customizable content.

**Attributes:**
- `header` (string, optional) – Main heading text (default: loaded from settings)
- `subtext` (string, optional) – Descriptive message (default: loaded from settings)

**Examples:**

```heex
<%!-- Use settings from database --%>
<PhoenixKitWeb.Components.Core.MaintenancePage.maintenance_page />

<%!-- Custom content --%>
<PhoenixKitWeb.Components.Core.MaintenancePage.maintenance_page
  header="Coming Soon"
  subtext="We're building something special!"
/>
```

## Module Dashboard Integration

The maintenance mode module appears in the Modules dashboard at `{prefix}/admin/modules` with:

- **Toggle switch** – Enable/disable maintenance mode system-wide
- **Status badges** – Shows "Active" (warning) or "Inactive" (neutral)
- **Warning alert** – When active, shows "Non-admin users see maintenance page"
- **Content preview** – Displays current header and subtext
- **Stats** – Explains that admins/owners can still access the site

## Settings Storage

The module uses the PhoenixKit Settings system to persist configuration:

**Setting keys:**
- `maintenance_enabled` (boolean, default: `false`)
- `maintenance_header` (string, default: `"Maintenance Mode"`)
- `maintenance_subtext` (string, default: `"We'll be back soon. Our team is working hard to bring you something amazing!"`)

**Storage:** `phoenix_kit_settings` database table

## Use Cases

1. **Scheduled Maintenance** – Enable before deploying major updates
2. **Emergency Downtime** – Quickly show maintenance page during incidents
3. **Beta Testing** – Allow only admin team to access while testing new features
4. **Gradual Rollout** – Keep site in maintenance mode while adding team members
5. **Development Mode** – Work on live site without affecting users

## User Experience Flow

### Regular User

1. User visits site
2. `on_mount` hook checks maintenance mode → enabled
3. User is not admin → `@show_maintenance = true`
4. Layout renders maintenance page instead of content
5. User sees "Maintenance Mode" message
6. Admin disables maintenance mode
7. User refreshes page → sees real content (no redirect needed)

### Admin/Owner User

1. Admin visits site
2. `on_mount` hook checks maintenance mode → enabled
3. Admin has elevated role → `@show_maintenance = false`
4. Layout renders normal content
5. Admin sees real site and can work normally
6. (Optional) Admin sees warning banner at top

## Design Considerations

- **No Redirects** – Content replacement is inline, no URL changes
- **Live Refresh** – Users just refresh when maintenance ends
- **Role-Based** – Owner and Admin roles bypass automatically
- **Settings-Driven** – All configuration stored in database
- **Graceful Degradation** – If settings missing, uses sensible defaults
- **Performance** – Check runs only on mount, minimal overhead

## Customization Examples

### Update Maintenance Message

```elixir
# Via IEx or Phoenix console
PhoenixKit.Maintenance.update_header("Scheduled Maintenance")
PhoenixKit.Maintenance.update_subtext("We'll be back online at 3:00 PM EST. Thank you for your patience!")
```

### Enable/Disable via Code

```elixir
# Enable for deployment
PhoenixKit.Maintenance.enable_system()

# Run migrations, deploy new code, test, etc.

# Disable when ready
PhoenixKit.Maintenance.disable_system()
```

### Check Status in Templates

```heex
<%= if PhoenixKit.Maintenance.enabled?() do %>
  <div class="alert alert-warning">
    Maintenance mode is currently active for non-admin users.
  </div>
<% end %>
```

## Operational Notes

- The maintenance check runs on every LiveView mount via `on_mount` hook
- Regular Phoenix controllers (non-LiveView) are not affected by this system
- Static assets and auth routes work normally even in maintenance mode
- The `show_maintenance` assign is set per-socket, allowing real-time updates
- When disabled, the `show_maintenance` assign is `false` for all users
- No database queries on each request - settings are cached

## Future Enhancements

Potential additions to this module could include:

- Admin warning banner when maintenance mode is active
- Scheduled maintenance mode (enable/disable at specific times)
- Custom maintenance page templates
- IP whitelist for bypassing maintenance mode
- Maintenance mode history/audit log
- API endpoint protection during maintenance
- Email notifications when maintenance mode changes
- Integration with deployment systems

## Troubleshooting

### Users still see normal content after enabling

- Check that the LiveView is using `on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}]`
- Verify `show_maintenance` assign is being set in socket
- Check that `root.html.heex` layout includes the maintenance mode check

### Admins see maintenance page

- Verify user has Admin or Owner role in database
- Check that `phoenix_kit_current_scope` is being assigned correctly
- Ensure `Scope.admin?()` or `Scope.owner?()` returns true for the user

### Maintenance page doesn't match settings

- Clear browser cache and refresh
- Check Settings database for correct values
- Verify `PhoenixKit.Maintenance.get_header()` returns expected value

Update this README whenever new features, components, or workflows are added to the Maintenance module so CLAUDE.md can remain lightweight.
