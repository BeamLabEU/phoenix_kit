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

### 1. Configure Tabs in config.exs

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

### 2. Register Tabs at Runtime (Optional)

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

### 3. Update Badges Live

```elixir
# From anywhere in your app
PhoenixKit.Dashboard.update_badge(:notifications, 5)
PhoenixKit.Dashboard.update_badge(:printers, count: 3, color: :warning)

# Increment/decrement
PhoenixKit.Dashboard.increment_badge(:notifications)
PhoenixKit.Dashboard.decrement_badge(:notifications)
```

### 4. Trigger Attention

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

### Subtab Appearance

- Subtabs are automatically indented with a left border
- Subtabs have smaller icons and slightly different styling
- Subtabs maintain their own badges and attention states

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
