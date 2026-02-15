# PhoenixKit Admin Navigation System

Registry-driven admin sidebar navigation that replaces hardcoded HEEX with configurable, permission-gated Tab structs. Shares the same underlying registry and rendering infrastructure as the [User Dashboard Tab System](README.md).

## How It Works

All admin navigation items are registered as Tab structs in the Dashboard Registry with `level: :admin`. The admin sidebar component reads these tabs, filters by permission and module-enabled status, and renders them using the same `TabItem` component as the user dashboard.

### Three-Layer Visibility

Every admin tab passes through three filters before rendering:

1. **Module Enabled** — Is the feature module active? (e.g., is Billing enabled?)
2. **Permission Granted** — Does the user's role have access? (checked via `Scope.has_module_access?/2`)
3. **Custom Visibility** — Optional `visible` function for special logic

```
Tab registered → module_enabled? → permission_granted? → visible? → rendered
```

## Default Admin Tabs

PhoenixKit registers ~50 admin tabs automatically on startup, organized into three groups:

| Group | Tabs |
|-------|------|
| **Main** | Dashboard, Users (+ 6 subtabs), Media |
| **Modules** | Emails, Billing, Shop, Entities, AI, Sync, DB, Posts, Comments, Publishing, Jobs, Tickets, Modules |
| **System** | Settings (+ ~20 subtabs covering all module settings) |

Each tab has a `permission` field matching one of the 25 permission keys (e.g., `"billing"`, `"users"`, `"settings"`). Tabs for disabled modules are automatically hidden.

## Customizing Admin Tabs

### Adding Tabs via Config

Add custom tabs to the admin sidebar:

```elixir
# config/config.exs
config :phoenix_kit, :admin_dashboard_tabs, [
  %{
    id: :admin_analytics,
    label: "Analytics",
    icon: "hero-chart-bar",
    path: "/admin/analytics",
    permission: "dashboard",
    priority: 350,
    group: :admin_main
  }
]
```

### Adding Tabs with Seamless Navigation

By default, custom tabs are sidebar links only — the parent app must define the actual LiveView routes. If those routes are in a different `live_session`, navigation causes a full page reload.

To avoid this, add the `live_view` field. PhoenixKit will auto-generate the route inside its shared admin `live_session`, giving you seamless LiveView navigation:

```elixir
config :phoenix_kit, :admin_dashboard_tabs, [
  %{
    id: :admin_analytics,
    label: "Analytics",
    icon: "hero-chart-bar",
    path: "/admin/analytics",
    permission: "dashboard",
    priority: 350,
    group: :admin_main,
    live_view: {MyAppWeb.AnalyticsLive, :index}  # Auto-generates route
  }
]
```

With `live_view` set, PhoenixKit:
- Generates `live "/admin/analytics", MyAppWeb.AnalyticsLive, :index` inside the admin `live_session`
- Applies the `:phoenix_kit_ensure_admin` on_mount hook automatically
- Navigation from other admin pages uses LiveView `navigate` (no full page reload)

**Without `live_view`**: Parent app defines routes in its own router (may be a different `live_session`).

### Tab Fields Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `id` | atom | required | Unique identifier (prefix with `admin_` by convention) |
| `label` | string | required | Display text in sidebar |
| `icon` | string | nil | Heroicon name (e.g., `"hero-chart-bar"`) |
| `path` | string | required | URL path without prefix (e.g., `"/admin/analytics"`) |
| `priority` | integer | 500 | Sort order (lower = higher in sidebar) |
| `level` | atom | `:admin` | Set automatically by config loader |
| `permission` | string | nil | Permission key for access control (e.g., `"billing"`) |
| `group` | atom | nil | Group ID: `:admin_main`, `:admin_modules`, or `:admin_system` |
| `parent` | atom | nil | Parent tab ID for subtab relationships |
| `match` | atom | `:prefix` | Path matching: `:exact`, `:prefix`, or `{:regex, ~r/...}` |
| `visible` | function | nil | `(scope -> boolean)` for custom visibility logic |
| `live_view` | tuple | nil | `{Module, :action}` to auto-generate a route |
| `subtab_display` | atom | `:when_active` | `:when_active` or `:always` |
| `highlight_with_subtabs` | boolean | false | Highlight parent when subtab is active |
| `dynamic_children` | function | nil | `(scope -> [Tab.t()])` for runtime subtabs |

### Modifying Default Tabs

Update or remove default tabs at runtime:

```elixir
# Change a default tab's label or icon
PhoenixKit.Dashboard.update_tab(:admin_dashboard, %{label: "Home", icon: "hero-home"})

# Remove a default tab
PhoenixKit.Dashboard.unregister_tab(:admin_jobs)
```

### Registering Tabs at Runtime

```elixir
# Register admin tabs programmatically (level: :admin is set automatically)
PhoenixKit.Dashboard.register_admin_tabs(:my_app, [
  %{
    id: :admin_analytics,
    label: "Analytics",
    icon: "hero-chart-bar",
    path: "/admin/analytics",
    permission: "dashboard",
    priority: 350,
    group: :admin_main
  }
])

# Unregister all tabs for a namespace
PhoenixKit.Dashboard.unregister_tabs(:my_app)
```

## Subtabs

Admin tabs support parent/child relationships, working the same as [user dashboard subtabs](README.md#subtabs):

```elixir
config :phoenix_kit, :admin_dashboard_tabs, [
  # Parent
  %{
    id: :admin_reports,
    label: "Reports",
    icon: "hero-document-chart-bar",
    path: "/admin/reports",
    permission: "dashboard",
    priority: 360,
    group: :admin_main,
    subtab_display: :when_active,
    live_view: {MyAppWeb.ReportsLive, :index}
  },
  # Subtabs
  %{
    id: :admin_reports_sales,
    label: "Sales",
    path: "/admin/reports/sales",
    parent: :admin_reports,
    priority: 361,
    live_view: {MyAppWeb.ReportsSalesLive, :index}
  },
  %{
    id: :admin_reports_users,
    label: "Users",
    path: "/admin/reports/users",
    parent: :admin_reports,
    priority: 362,
    live_view: {MyAppWeb.ReportsUsersLive, :index}
  }
]
```

## Dynamic Children

Some admin tabs generate subtabs at render time based on data:

- **Entities** — A subtab for each published entity type
- **Publishing** — A subtab for each publishing group from settings

These use the `dynamic_children` field — a function `(scope -> [Tab.t()])` called when the sidebar renders. Dynamic children are always rendered under their parent tab and inherit its permission.

### Custom Dynamic Children

```elixir
PhoenixKit.Dashboard.register_admin_tabs(:my_app, [
  %{
    id: :admin_workspaces,
    label: "Workspaces",
    icon: "hero-squares-2x2",
    path: "/admin/workspaces",
    permission: "dashboard",
    priority: 400,
    group: :admin_main,
    dynamic_children: fn _scope ->
      MyApp.Workspaces.list_active()
      |> Enum.with_index()
      |> Enum.map(fn {ws, idx} ->
        %PhoenixKit.Dashboard.Tab{
          id: :"admin_workspace_#{ws.slug}",
          label: ws.name,
          icon: "hero-square-2-stack",
          path: "/admin/workspaces/#{ws.slug}",
          priority: 401 + idx,
          level: :admin,
          permission: "dashboard",
          match: :prefix,
          parent: :admin_workspaces
        }
      end)
    end
  }
])
```

**Performance note**: Dynamic children functions run on every sidebar render (each navigation). Keep them fast — use cached data, avoid expensive queries.

## Permission System

Admin tabs integrate with PhoenixKit's module-level permissions (`PhoenixKit.Users.Permissions`):

- **Owner** — Always has full access (hardcoded, no DB rows needed)
- **Admin** — Gets all 25 permissions by default
- **Custom roles** — Start with no permissions; grant via matrix UI or API

### Permission Keys

The `permission` field on a tab must match one of the 25 permission keys:

**Core (always enabled):** `dashboard`, `users`, `media`, `settings`, `modules`

**Feature modules (enabled/disabled):** `billing`, `shop`, `emails`, `entities`, `tickets`, `posts`, `comments`, `ai`, `sync`, `publishing`, `referrals`, `sitemap`, `seo`, `maintenance`, `storage`, `languages`, `connections`, `legal`, `db`, `jobs`

When a tab's `permission` points to a feature module:
- If the module is **disabled**, the tab is hidden for everyone
- If the module is **enabled**, the tab is shown only to users whose role has that permission

## Navigation Architecture

### LiveView Sessions

All PhoenixKit admin routes share a single `live_session`:

```elixir
live_session :phoenix_kit_admin,
  on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
    # All admin routes — PhoenixKit core + modules + custom (with live_view)
end
```

This means:
- Navigating between admin pages uses LiveView `navigate` (WebSocket stays alive)
- Each page does a lightweight MOUNT (expected behavior for different LiveView modules)
- No full page reloads within the admin panel

**Important**: Custom admin routes defined by the parent app WITHOUT `live_view` may be in a different `live_session`, which would cause a full page reload when navigating to them. Use `live_view` in your tab config to avoid this.

### Tab Rendering Flow

```
1. Registry.get_admin_tabs(scope: scope)
   ├── Filter by level (:admin + :all)
   ├── Filter by module enabled (deduplicated per permission key)
   ├── Filter by permission (in-memory MapSet check)
   └── Filter by visibility (custom functions)

2. AdminSidebar component
   ├── Expand dynamic children (entities, publishing)
   ├── Add active state based on current_path
   ├── Group tabs by group field
   └── Render via TabItem component (shared with user dashboard)
```

**Important**: Dynamic children are expanded *before* active state is applied, so that dynamically-generated subtabs (e.g., individual entity types) correctly highlight when navigated to.

## API Reference

```elixir
# Admin-specific
PhoenixKit.Dashboard.get_admin_tabs(opts)           # Get filtered admin tabs
PhoenixKit.Dashboard.get_user_tabs(opts)            # Get filtered user tabs
PhoenixKit.Dashboard.register_admin_tabs(ns, tabs)  # Register with level: :admin
PhoenixKit.Dashboard.update_tab(tab_id, attrs)      # Modify existing tab
PhoenixKit.Dashboard.load_admin_defaults()           # Reload default admin tabs

# All standard Dashboard APIs also work (see README.md)
PhoenixKit.Dashboard.unregister_tab(tab_id)
PhoenixKit.Dashboard.get_tab(tab_id)
# etc.
```

## File Structure

```
lib/phoenix_kit/dashboard/
├── admin_tabs.ex     # Default admin tab definitions (~50 tabs)
├── dashboard.ex      # Public API facade
├── registry.ex       # Tab registry GenServer (shared user + admin)
├── tab.ex            # Tab struct with level/permission/dynamic_children fields
├── ADMIN_README.md   # This file
└── README.md         # User dashboard documentation

lib/phoenix_kit_web/components/dashboard/
├── admin_sidebar.ex  # Admin sidebar component
├── sidebar.ex        # User dashboard sidebar component
├── tab_item.ex       # Shared tab rendering component
└── ...
```

## Creating Custom Admin Pages

When using the `live_view` field, your LiveView runs inside PhoenixKit's admin `live_session` and must use the admin layout. Here's the complete pattern:

### 1. Create the LiveView

```elixir
# lib/my_app_web/phoenix_kit_live/admin_analytics_live.ex
defmodule MyAppWeb.PhoenixKitLive.AdminAnalyticsLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Analytics")}
  end

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      page_title={@page_title}
      current_path={@url_path}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      current_locale={assigns[:current_locale]}
    >
      <div class="container flex-col mx-auto px-4 py-6">
        <h1 class="text-2xl font-bold mb-6">Analytics Dashboard</h1>
        <%!-- Your content here --%>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
```

### 2. Register the Tab

```elixir
# config/config.exs
config :phoenix_kit, :admin_dashboard_tabs, [
  %{
    id: :admin_analytics,
    label: "Analytics",
    icon: "hero-chart-bar",
    path: "/admin/analytics",
    permission: "dashboard",
    priority: 150,
    group: :admin_main,
    live_view: {MyAppWeb.PhoenixKitLive.AdminAnalyticsLive, :index}
  }
]
```

### Key Points

- **Use `@url_path` not `@current_path`** — The `url_path` assign is set by PhoenixKit's `on_mount` hooks. There is no `current_path` assign.
- **Use `LayoutWrapper.app_layout`** — This is the admin layout with the admin sidebar. Do NOT use `Layouts.dashboard` (that's the user dashboard layout).
- **Don't pass `project_title`** — The `app_layout` component has a built-in default; passing it from the LiveView will crash since it's not in the assigns.
- **Use `assigns[:current_locale]`** — Use bracket access for optional assigns that may not be set.
- **Place LiveViews under `phoenix_kit_live/`** — Convention for LiveViews that run inside PhoenixKit's admin `live_session`.

### Available Assigns

These assigns are automatically set by PhoenixKit's `on_mount` hooks in the admin `live_session`:

| Assign | Type | Description |
|--------|------|-------------|
| `@url_path` | string | Current URL path (use for `current_path` in layout) |
| `@phoenix_kit_current_scope` | Scope.t() | Auth scope with user, roles, and permissions |
| `@phoenix_kit_current_user` | User.t() | Current authenticated user |
| `@current_locale` | string | Current locale code (may be nil) |
| `@flash` | map | Flash messages |
| `@live_action` | atom | The action from the route (e.g., `:index`) |
| `@show_maintenance` | boolean | Whether maintenance mode banner is shown |

## Legacy Config Compatibility

The legacy `AdminDashboardCategories` config format is still supported but deprecated:

```elixir
# Legacy format (deprecated, will log warning)
config :phoenix_kit, AdminDashboardCategories, [
  %{title: "Custom", icon: "hero-star", tabs: [
    %{title: "Analytics", url: "/admin/analytics", icon: "hero-chart-bar"}
  ]}
]

# New format (recommended)
config :phoenix_kit, :admin_dashboard_tabs, [
  %{id: :admin_analytics, label: "Analytics", icon: "hero-chart-bar",
    path: "/admin/analytics", permission: "dashboard", group: :admin_main}
]
```

Legacy categories are automatically converted to admin Tab structs at startup. A deprecation warning is logged when legacy config is detected.
