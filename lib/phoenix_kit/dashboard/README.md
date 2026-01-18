# PhoenixKit User Dashboard Tab System

A comprehensive, extensible navigation system for the PhoenixKit user dashboard that allows parent applications to add custom tabs with rich features.

## Features

- **Dynamic Tabs**: Configure tabs via config or register at runtime
- **Subtabs**: Hierarchical parent/child tab relationships with conditional visibility
- **Live Badges**: Real-time badge updates via PubSub
- **Badge Types**: Count, dot, status, "new", and custom text badges
- **Grouping**: Organize tabs into sections with headers and dividers
- **Conditional Visibility**: Show/hide tabs based on roles or custom logic
- **Attention Animations**: Pulse, bounce, shake, glow effects
- **Presence Tracking**: Show user counts per tab
- **Path Matching**: Flexible active state detection (exact, prefix, regex, custom)
- **Mobile Support**: Responsive bottom navigation and FAB menu

## Quick Start

### Using the Mix Generator (Recommended)

The easiest way to add tabs is using the Mix generator:

```bash
# Add a History tab to Farm Management category
mix phoenix_kit.gen.dashboard_tab "Farm Management" "History" \
  --url="/dashboard/history" \
  --icon="hero-chart-bar" \
  --category-icon="hero-cube"

# Add a Settings tab to Account category
mix phoenix_kit.gen.dashboard_tab "Account" "Settings" \
  --url="/dashboard/settings" \
  --icon="hero-cog-6-tooth" \
  --description="Manage your account settings"
```

This will automatically add the tab configuration to your `config/config.exs`.

### Configure Categories in config.exs

For category-based organization (similar to admin dashboard):

```elixir
config :phoenix_kit, :user_dashboard_categories, [
  %{
    title: "Farm Management",
    icon: "hero-cube",
    tabs: [
      %{
        title: "Printers",
        url: "/dashboard/printers",
        icon: "hero-printer",
        description: "Manage your 3D printers"
      },
      %{
        title: "History",
        url: "/dashboard/history",
        icon: "hero-chart-bar"
      }
    ]
  },
  %{
    title: "Account",
    icon: "hero-user",
    tabs: [
      %{title: "Settings", url: "/dashboard/settings", icon: "hero-cog-6-tooth"}
    ]
  }
]
```

### Configure Flat Tabs in config.exs

For simpler flat tab configuration:

```elixir
config :phoenix_kit, :user_dashboard_tabs, [
  %{
    id: :orders,
    label: "My Orders",
    icon: "hero-shopping-bag",
    path: "/dashboard/orders",
    priority: 100
  },
  %{
    id: :notifications,
    label: "Notifications",
    icon: "hero-bell",
    path: "/dashboard/notifications",
    priority: 200,
    badge: %{type: :count, value: 0, color: :error}
  }
]
```

### Register Tabs at Runtime (Optional)

```elixir
# In your application startup or a module
PhoenixKit.Dashboard.register_tabs(:my_app, [
  %{
    id: :printers,
    label: "Printers",
    icon: "hero-cube",
    path: "/dashboard/printers",
    priority: 150,
    badge: %{
      type: :count,
      subscribe: {"farm:stats", fn msg -> msg.printing_count end}
    }
  }
])
```

### Update Badges Live

```elixir
# From anywhere in your app
PhoenixKit.Dashboard.update_badge(:notifications, 5)
PhoenixKit.Dashboard.update_badge(:printers, count: 3, color: :warning)

# Increment/decrement
PhoenixKit.Dashboard.increment_badge(:notifications)
PhoenixKit.Dashboard.decrement_badge(:notifications)
```

### Trigger Attention

```elixir
# Make a tab pulse to draw attention
PhoenixKit.Dashboard.set_attention(:alerts, :pulse)

# Clear attention
PhoenixKit.Dashboard.clear_attention(:alerts)
```

## Tab Configuration

### Basic Tab

```elixir
%{
  id: :orders,           # Required: Unique atom identifier
  label: "Orders",       # Required: Display text
  path: "/dashboard/orders",  # Required: URL path
  icon: "hero-shopping-bag",  # Optional: Heroicon name
  priority: 100          # Optional: Sort order (default: 500)
}
```

### Full Options

```elixir
%{
  id: :printers,
  label: "Printers",
  icon: "hero-cube",
  path: "/dashboard/printers",
  priority: 150,
  group: :farm,          # Group ID for organization
  match: :prefix,        # :exact, :prefix, {:regex, ~r/.../}, or function
  visible: fn scope -> scope.user.has_farm? end,  # Conditional visibility
  badge: %{
    type: :count,        # :count, :dot, :status, :new, :text
    value: 0,
    color: :primary,     # :primary, :secondary, :accent, :info, :success, :warning, :error
    max: 99,             # Shows "99+" for higher values
    pulse: true,         # Enable pulse animation
    subscribe: {"topic", :key}  # PubSub subscription for live updates
  },
  tooltip: "View all printers",
  external: false,       # External link (opens in new tab)
  new_tab: false,        # Open in new browser tab
  attention: nil         # :pulse, :bounce, :shake, :glow
}
```

## Tab Groups

Organize tabs into labeled sections:

```elixir
config :phoenix_kit, :user_dashboard_tab_groups, [
  %{id: :main, label: nil, priority: 100},
  %{id: :farm, label: "Farm Management", priority: 200, icon: "hero-cube", collapsible: true},
  %{id: :account, label: "Account", priority: 900}
]
```

Then assign tabs to groups:

```elixir
%{id: :printers, label: "Printers", path: "/dashboard/printers", group: :farm}
```

## Subtabs

Create hierarchical navigation with parent/child relationships:

### Basic Subtabs

```elixir
config :phoenix_kit, :user_dashboard_tabs, [
  # Parent tab
  %{
    id: :orders,
    label: "Orders",
    icon: "hero-shopping-bag",
    path: "/dashboard/orders",
    priority: 100,
    subtab_display: :when_active  # Show subtabs only when parent is active
  },
  # Subtabs
  %{
    id: :pending_orders,
    label: "Pending",
    path: "/dashboard/orders/pending",
    priority: 110,
    parent: :orders  # Links this tab to the parent
  },
  %{
    id: :completed_orders,
    label: "Completed",
    path: "/dashboard/orders/completed",
    priority: 120,
    parent: :orders
  },
  %{
    id: :cancelled_orders,
    label: "Cancelled",
    path: "/dashboard/orders/cancelled",
    priority: 130,
    parent: :orders
  }
]
```

### Subtab Display Options

- `:when_active` (default) - Subtabs only appear when the parent tab is active
- `:always` - Subtabs are always visible

```elixir
# Always show subtabs
%{
  id: :settings,
  label: "Settings",
  path: "/dashboard/settings",
  subtab_display: :always
}
```

### Redirect to First Subtab

When `redirect_to_first_subtab: true` is set on a parent tab, clicking the parent tab navigates to the first subtab instead of the parent's own path. This is useful when the parent tab serves as a container/category and the first subtab is the default landing page.

```elixir
%{
  id: :orders,
  label: "Orders",
  path: "/dashboard/orders",           # This path won't be used for navigation
  redirect_to_first_subtab: true,      # Clicking "Orders" goes to first subtab
  subtab_display: :when_active
}

# First subtab (priority 110) becomes the landing page
%{id: :pending, label: "Pending", path: "/dashboard/orders/pending", parent: :orders, priority: 110}
%{id: :completed, label: "Completed", path: "/dashboard/orders/completed", parent: :orders, priority: 120}
```

With this config, clicking "Orders" navigates to `/dashboard/orders/pending`.

### Parent Tab Highlighting

By default, when a subtab is active, only the subtab is highlighted (not the parent). This behavior can be changed with `highlight_with_subtabs`:

```elixir
%{
  id: :orders,
  label: "Orders",
  path: "/dashboard/orders",
  highlight_with_subtabs: true  # Also highlight parent when subtab is active (default: false)
}
```

- `highlight_with_subtabs: false` (default) - Only the active subtab is highlighted
- `highlight_with_subtabs: true` - Both parent and active subtab are highlighted

### Subtab Customization

Subtabs support customizable styling for indent, icon size, text size, and entry animations.

#### Style Options

Set these on the **parent tab** to apply to all its subtabs, or on **individual subtabs** to override:

```elixir
%{
  id: :orders,
  label: "Orders",
  path: "/dashboard/orders",
  subtab_display: :when_active,
  # Style options for subtabs (applied to children)
  subtab_indent: "pl-12",        # Tailwind padding-left class (default: "pl-9")
  subtab_icon_size: "w-3 h-3",   # Icon size classes (default: "w-4 h-4")
  subtab_text_size: "text-xs",   # Text size class (default: "text-sm")
  subtab_animation: :slide       # Animation: :none, :slide, :fade, :collapse
}
```

#### Per-Subtab Overrides

Individual subtabs can override the parent's styling:

```elixir
# Parent with default styling
%{id: :settings, label: "Settings", path: "/dashboard/settings", subtab_display: :always},

# Subtab with custom styling (overrides parent)
%{
  id: :advanced_settings,
  label: "Advanced",
  path: "/dashboard/settings/advanced",
  parent: :settings,
  subtab_indent: "pl-14",
  subtab_text_size: "text-xs font-medium"
}
```

#### Global Defaults

Set global subtab styling defaults in your config:

```elixir
config :phoenix_kit,
  dashboard_subtab_style: [
    indent: "pl-9",           # Default indent
    icon_size: "w-4 h-4",     # Default icon size
    text_size: "text-sm",     # Default text size
    animation: :none          # Default animation
  ]
```

#### Style Cascade

Styles are resolved in this order (first non-nil wins):
1. Subtab's own `subtab_*` fields
2. Parent tab's `subtab_*` fields
3. Global `dashboard_subtab_style` config
4. Hardcoded defaults

#### Animation Options

- `:none` - No animation (default)
- `:slide` - Slides in from the left
- `:fade` - Fades in
- `:collapse` - Expands from collapsed state

Animations play when subtabs become visible (when navigating to parent or subtab).

### Dynamic Subtab Registration

```elixir
# Register parent and subtabs at runtime
PhoenixKit.Dashboard.register_tabs(:my_app, [
  %{id: :printers, label: "Printers", path: "/dashboard/printers", subtab_display: :when_active},
  %{id: :active_printers, label: "Active", path: "/dashboard/printers/active", parent: :printers},
  %{id: :idle_printers, label: "Idle", path: "/dashboard/printers/idle", parent: :printers}
])
```

### Subtab API

```elixir
# Get all subtabs for a parent
PhoenixKit.Dashboard.get_subtabs(:orders)
# => [%Tab{id: :pending_orders, ...}, %Tab{id: :completed_orders, ...}]

# Get only top-level tabs
PhoenixKit.Dashboard.get_top_level_tabs()

# Check if a tab has subtabs
PhoenixKit.Dashboard.has_subtabs?(:orders)
# => true

# Check if a tab is a subtab
PhoenixKit.Dashboard.subtab?(tab)
# => true

# Check if subtabs should be shown
PhoenixKit.Dashboard.show_subtabs?(parent_tab, is_active)
```

## Badge Types

### Count Badge

```elixir
%{type: :count, value: 5}
%{type: :count, value: 150, max: 99}  # Shows "99+"
%{type: :count, value: 3, color: :error, pulse: true}
```

### Dot Badge

```elixir
%{type: :dot, color: :success}  # Green dot
%{type: :dot, color: :warning, pulse: true}  # Pulsing yellow dot
```

### Status Badge

```elixir
%{type: :status, value: :online, color: :success}
%{type: :status, value: :busy, color: :warning}
```

### New Badge

```elixir
%{type: :new}
%{type: :new, color: :accent}
```

### Text Badge

```elixir
%{type: :text, value: "Beta"}
%{type: :text, value: "Pro", color: :accent}
```

## Live Badge Updates via PubSub

Badges can subscribe to PubSub topics for automatic updates:

```elixir
# Using a key from the message
badge: %{
  type: :count,
  subscribe: {"user:#{user_id}:notifications", :unread_count}
}

# Using a function to extract the value
badge: %{
  type: :count,
  subscribe: {"farm:stats", fn msg -> msg.printing_count end}
}
```

When you broadcast to the topic, the badge updates automatically:

```elixir
Phoenix.PubSub.broadcast(MyApp.PubSub, "farm:stats", %{printing_count: 3})
```

## Conditional Visibility

### Role-Based

```elixir
%{
  id: :admin_settings,
  label: "Admin",
  path: "/dashboard/admin",
  visible: fn scope ->
    PhoenixKit.Users.Roles.has_role?(scope.user, "admin")
  end
}
```

### Feature Flag

```elixir
%{
  id: :beta_feature,
  label: "Beta Feature",
  path: "/dashboard/beta",
  visible: fn scope ->
    scope.user.features["beta_enabled"] == true
  end
}
```

## Presence Tracking

Track how many users are viewing each tab:

```elixir
# In your LiveView
def mount(_params, _session, socket) do
  if connected?(socket) do
    PhoenixKit.Dashboard.track_presence(socket, :orders)
  end
  {:ok, socket}
end
```

Configure presence options:

```elixir
config :phoenix_kit, :dashboard_presence,
  enabled: true,
  show_user_count: true,
  show_user_names: false,
  track_anonymous: false
```

## Attention Animations

Draw user attention to important tabs:

```elixir
# Available animations
PhoenixKit.Dashboard.set_attention(:alerts, :pulse)   # Gentle pulsing
PhoenixKit.Dashboard.set_attention(:errors, :bounce)  # Bouncing motion
PhoenixKit.Dashboard.set_attention(:urgent, :shake)   # Shaking motion
PhoenixKit.Dashboard.set_attention(:new, :glow)       # Glowing effect

# Clear attention
PhoenixKit.Dashboard.clear_attention(:alerts)
```

## LiveView Integration

For real-time tab updates in your LiveViews:

```elixir
defmodule MyAppWeb.DashboardLive do
  use MyAppWeb, :live_view
  use PhoenixKitWeb.Components.Dashboard.LiveTabs

  def mount(_params, _session, socket) do
    socket =
      socket
      |> init_dashboard_tabs()
      |> track_tab_presence(:my_tab)

    {:ok, socket}
  end
end
```

Or manually:

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(PhoenixKit.PubSub, PhoenixKit.Dashboard.pubsub_topic())
  end

  {:ok, assign(socket, :dashboard_tabs, PhoenixKit.Dashboard.get_tabs())}
end

def handle_info({:tab_updated, _tab}, socket) do
  {:noreply, assign(socket, :dashboard_tabs, PhoenixKit.Dashboard.get_tabs())}
end

def handle_info(:tabs_refreshed, socket) do
  {:noreply, assign(socket, :dashboard_tabs, PhoenixKit.Dashboard.get_tabs())}
end
```

## API Reference

### PhoenixKit.Dashboard

```elixir
# Tab Registration
register_tabs(namespace, tabs)      # Register tabs for a namespace
unregister_tabs(namespace)          # Remove all tabs for a namespace
unregister_tab(tab_id)              # Remove a specific tab

# Tab Retrieval
get_tabs(opts \\ [])                # Get all tabs
get_tab(tab_id)                     # Get a specific tab
get_tabs_with_active(path, opts)    # Get tabs with active state

# Groups
register_groups(groups)             # Register tab groups
get_groups()                        # Get all groups

# Subtabs
get_subtabs(parent_id, opts)        # Get subtabs for a parent
get_top_level_tabs(opts)            # Get only top-level tabs
has_subtabs?(tab_id)                # Check if tab has subtabs
subtab?(tab)                        # Check if tab is a subtab
show_subtabs?(tab, active)          # Check if subtabs should be shown

# Badges
update_badge(tab_id, value)         # Update a tab's badge
increment_badge(tab_id, amount)     # Increment count badge
decrement_badge(tab_id, amount)     # Decrement count badge
clear_badge(tab_id)                 # Clear a tab's badge

# Attention
set_attention(tab_id, animation)    # Set attention animation
clear_attention(tab_id)             # Clear attention animation

# Presence
track_presence(socket, tab_id)      # Track user on a tab
get_viewer_count(tab_id)            # Get viewer count
get_all_viewer_counts()             # Get all viewer counts

# PubSub
subscribe()                         # Subscribe to tab updates
pubsub_topic()                      # Get the PubSub topic
```

### Helper Functions

```elixir
# Tab creation
PhoenixKit.Dashboard.new_tab(attrs)       # Create a Tab struct
PhoenixKit.Dashboard.divider(opts)        # Create a divider
PhoenixKit.Dashboard.group_header(opts)   # Create a group header

# Badge creation
PhoenixKit.Dashboard.count_badge(value, opts)
PhoenixKit.Dashboard.dot_badge(opts)
PhoenixKit.Dashboard.status_badge(value, opts)
PhoenixKit.Dashboard.live_badge(topic, extractor, opts)

# Utilities
PhoenixKit.Dashboard.matches_path?(tab, path)
PhoenixKit.Dashboard.visible?(tab, scope)
```

## File Structure

```
lib/phoenix_kit/dashboard/
├── dashboard.ex      # Main public API
├── tab.ex            # Tab struct and logic
├── badge.ex          # Badge struct and logic
├── registry.ex       # Tab registry GenServer
├── presence.ex       # Presence tracking
└── README.md         # This file

lib/phoenix_kit_web/components/dashboard/
├── sidebar.ex        # Main sidebar component
├── tab_item.ex       # Individual tab component
├── badge.ex          # Badge rendering component
└── live_tabs.ex      # LiveView integration helpers
```

## Default Tabs

PhoenixKit provides these default tabs:

1. **Dashboard** (id: `:dashboard_home`, priority: 100)
   - Path: `/dashboard`
   - Always shown

2. **Settings** (id: `:dashboard_settings`, priority: 900)
   - Path: `/dashboard/settings`
   - Always shown

3. **My Tickets** (id: `:dashboard_tickets`, priority: 800)
   - Path: `/dashboard/tickets`
   - Only shown when Tickets module is enabled

Your custom tabs will be merged with these defaults based on priority.

## Examples

### FarmKeeper Example

```elixir
# config/config.exs
config :phoenix_kit, :user_dashboard_tabs, [
  %{
    id: :printers,
    label: "Printers",
    icon: "hero-cube",
    path: "/dashboard",
    priority: 100,
    group: :farm,
    match: :exact,
    badge: %{
      type: :count,
      subscribe: {"farm:stats", fn msg -> msg.printing_count end}
    }
  },
  %{
    id: :history,
    label: "History",
    icon: "hero-chart-bar",
    path: "/dashboard/history",
    priority: 200,
    group: :farm
  },
  %{
    id: :farm_settings,
    label: "Farm Settings",
    icon: "hero-cog-6-tooth",
    path: "/dashboard/farm-settings",
    priority: 300,
    group: :farm,
    visible: fn scope -> scope.user.has_farm? end
  }
]

config :phoenix_kit, :user_dashboard_tab_groups, [
  %{id: :farm, label: "Farm Management", priority: 100, icon: "hero-cube"},
  %{id: :account, label: "Account", priority: 900}
]
```

### E-commerce Example

```elixir
config :phoenix_kit, :user_dashboard_tabs, [
  %{
    id: :orders,
    label: "Orders",
    icon: "hero-shopping-bag",
    path: "/dashboard/orders",
    priority: 100,
    badge: %{type: :count, value: 0}
  },
  %{
    id: :wishlist,
    label: "Wishlist",
    icon: "hero-heart",
    path: "/dashboard/wishlist",
    priority: 200
  },
  %{
    id: :reviews,
    label: "Reviews",
    icon: "hero-star",
    path: "/dashboard/reviews",
    priority: 300,
    badge: %{type: :new}
  },
  %{
    id: :addresses,
    label: "Addresses",
    icon: "hero-map-pin",
    path: "/dashboard/addresses",
    priority: 400
  }
]
```

## Context Selector

For multi-tenant applications where users can switch between organizations, farms, teams, or workspaces.

### Configuration

```elixir
config :phoenix_kit, :dashboard_context_selector,
  # Required: Function to load contexts for a user
  loader: {MyApp.Farms, :list_for_user},

  # Required: Function to get display name from context item
  display_name: fn farm -> farm.name end,

  # Optional settings with defaults shown
  id_field: :id,                    # Field or function to get ID
  label: "Farm",                    # UI label (e.g., "Switch Farm")
  icon: "hero-building-office",     # Heroicon name
  position: :sidebar,               # :header or :sidebar
  sub_position: :end,               # :start, :end, or {:priority, N}
  separator: "/",                   # Header separator (false to disable)
  empty_behavior: :hide,            # :hide, :show_empty, or {:redirect, "/setup"}
  session_key: "dashboard_context_id",

  # Optional: Dynamic tabs based on context
  tab_loader: {MyApp.Farms, :get_tabs_for_context}
```

### Dynamic Tabs Based on Context

The `tab_loader` option allows tabs to change based on the selected context:

```elixir
# In your context module
def get_tabs_for_context(%{type: :personal}) do
  [
    %{id: :overview, label: "Overview", path: "/dashboard", icon: "hero-home"},
    %{id: :settings, label: "Settings", path: "/dashboard/settings", icon: "hero-cog-6-tooth"}
  ]
end

def get_tabs_for_context(%{type: :team}) do
  [
    %{id: :overview, label: "Overview", path: "/dashboard", icon: "hero-home"},
    %{id: :projects, label: "Projects", path: "/dashboard/projects", icon: "hero-folder"},
    %{id: :settings, label: "Settings", path: "/dashboard/settings", icon: "hero-cog-6-tooth"}
  ]
end
```

### LiveView Integration

Add the ContextProvider to your live_session:

```elixir
live_session :dashboard,
  on_mount: [
    {PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope},
    {PhoenixKitWeb.Dashboard.ContextProvider, :default}
  ] do
  live "/dashboard", DashboardLive.Index
end
```

### Accessing Current Context

```elixir
defmodule MyAppWeb.DashboardLive do
  def mount(_params, _session, socket) do
    # Context is loaded by on_mount hook
    context = socket.assigns.current_context

    if context do
      items = MyApp.Items.list_for_context(context.id)
      {:ok, assign(socket, items: items)}
    else
      {:ok, assign(socket, items: [])}
    end
  end
end

# Or use helper functions
context = PhoenixKit.Dashboard.current_context(socket)
context_id = PhoenixKit.Dashboard.current_context_id(socket)
has_multiple = PhoenixKit.Dashboard.has_multiple_contexts?(socket)
```

### Socket Assigns Set by ContextProvider

- `@dashboard_contexts` - List of all contexts available to the user
- `@current_context` - The currently selected context item
- `@show_context_selector` - Boolean, true only if user has 2+ contexts
- `@context_selector_config` - The configuration struct
- `@dashboard_tabs` - (Optional) List of Tab structs when `tab_loader` is configured

### Position Options

The context selector position is controlled by two options: `position` and `sub_position`.

**Position (which area):**
- `:header` - Shows in the page header
- `:sidebar` - Shows in the sidebar navigation

**Sub-position (where within the area):**

For `:header`:
- `:start` - Left side, after the logo (default)
- `:end` - Right side, before the user menu
- `{:priority, N}` - Sorted among other header items by priority

For `:sidebar`:
- `:start` - At the top of the sidebar (default)
- `:end` - Pinned to the very bottom of the sidebar (sticky footer style)
- `{:priority, N}` - Sorted among tabs by priority number

**Examples:**

```elixir
# Header, left side
position: :header, sub_position: :start

# Header, right side
position: :header, sub_position: :end

# Sidebar, at the top
position: :sidebar, sub_position: :start

# Sidebar, pinned to the very bottom
position: :sidebar, sub_position: :end

# Sidebar, between tabs with priority 150
position: :sidebar, sub_position: {:priority, 150}
```

**Header Separator:**

When using `position: :header, sub_position: :start`, a separator character is shown
between the logo/title and the context selector. Configure with:

```elixir
separator: "/"      # Default - shows a forward slash
separator: "›"      # Use a chevron
separator: "|"      # Use a pipe
separator: false    # Disable separator entirely
```

> **Note:** The separator may appear slightly off-center visually. This is due to
> internal padding in the selector dropdown creating an optical illusion of uneven
> spacing. If precise alignment is required, customize the layout template directly.

### Behavior

- **Single context**: Selector is hidden, user doesn't know multi-context exists
- **Multiple contexts**: Dropdown appears based on position setting
- **Context switch**: POST to `/phoenix_kit/context/:id`, session updated, page redirects back
- **Persistence**: Selection stored in session, survives navigation
