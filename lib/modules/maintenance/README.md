# Maintenance Mode Module

System-wide maintenance mode that redirects non-admin users to a dedicated `/maintenance` LiveView page. Admins and owners bypass maintenance and see the real site.

## Features

- **Redirect-based** -- plug redirects to `/maintenance` LiveView, on_mount hooks redirect LiveView routes
- **LiveView maintenance page** -- supports countdown timers, PubSub auto-redirect, admin preview, extensible with custom components (live chat, status updates, etc.)
- **Scheduled maintenance** -- set a start/end UTC window; `active?/0` checks manual toggle OR scheduled window, no Oban job needed
- **Role-based bypass** -- admins and owners access the site normally during maintenance
- **PubSub real-time updates** -- when maintenance ends, all connected users auto-redirect back (no manual refresh)
- **Retry-After header** -- HTTP header sent with redirect when a scheduled end time is known
- **Customizable content** -- header and subtext configurable via admin settings with live preview
- **Activity logging** -- all admin actions (toggle, content changes, schedule) are logged

## Module Structure

```
lib/modules/maintenance/
├── README.md                          # This documentation
├── maintenance.ex                     # Context module (active?, schedule, PubSub)
├── settings.ex                        # Admin settings LiveView
└── web/
    ├── plugs/
    │   └── maintenance_mode.ex        # HTTP plug — redirects non-admins to /maintenance
    ├── components/
    │   └── maintenance_page.ex        # Reusable card component
    └── maintenance_page_live.ex       # Public /maintenance LiveView page
```

## How It Works

### Request Flow

1. **HTTP request** hits `PhoenixKitWeb.Plugs.Integration` (in browser pipeline)
2. `MaintenanceMode` plug checks `Maintenance.active?()`
3. If active:
   - Static assets and auth routes pass through (login, reset-password, etc.)
   - Admin/owner users pass through (checked via session token + Scope)
   - The `/maintenance` path itself passes through (prevents redirect loop)
   - Everyone else gets a **302 redirect to `/maintenance`** with optional `Retry-After` header
4. **LiveView routes** are also protected via `check_maintenance_mode/1` in `auth.ex` on_mount hooks

### Maintenance Page LiveView

The `/maintenance` route renders a full-screen LiveView (`PhoenixKitWeb.Live.Modules.Maintenance.Page`) that:
- Shows the customizable header + subtext with a construction emoji
- Displays a live countdown timer if a scheduled end time is set (JS hook)
- Subscribes to PubSub and auto-redirects users to `/` when maintenance ends
- Shows an admin preview banner with link to settings if an admin visits directly
- Redirects to `/` if maintenance is not active (prevents stale bookmarks)

### active?/0

The main check used by the plug and on_mount:

```elixir
def active? do
  manually_enabled?() or within_scheduled_window?()
end
```

Returns true when either:
- The manual toggle (`maintenance_enabled` setting) is on, OR
- The current UTC time falls between `maintenance_scheduled_start` and `maintenance_scheduled_end`

## Context API

### `PhoenixKit.Modules.Maintenance`

**Status checks:**

| Function | Returns | Description |
|----------|---------|-------------|
| `active?/0` | `boolean` | Main check: `true` if maintenance is currently active (manual toggle OR schedule), auto-disables if past scheduled end |
| `manually_enabled?/0` | `boolean` | Just the manual toggle state |
| `past_scheduled_start?/0` | `boolean` | `true` if now >= scheduled start |
| `past_scheduled_end?/0` | `boolean` | `true` if now >= scheduled end |
| `within_scheduled_window?/0` | `boolean` | `true` if inside an active scheduled window |
| `seconds_until_end/0` | `integer \| nil` | Seconds until maintenance ends (for Retry-After + countdown) |

**Mutations:**

| Function | Returns | Description |
|----------|---------|-------------|
| `enable_system/0` | `{:ok, _} \| {:error, _}` | Turn on manual toggle, clears expired schedule |
| `disable_system/0` | `{:ok, _} \| {:error, _}` | Turn off manual toggle, clears scheduled start |
| `update_schedule/2` | `:ok \| {:error, atom}` | Set scheduled start/end DateTimes (either may be `nil`). Validates before saving |
| `clear_schedule/0` | `:ok` | Remove scheduled window |
| `cleanup_expired_schedule/0` | `boolean` | Clean up stale state if end time has passed. Returns `true` if cleanup was performed |
| `validate_schedule/2` | `:ok \| {:error, atom}` | Validate a proposed schedule without saving. Error atoms: `:empty`, `:start_in_past`, `:end_in_past`, `:end_before_start`, `:too_far_future` |

**Content:**

| Function | Returns | Description |
|----------|---------|-------------|
| `get_header/0` | `String.t()` | Maintenance page header text |
| `get_subtext/0` | `String.t()` | Maintenance page subtext |
| `update_header/1` | `{:ok, _} \| {:error, _}` | Update header text |
| `update_subtext/1` | `{:ok, _} \| {:error, _}` | Update subtext |
| `get_scheduled_start/0` | `DateTime.t() \| nil` | Scheduled start time in UTC |
| `get_scheduled_end/0` | `DateTime.t() \| nil` | Scheduled end time in UTC |
| `get_config/0` | `map` | Full configuration map with all settings + computed status |

**Module lifecycle:**

| Function | Returns | Description |
|----------|---------|-------------|
| `module_enabled?/0` | `boolean` | Is the module's settings page enabled? |
| `enabled?/0` | `boolean` | Same as `module_enabled?/0` (PhoenixKit.Module callback) |
| `enable_module/0` | `{:ok, _} \| {:error, _}` | Enable the settings page |
| `disable_module/0` | `{:ok, _} \| {:error, _}` | Disable the settings page. Also disables maintenance and clears schedule to prevent lockouts |

**PubSub:**

| Function | Returns | Description |
|----------|---------|-------------|
| `pubsub_topic/0` | `String.t()` | Returns `"phoenix_kit:maintenance"` |
| `subscribe/0` | `:ok` | Subscribe calling process to status change events |
| `broadcast_status_change/0` | `:ok` | Broadcast current status to subscribers. Message: `{:maintenance_status_changed, %{active: boolean}}` |

### PubSub

Topic: `"phoenix_kit:maintenance"`
Message: `{:maintenance_status_changed, %{active: boolean}}`

Subscribe with `Maintenance.subscribe/0`, uses `PhoenixKit.PubSub.Manager`.

## Settings Storage

All settings stored in `phoenix_kit_settings` table:

| Key | Type | Default |
|-----|------|---------|
| `maintenance_module_enabled` | boolean | `false` |
| `maintenance_enabled` | boolean | `false` |
| `maintenance_header` | string | `"Maintenance Mode"` |
| `maintenance_subtext` | string | `"We'll be back soon..."` |
| `maintenance_scheduled_start` | ISO 8601 string | `nil` |
| `maintenance_scheduled_end` | ISO 8601 string | `nil` |

## Admin Settings UI

Located at `/admin/settings/maintenance`:

- **Manual toggle** -- immediately enable/disable
- **Scheduled maintenance** -- UTC datetime pickers for start/end with current server time display
- **Content editor** -- header + subtext with live preview
- **Status banner** -- shows why maintenance is active (manual, scheduled, or both)
- **Preview link** -- navigate to `/maintenance` to see the user-facing page

## Component

`PhoenixKitWeb.Components.Core.MaintenancePage.maintenance_card/1` renders the maintenance card (emoji + header + subtext). Used by the LiveView. Also available as `maintenance_page/1` for backwards compatibility.

## Troubleshooting

### Users still see normal content after enabling
- Existing LiveView WebSocket connections are not affected until next page navigation
- Verify `Maintenance.active?()` returns true in IEx

### Admins see maintenance page
- Verify user has Admin or Owner role
- Check `Scope.admin?(scope)` or `Scope.owner?(scope)` returns true

### Scheduled maintenance not activating
- Times are stored and compared in UTC
- Check `Maintenance.get_scheduled_start()` and `Maintenance.get_scheduled_end()` return expected DateTimes
- Verify current server time with `DateTime.utc_now()`
