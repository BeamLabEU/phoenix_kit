defmodule PhoenixKit.Dashboard do
  @moduledoc """
  User Dashboard Tab Management System.

  PhoenixKit's dashboard provides a flexible, extensible navigation system that
  parent applications can customize with their own tabs, badges, and features.

  ## Features

  - **Dynamic Tabs**: Register tabs from config or at runtime
  - **Live Badges**: Real-time badge updates via PubSub
  - **Grouping**: Organize tabs into logical sections with headers
  - **Conditional Visibility**: Show/hide tabs based on roles or custom logic
  - **Attention Indicators**: Pulse, bounce, shake animations to draw attention
  - **Presence Tracking**: Show how many users are viewing each tab
  - **Path Matching**: Flexible active state detection (exact, prefix, custom)

  ## Quick Start

  ### 1. Configure Tabs in config.exs

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

  ### 2. Register Tabs at Runtime (Optional)

      # In your application startup or a LiveView mount
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

  ### 3. Update Badges Live

      # From anywhere in your app
      PhoenixKit.Dashboard.update_badge(:notifications, 5)
      PhoenixKit.Dashboard.update_badge(:printers, count: 3, color: :warning)

  ### 4. Trigger Attention

      # Make a tab pulse to draw attention
      PhoenixKit.Dashboard.set_attention(:alerts, :pulse)

  ## Tab Groups

  Organize tabs into sections:

      config :phoenix_kit, :user_dashboard_tab_groups, [
        %{id: :main, label: nil, priority: 100},
        %{id: :farm, label: "Farm Management", priority: 200, icon: "hero-cube"},
        %{id: :account, label: "Account", priority: 900}
      ]

  Then assign tabs to groups:

      %{id: :printers, label: "Printers", path: "/dashboard/printers", group: :farm}

  ## Conditional Visibility

  Use `visible` for non-permission conditional logic (feature flags, user data).
  For access control, use the `permission` field instead.

      %{
        id: :beta_feature,
        label: "Beta",
        path: "/dashboard/beta",
        visible: fn scope ->
          scope.user.features["beta_enabled"] == true
        end
      }

  ## Live Badges with PubSub

  Badges can subscribe to PubSub topics for real-time updates:

      %{
        id: :notifications,
        label: "Notifications",
        path: "/dashboard/notifications",
        badge: %{
          type: :count,
          color: :error,
          subscribe: {"user:\#{user_id}:notifications", :unread_count}
        }
      }

  When a message is broadcast to the topic, the badge automatically updates.

  ## Presence Tracking

  Track which users are viewing which tabs:

      # In your LiveView
      def mount(_params, _session, socket) do
        if connected?(socket) do
          PhoenixKit.Dashboard.Presence.track_tab(socket, :orders)
        end
        {:ok, socket}
      end

  The sidebar will show "2 viewing" indicators.
  """

  alias PhoenixKit.Dashboard.{Badge, ContextSelector, Group, Presence, Registry, Tab}
  alias PhoenixKit.PubSubHelper

  # ============================================================================
  # Tab Registration
  # ============================================================================

  @doc """
  Registers dashboard tabs for an application namespace.

  ## Examples

      # Register multiple tabs
      PhoenixKit.Dashboard.register_tabs(:my_app, [
        %{id: :orders, label: "Orders", path: "/dashboard/orders", icon: "hero-shopping-bag"},
        %{id: :history, label: "History", path: "/dashboard/history", icon: "hero-clock"}
      ])

      # Register a single tab
      PhoenixKit.Dashboard.register_tabs(:my_app, [
        Tab.new!(id: :custom, label: "Custom", path: "/dashboard/custom")
      ])
  """
  @spec register_tabs(atom(), [map() | Tab.t()]) :: :ok | {:error, term()}
  def register_tabs(namespace, tabs) when is_atom(namespace) and is_list(tabs) do
    parsed_tabs =
      Enum.reduce_while(tabs, {:ok, []}, fn
        %Tab{} = tab, {:ok, acc} ->
          {:cont, {:ok, [tab | acc]}}

        attrs, {:ok, acc} ->
          case Tab.new(attrs) do
            {:ok, tab} -> {:cont, {:ok, [tab | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end)

    case parsed_tabs do
      {:ok, tab_list} ->
        Registry.register(namespace, Enum.reverse(tab_list))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Unregisters all tabs for a namespace.

  ## Examples

      PhoenixKit.Dashboard.unregister_tabs(:my_app)
  """
  @spec unregister_tabs(atom()) :: :ok
  defdelegate unregister_tabs(namespace), to: Registry, as: :unregister

  @doc """
  Unregisters a specific tab by ID.

  ## Examples

      PhoenixKit.Dashboard.unregister_tab(:orders)
  """
  @spec unregister_tab(atom()) :: :ok
  defdelegate unregister_tab(tab_id), to: Registry

  # ============================================================================
  # Admin Tab Management
  # ============================================================================

  @doc """
  Gets all admin-level tabs, filtered by permission and module-enabled status.

  ## Options

  - `:scope` - The current authentication scope for permission filtering

  ## Examples

      tabs = PhoenixKit.Dashboard.get_admin_tabs(scope: scope)
  """
  @spec get_admin_tabs(keyword()) :: [Tab.t()]
  defdelegate get_admin_tabs(opts \\ []), to: Registry

  @doc """
  Gets all user-level tabs, filtered by visibility and scope.

  ## Options

  - `:scope` - The current authentication scope for visibility filtering

  ## Examples

      tabs = PhoenixKit.Dashboard.get_user_tabs(scope: scope)
  """
  @spec get_user_tabs(keyword()) :: [Tab.t()]
  defdelegate get_user_tabs(opts \\ []), to: Registry

  @doc """
  Registers admin tabs for an application namespace.

  Automatically sets `level: :admin` on all tabs.

  ## Examples

      PhoenixKit.Dashboard.register_admin_tabs(:my_app, [
        %{id: :admin_analytics, label: "Analytics", path: "/admin/analytics",
          icon: "hero-chart-bar", permission: "dashboard"}
      ])
  """
  @spec register_admin_tabs(atom(), [map() | Tab.t()]) :: :ok | {:error, term()}
  def register_admin_tabs(namespace, tabs) when is_atom(namespace) and is_list(tabs) do
    admin_tabs = Enum.map(tabs, fn tab -> Map.put(tab, :level, :admin) end)
    register_tabs(namespace, admin_tabs)
  end

  @doc """
  Updates an existing tab's attributes by ID.

  ## Examples

      PhoenixKit.Dashboard.update_tab(:admin_dashboard, %{label: "Home", icon: "hero-home"})
  """
  @spec update_tab(atom(), map()) :: :ok | {:error, :not_found}
  defdelegate update_tab(tab_id, attrs), to: Registry

  @doc """
  Loads the default admin tabs into the registry.

  Called automatically on Registry startup, but can be called manually
  to reload defaults after changes.
  """
  @spec load_admin_defaults() :: :ok
  defdelegate load_admin_defaults(), to: Registry

  @doc """
  Gets all registered tabs, sorted by priority.

  ## Options

  - `:scope` - Filter by visibility using the current scope
  - `:include_hidden` - Include tabs that would be hidden (default: false)

  ## Examples

      tabs = PhoenixKit.Dashboard.get_tabs()
      tabs = PhoenixKit.Dashboard.get_tabs(scope: socket.assigns.phoenix_kit_current_scope)
  """
  @spec get_tabs(keyword()) :: [Tab.t()]
  defdelegate get_tabs(opts \\ []), to: Registry

  @doc """
  Gets a specific tab by ID.

  ## Examples

      tab = PhoenixKit.Dashboard.get_tab(:orders)
  """
  @spec get_tab(atom()) :: Tab.t() | nil
  defdelegate get_tab(tab_id), to: Registry

  @doc """
  Gets all tabs with their active state for the given path.

  Returns tabs with an additional `:active` key.

  ## Examples

      tabs = PhoenixKit.Dashboard.get_tabs_with_active("/dashboard/orders")
  """
  @spec get_tabs_with_active(String.t(), keyword()) :: [map()]
  defdelegate get_tabs_with_active(current_path, opts \\ []), to: Registry

  @doc """
  Registers tab groups for organizing the sidebar.

  ## Examples

      PhoenixKit.Dashboard.register_groups([
        %{id: :main, label: nil, priority: 100},
        %{id: :farm, label: "Farm Management", priority: 200, icon: "hero-cube"},
        %{id: :account, label: "Account", priority: 900}
      ])
  """
  @spec register_groups([Group.t() | map()]) :: :ok
  defdelegate register_groups(groups), to: Registry

  @doc """
  Gets all registered tab groups.
  """
  @spec get_groups() :: [Group.t()]
  defdelegate get_groups(), to: Registry

  # ============================================================================
  # Subtab Management
  # ============================================================================

  @doc """
  Gets all subtabs for a given parent tab ID.

  ## Examples

      PhoenixKit.Dashboard.get_subtabs(:orders)
      # => [%Tab{id: :pending_orders, parent: :orders, ...}, ...]
  """
  @spec get_subtabs(atom(), keyword()) :: [Tab.t()]
  defdelegate get_subtabs(parent_id, opts \\ []), to: Registry

  @doc """
  Gets only top-level tabs (tabs without a parent).

  ## Examples

      PhoenixKit.Dashboard.get_top_level_tabs()
      # => [%Tab{id: :orders, parent: nil, ...}, ...]
  """
  @spec get_top_level_tabs(keyword()) :: [Tab.t()]
  defdelegate get_top_level_tabs(opts \\ []), to: Registry

  @doc """
  Checks if a tab has any subtabs.

  ## Examples

      PhoenixKit.Dashboard.has_subtabs?(:orders)
      # => true
  """
  @spec has_subtabs?(atom()) :: boolean()
  defdelegate has_subtabs?(tab_id), to: Registry

  @doc """
  Checks if a tab is a subtab (has a parent).

  ## Examples

      PhoenixKit.Dashboard.subtab?(:pending_orders)
      # => true
  """
  @spec subtab?(Tab.t()) :: boolean()
  defdelegate subtab?(tab), to: Tab

  @doc """
  Checks if subtabs should be shown for a tab based on its display setting and active state.

  ## Examples

      PhoenixKit.Dashboard.show_subtabs?(tab, true)  # parent is active
      # => true (for :when_active or :always)

      PhoenixKit.Dashboard.show_subtabs?(tab, false)  # parent not active
      # => true (only for :always)
  """
  @spec show_subtabs?(Tab.t(), boolean()) :: boolean()
  defdelegate show_subtabs?(tab, active), to: Tab

  # ============================================================================
  # Badge Management
  # ============================================================================

  @doc """
  Updates a tab's badge.

  ## Examples

      # Set a count badge
      PhoenixKit.Dashboard.update_badge(:notifications, 5)

      # Set badge with options
      PhoenixKit.Dashboard.update_badge(:alerts, count: 3, color: :error, pulse: true)

      # Set a dot badge
      PhoenixKit.Dashboard.update_badge(:status, type: :dot, color: :success)

      # Clear a badge
      PhoenixKit.Dashboard.update_badge(:notifications, nil)
  """
  @spec update_badge(atom(), integer() | map() | keyword() | Badge.t() | nil) :: :ok
  def update_badge(tab_id, value) when is_integer(value) do
    badge = Badge.count(value)
    Registry.update_tab_badge(tab_id, badge)
  end

  def update_badge(tab_id, %Badge{} = badge) do
    Registry.update_tab_badge(tab_id, badge)
  end

  def update_badge(tab_id, nil) do
    Registry.update_tab_badge(tab_id, nil)
  end

  def update_badge(tab_id, opts) when is_list(opts) or is_map(opts) do
    case Badge.new(opts) do
      {:ok, badge} -> Registry.update_tab_badge(tab_id, badge)
      {:error, _} -> :ok
    end
  end

  @doc """
  Increments a tab's count badge by a given amount.

  ## Examples

      PhoenixKit.Dashboard.increment_badge(:notifications)
      PhoenixKit.Dashboard.increment_badge(:notifications, 5)
  """
  @spec increment_badge(atom(), integer()) :: :ok
  def increment_badge(tab_id, amount \\ 1) do
    case Registry.get_tab(tab_id) do
      %Tab{badge: %Badge{type: :count, value: current}} when is_integer(current) ->
        update_badge(tab_id, current + amount)

      %Tab{badge: nil} ->
        update_badge(tab_id, amount)

      _ ->
        :ok
    end
  end

  @doc """
  Decrements a tab's count badge by a given amount.

  Will not go below 0.
  """
  @spec decrement_badge(atom(), integer()) :: :ok
  def decrement_badge(tab_id, amount \\ 1) do
    case Registry.get_tab(tab_id) do
      %Tab{badge: %Badge{type: :count, value: current}} when is_integer(current) ->
        update_badge(tab_id, max(0, current - amount))

      _ ->
        :ok
    end
  end

  @doc """
  Clears a tab's badge.
  """
  @spec clear_badge(atom()) :: :ok
  def clear_badge(tab_id) do
    update_badge(tab_id, nil)
  end

  # ============================================================================
  # Attention / Animations
  # ============================================================================

  @doc """
  Sets an attention animation on a tab.

  ## Animation Types

  - `:pulse` - Gentle pulsing glow
  - `:bounce` - Bouncing motion
  - `:shake` - Shaking motion (for errors/alerts)
  - `:glow` - Glowing effect

  ## Examples

      PhoenixKit.Dashboard.set_attention(:alerts, :pulse)
      PhoenixKit.Dashboard.set_attention(:errors, :shake)
  """
  @spec set_attention(atom(), atom()) :: :ok
  defdelegate set_attention(tab_id, animation), to: Registry, as: :set_tab_attention

  @doc """
  Clears attention animation from a tab.
  """
  @spec clear_attention(atom()) :: :ok
  defdelegate clear_attention(tab_id), to: Registry, as: :clear_tab_attention

  # ============================================================================
  # PubSub Integration
  # ============================================================================

  @doc """
  Gets the PubSub topic for tab updates.

  Subscribe to this topic to receive real-time tab updates in LiveViews.

  ## Example

      def mount(_params, _session, socket) do
        if connected?(socket) do
          Phoenix.PubSub.subscribe(PubSubHelper.pubsub(), PhoenixKit.Dashboard.pubsub_topic())
        end
        {:ok, socket}
      end

      def handle_info({:tab_updated, tab}, socket) do
        # Handle tab update - refresh sidebar
        {:noreply, assign(socket, tabs: PhoenixKit.Dashboard.get_tabs())}
      end

      def handle_info(:tabs_refreshed, socket) do
        # Full tab list refresh
        {:noreply, assign(socket, tabs: PhoenixKit.Dashboard.get_tabs())}
      end
  """
  @spec pubsub_topic() :: String.t()
  defdelegate pubsub_topic(), to: Registry

  @doc """
  Subscribes the current process to tab updates.

  Convenience wrapper around Phoenix.PubSub.subscribe/2.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(PubSubHelper.pubsub(), Registry.pubsub_topic())
  end

  # ============================================================================
  # Presence
  # ============================================================================

  @doc """
  Tracks a user's presence on a dashboard tab.

  ## Examples

      PhoenixKit.Dashboard.track_presence(socket, :orders)
  """
  @spec track_presence(Phoenix.LiveView.Socket.t(), atom(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate track_presence(socket, tab_id, opts \\ []), to: Presence, as: :track_tab

  @doc """
  Gets the number of users viewing a specific tab.

  ## Examples

      count = PhoenixKit.Dashboard.get_viewer_count(:orders)
  """
  @spec get_viewer_count(atom()) :: integer()
  def get_viewer_count(tab_id) do
    Presence.get_tab_viewers(tab_id, format: :count)
  end

  @doc """
  Gets viewer counts for all tabs.

  ## Examples

      counts = PhoenixKit.Dashboard.get_all_viewer_counts()
      # => %{orders: 3, settings: 1, printers: 2}
  """
  @spec get_all_viewer_counts() :: map()
  defdelegate get_all_viewer_counts(), to: Presence, as: :get_all_tab_counts

  # ============================================================================
  # Context Selector
  # ============================================================================

  @doc """
  Gets the current context from socket assigns.

  Returns nil if context selector is not configured or no context is selected.

  ## Examples

      context = PhoenixKit.Dashboard.current_context(socket)
      # => %MyApp.Farm{id: 1, name: "My Farm"}

      context = PhoenixKit.Dashboard.current_context(socket.assigns)
      # => %MyApp.Farm{id: 1, name: "My Farm"}
  """
  @spec current_context(Phoenix.LiveView.Socket.t() | map()) :: any() | nil
  def current_context(%Phoenix.LiveView.Socket{assigns: assigns}), do: current_context(assigns)
  def current_context(%{current_context: context}), do: context
  def current_context(_), do: nil

  @doc """
  Gets the current context ID from socket assigns.

  Convenience function that extracts just the ID.

  ## Examples

      context_uuid = PhoenixKit.Dashboard.current_context_uuid(socket)
      # => "550e8400-e29b-41d4-a716-446655440000"
  """
  @spec current_context_uuid(Phoenix.LiveView.Socket.t() | map()) :: any() | nil
  def current_context_uuid(socket_or_assigns) do
    case current_context(socket_or_assigns) do
      nil -> nil
      context -> ContextSelector.get_id(context)
    end
  end

  @doc """
  Checks if the user has multiple contexts available.

  Returns true only if context selector is enabled and user has 2+ contexts.

  ## Examples

      if PhoenixKit.Dashboard.has_multiple_contexts?(socket) do
        # Show context-specific UI
      end
  """
  @spec has_multiple_contexts?(Phoenix.LiveView.Socket.t() | map()) :: boolean()
  def has_multiple_contexts?(%Phoenix.LiveView.Socket{assigns: assigns}) do
    has_multiple_contexts?(assigns)
  end

  def has_multiple_contexts?(%{show_context_selector: true}), do: true
  def has_multiple_contexts?(_), do: false

  @doc """
  Checks if the context selector feature is enabled.

  ## Examples

      if PhoenixKit.Dashboard.context_selector_enabled?() do
        # Context switching is available
      end
  """
  @spec context_selector_enabled?() :: boolean()
  defdelegate context_selector_enabled?(), to: ContextSelector, as: :enabled?

  # ============================================================================
  # Helpers
  # ============================================================================

  @doc """
  Creates a new Tab struct.

  See `PhoenixKit.Dashboard.Tab.new/1` for options.
  """
  @spec new_tab(map() | keyword()) :: {:ok, Tab.t()} | {:error, String.t()}
  defdelegate new_tab(attrs), to: Tab, as: :new

  @doc """
  Creates a new Tab struct, raising on error.
  """
  @spec new_tab!(map() | keyword()) :: Tab.t()
  defdelegate new_tab!(attrs), to: Tab, as: :new!

  @doc """
  Creates a divider for visual separation in the sidebar.

  ## Examples

      PhoenixKit.Dashboard.divider(priority: 150)
      PhoenixKit.Dashboard.divider(priority: 200, label: "Account")
  """
  @spec divider(keyword()) :: Tab.t()
  defdelegate divider(opts \\ []), to: Tab

  @doc """
  Creates a group header for organizing tabs.

  ## Examples

      PhoenixKit.Dashboard.group_header(id: :farm, label: "Farm Management", priority: 200)
  """
  @spec group_header(keyword()) :: Tab.t()
  defdelegate group_header(opts), to: Tab

  @doc """
  Creates a new Badge struct.

  See `PhoenixKit.Dashboard.Badge.new/1` for options.
  """
  @spec new_badge(map() | keyword()) :: {:ok, Badge.t()} | {:error, String.t()}
  defdelegate new_badge(attrs), to: Badge, as: :new

  @doc """
  Creates a count badge.
  """
  @spec count_badge(integer(), keyword()) :: Badge.t()
  defdelegate count_badge(value, opts \\ []), to: Badge, as: :count

  @doc """
  Creates a dot badge.
  """
  @spec dot_badge(keyword()) :: Badge.t()
  defdelegate dot_badge(opts \\ []), to: Badge, as: :dot

  @doc """
  Creates a status badge.
  """
  @spec status_badge(atom() | String.t(), keyword()) :: Badge.t()
  defdelegate status_badge(value, opts \\ []), to: Badge, as: :status

  @doc """
  Creates a live badge that subscribes to PubSub updates.
  """
  @spec live_badge(String.t(), atom() | (map() -> any()), keyword()) :: Badge.t()
  defdelegate live_badge(topic, extractor, opts \\ []), to: Badge, as: :live

  @doc """
  Checks if a tab matches the given path.
  """
  @spec matches_path?(Tab.t(), String.t()) :: boolean()
  defdelegate matches_path?(tab, path), to: Tab

  @doc """
  Checks if a tab is visible for the given scope.
  """
  @spec visible?(Tab.t(), map()) :: boolean()
  defdelegate visible?(tab, scope), to: Tab
end
