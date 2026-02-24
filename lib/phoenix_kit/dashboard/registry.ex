defmodule PhoenixKit.Dashboard.Registry do
  @moduledoc """
  Registry for managing dashboard tabs across the application.

  The Registry provides both compile-time configuration via application config
  and runtime registration for dynamic tabs. Tabs are stored in an ETS table
  for efficient access.

  ## Configuration

  Tabs can be configured in your application config:

      config :phoenix_kit, :user_dashboard_tabs, [
        %{
          id: :orders,
          label: "Orders",
          icon: "hero-shopping-bag",
          path: "/dashboard/orders",
          priority: 100
        },
        %{
          id: :settings,
          label: "Settings",
          icon: "hero-cog-6-tooth",
          path: "/dashboard/settings",
          priority: 900
        }
      ]

  ## Runtime Registration

  Parent applications can register tabs at runtime:

      PhoenixKit.Dashboard.Registry.register(:my_app, [
        Tab.new!(id: :custom, label: "Custom", path: "/dashboard/custom", priority: 150)
      ])

  ## Groups

  Tabs can be organized into groups:

      config :phoenix_kit, :user_dashboard_tab_groups, [
        %{id: :main, label: nil, priority: 100},
        %{id: :farm, label: "Farm Management", priority: 200, icon: "hero-cube"},
        %{id: :account, label: "Account", priority: 900}
      ]

  Then assign tabs to groups:

      %{id: :printers, label: "Printers", path: "/dashboard/printers", group: :farm}

  ## PubSub Integration

  The registry can broadcast tab updates:

      PhoenixKit.Dashboard.Registry.update_tab_badge(:notifications, Badge.count(5))

  LiveViews subscribed to "phoenix_kit:dashboard:tabs" will receive updates.
  """

  use GenServer

  require Logger

  alias PhoenixKit.Dashboard.{AdminTabs, Badge, Group, Tab}
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Entities
  alias PhoenixKit.PubSubHelper
  alias PhoenixKit.Users.Permissions

  @ets_table :phoenix_kit_dashboard_tabs
  @pubsub_topic "phoenix_kit:dashboard:tabs"

  # Client API

  @doc """
  Starts the Registry GenServer.

  This is typically called by the PhoenixKit supervisor.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers tabs for an application namespace.

  ## Examples

      Registry.register(:my_app, [
        Tab.new!(id: :home, label: "Home", path: "/dashboard", icon: "hero-home"),
        Tab.new!(id: :orders, label: "Orders", path: "/dashboard/orders")
      ])

      # Register a single tab
      Registry.register(:my_app, Tab.new!(id: :settings, label: "Settings", path: "/dashboard/settings"))
  """
  @spec register(atom(), Tab.t() | [Tab.t()]) :: :ok
  def register(namespace, %Tab{} = tab) do
    register(namespace, [tab])
  end

  def register(namespace, tabs) when is_atom(namespace) and is_list(tabs) do
    GenServer.call(__MODULE__, {:register, namespace, tabs})
  end

  @doc """
  Registers tabs from a map/keyword configuration.

  Useful for registering tabs from config files.

  ## Examples

      Registry.register_from_config(:my_app, [
        %{id: :home, label: "Home", path: "/dashboard", icon: "hero-home"},
        %{id: :orders, label: "Orders", path: "/dashboard/orders"}
      ])
  """
  @spec register_from_config(atom(), [map()] | [keyword()]) :: :ok | {:error, term()}
  def register_from_config(namespace, config) when is_atom(namespace) and is_list(config) do
    tabs =
      Enum.reduce_while(config, {:ok, []}, fn item, {:ok, acc} ->
        case Tab.new(item) do
          {:ok, tab} -> {:cont, {:ok, [tab | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case tabs do
      {:ok, tab_list} ->
        register(namespace, Enum.reverse(tab_list))
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Unregisters all tabs for a namespace.
  """
  @spec unregister(atom()) :: :ok
  def unregister(namespace) when is_atom(namespace) do
    GenServer.call(__MODULE__, {:unregister, namespace})
  end

  @doc """
  Unregisters a specific tab by ID.
  """
  @spec unregister_tab(atom()) :: :ok
  def unregister_tab(tab_id) when is_atom(tab_id) do
    GenServer.call(__MODULE__, {:unregister_tab, tab_id})
  end

  @doc """
  Gets all registered tabs, sorted by priority.

  ## Options

  - `:scope` - The current scope (for visibility filtering)
  - `:level` - Filter by tab level: `:admin`, `:user`, or nil for all
  - `:path` - The current path (for active state detection)
  - `:include_hidden` - Include tabs that would be hidden (default: false)

  ## Examples

      Registry.get_tabs()
      Registry.get_tabs(scope: scope, level: :user)
      Registry.get_tabs(scope: scope, level: :admin)
  """
  @spec get_tabs(keyword()) :: [Tab.t()]
  def get_tabs(opts \\ []) do
    if initialized?() do
      scope = opts[:scope]
      level = opts[:level]
      include_hidden = opts[:include_hidden] || false

      all_tabs()
      |> maybe_filter_level(level)
      |> maybe_filter_enabled()
      |> maybe_filter_permission(scope)
      |> maybe_filter_visibility(scope, include_hidden)
      |> sort_tabs()
    else
      Logger.warning("[Registry] get_tabs/1 called before initialization, returning empty list")
      []
    end
  end

  @doc """
  Gets admin-level tabs, filtered by permission and module-enabled status.

  ## Options

  - `:scope` - The current scope (for permission and visibility filtering)
  - `:include_hidden` - Include tabs that would be hidden (default: false)
  """
  @spec get_admin_tabs(keyword()) :: [Tab.t()]
  def get_admin_tabs(opts \\ []) do
    get_tabs(Keyword.put(opts, :level, :admin))
  end

  @doc """
  Gets user-level tabs.

  ## Options

  - `:scope` - The current scope (for visibility filtering)
  - `:include_hidden` - Include tabs that would be hidden (default: false)
  """
  @spec get_user_tabs(keyword()) :: [Tab.t()]
  def get_user_tabs(opts \\ []) do
    get_tabs(Keyword.put(opts, :level, :user))
  end

  @doc """
  Updates an existing tab's attributes.

  ## Examples

      Registry.update_tab(:admin_dashboard, %{label: "Home", icon: "hero-house"})
  """
  @spec update_tab(atom(), map()) :: :ok
  def update_tab(tab_id, attrs) when is_atom(tab_id) and is_map(attrs) do
    GenServer.call(__MODULE__, {:update_tab, tab_id, attrs})
  end

  @doc """
  Gets a specific tab by ID.
  """
  @spec get_tab(atom()) :: Tab.t() | nil
  def get_tab(tab_id) when is_atom(tab_id) do
    if initialized?() do
      case :ets.lookup(@ets_table, {:tab, tab_id}) do
        [{_, tab}] -> tab
        [] -> nil
      end
    else
      nil
    end
  end

  @doc """
  Gets all tabs in a specific group.
  """
  @spec get_tabs_in_group(atom(), keyword()) :: [Tab.t()]
  def get_tabs_in_group(group_id, opts \\ []) do
    get_tabs(opts)
    |> Enum.filter(&(&1.group == group_id))
  end

  @doc """
  Gets all subtabs for a given parent tab ID.

  ## Examples

      Registry.get_subtabs(:orders)
      # => [%Tab{id: :pending_orders, parent: :orders, ...}, ...]
  """
  @spec get_subtabs(atom(), keyword()) :: [Tab.t()]
  def get_subtabs(parent_id, opts \\ []) when is_atom(parent_id) do
    get_tabs(opts)
    |> Enum.filter(&(&1.parent == parent_id))
  end

  @doc """
  Gets only top-level tabs (tabs without a parent).

  ## Options

  Same as `get_tabs/1`.

  ## Examples

      Registry.get_top_level_tabs()
      # => [%Tab{id: :orders, parent: nil, ...}, ...]
  """
  @spec get_top_level_tabs(keyword()) :: [Tab.t()]
  def get_top_level_tabs(opts \\ []) do
    get_tabs(opts)
    |> Enum.filter(&Tab.top_level?/1)
  end

  @doc """
  Checks if a tab has any subtabs.

  ## Examples

      Registry.has_subtabs?(:orders)
      # => true
  """
  @spec has_subtabs?(atom()) :: boolean()
  def has_subtabs?(tab_id) when is_atom(tab_id) do
    get_subtabs(tab_id) |> Enum.any?()
  end

  @doc """
  Gets all registered groups, sorted by priority.
  """
  @spec get_groups() :: [Group.t()]
  def get_groups do
    if initialized?() do
      case :ets.lookup(@ets_table, :groups) do
        [{:groups, groups}] -> Enum.sort_by(groups, & &1.priority)
        [] -> []
      end
    else
      []
    end
  end

  @doc """
  Registers tab groups.

  ## Examples

      Registry.register_groups([
        %{id: :main, label: nil, priority: 100},
        %{id: :farm, label: "Farm Management", priority: 200},
        %{id: :account, label: "Account", priority: 900}
      ])
  """
  @spec register_groups([Group.t() | map()]) :: :ok
  def register_groups(groups) when is_list(groups) do
    GenServer.call(__MODULE__, {:register_groups, groups})
  end

  @doc """
  Updates a tab's badge.

  This broadcasts an update to all subscribed LiveViews.

  ## Examples

      Registry.update_tab_badge(:notifications, Badge.count(5))
      Registry.update_tab_badge(:printers, Badge.count(3, color: :warning))
  """
  @spec update_tab_badge(atom(), Badge.t() | map() | nil) :: :ok
  def update_tab_badge(tab_id, badge) do
    GenServer.call(__MODULE__, {:update_badge, tab_id, badge})
  end

  @doc """
  Sets an attention animation on a tab.

  ## Examples

      Registry.set_tab_attention(:alerts, :pulse)
      Registry.set_tab_attention(:notifications, :bounce)
  """
  @spec set_tab_attention(atom(), atom()) :: :ok
  def set_tab_attention(tab_id, attention)
      when attention in [nil, :pulse, :bounce, :shake, :glow] do
    GenServer.call(__MODULE__, {:set_attention, tab_id, attention})
  end

  @doc """
  Clears attention animation from a tab.
  """
  @spec clear_tab_attention(atom()) :: :ok
  def clear_tab_attention(tab_id) do
    set_tab_attention(tab_id, nil)
  end

  @doc """
  Gets the PubSub topic for tab updates.

  LiveViews can subscribe to this topic to receive real-time tab updates.

  ## Example

      def mount(_params, _session, socket) do
        if connected?(socket) do
          Phoenix.PubSub.subscribe(PubSubHelper.pubsub(), Registry.pubsub_topic())
        end
        {:ok, socket}
      end

      def handle_info({:tab_updated, tab}, socket) do
        # Handle tab update
        {:noreply, socket}
      end
  """
  @spec pubsub_topic() :: String.t()
  def pubsub_topic, do: @pubsub_topic

  @doc """
  Broadcasts a tab update to all subscribers.
  """
  @spec broadcast_update(Tab.t()) :: :ok
  def broadcast_update(%Tab{} = tab) do
    Phoenix.PubSub.broadcast(PubSubHelper.pubsub(), @pubsub_topic, {:tab_updated, tab})
    :ok
  rescue
    error ->
      Logger.warning("[Registry] Failed to broadcast tab update: #{Exception.message(error)}")
      :ok
  end

  @doc """
  Broadcasts a full tab list refresh to all subscribers.
  """
  @spec broadcast_refresh() :: :ok
  def broadcast_refresh do
    Phoenix.PubSub.broadcast(PubSubHelper.pubsub(), @pubsub_topic, :tabs_refreshed)
    :ok
  rescue
    error ->
      Logger.warning("[Registry] Failed to broadcast tab refresh: #{Exception.message(error)}")
      :ok
  end

  @doc """
  Checks if the registry has been initialized.
  """
  @spec initialized?() :: boolean()
  def initialized? do
    case :ets.info(@ets_table) do
      :undefined -> false
      _ -> true
    end
  end

  @doc false
  @spec ets_table() :: atom()
  def ets_table, do: @ets_table

  @doc """
  Gets all tabs with their active state for the given path.

  Returns tabs with an additional `:active` key set based on path matching.
  """
  @spec get_tabs_with_active(String.t(), keyword()) :: [map()]
  def get_tabs_with_active(current_path, opts \\ []) do
    get_tabs(opts)
    |> Enum.map(fn tab ->
      Map.put(tab, :active, Tab.matches_path?(tab, current_path))
    end)
  end

  @doc """
  Loads the default PhoenixKit tabs (Dashboard, Settings).

  Called during initialization and can be used to reset to defaults.
  """
  @spec load_defaults() :: :ok
  def load_defaults do
    GenServer.call(__MODULE__, :load_defaults)
  end

  @doc """
  Loads tabs from application configuration.

  Reads from `:phoenix_kit, :user_dashboard_tabs` config key.
  """
  @spec load_from_config() :: :ok
  def load_from_config do
    GenServer.call(__MODULE__, :load_from_config)
  end

  @doc """
  Loads admin default tabs.

  Called during initialization.
  """
  @spec load_admin_defaults() :: :ok
  def load_admin_defaults do
    GenServer.call(__MODULE__, :load_admin_defaults)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for tab storage
    :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])

    # Load user dashboard defaults and config
    load_defaults_internal()
    load_from_config_internal()

    # Load admin dashboard defaults and config
    load_admin_defaults_internal()
    load_admin_from_config_internal()

    # Subscribe to entity lifecycle events for cache invalidation
    subscribe_to_entity_events()

    {:ok, %{namespaces: MapSet.new([:phoenix_kit, :phoenix_kit_admin])}}
  end

  @impl true
  def handle_call({:register, namespace, tabs}, _from, state) do
    Enum.each(tabs, fn tab ->
      :ets.insert(@ets_table, {{:tab, tab.id}, tab})
      :ets.insert(@ets_table, {{:namespace, namespace, tab.id}, true})

      # Auto-register custom permission keys for admin tabs
      if tab.level == :admin and is_binary(tab.permission) do
        auto_register_custom_permission(%{
          permission: tab.permission,
          label: tab.label,
          icon: tab.icon
        })
      end
    end)

    broadcast_refresh()
    {:reply, :ok, %{state | namespaces: MapSet.put(state.namespaces, namespace)}}
  end

  @impl true
  def handle_call({:unregister, namespace}, _from, state) do
    # Find and remove all tabs for this namespace
    pattern = {{:namespace, namespace, :_}, :_}

    :ets.match_object(@ets_table, pattern)
    |> Enum.each(fn {{:namespace, ^namespace, tab_id}, _} ->
      :ets.delete(@ets_table, {:tab, tab_id})
      :ets.delete(@ets_table, {:namespace, namespace, tab_id})
    end)

    broadcast_refresh()
    {:reply, :ok, %{state | namespaces: MapSet.delete(state.namespaces, namespace)}}
  end

  @impl true
  def handle_call({:unregister_tab, tab_id}, _from, state) do
    :ets.delete(@ets_table, {:tab, tab_id})

    # Remove from all namespace mappings
    :ets.match_delete(@ets_table, {{:namespace, :_, tab_id}, :_})

    broadcast_refresh()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:register_groups, groups}, _from, state) do
    converted =
      Enum.map(groups, fn
        %Group{} = g -> g
        map when is_map(map) -> Group.new(map)
      end)

    :ets.insert(@ets_table, {:groups, converted})
    broadcast_refresh()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_badge, tab_id, badge}, _from, state) do
    case get_tab(tab_id) do
      nil ->
        {:reply, :ok, state}

      tab ->
        updated_tab = Tab.update_badge(tab, badge)
        :ets.insert(@ets_table, {{:tab, tab_id}, updated_tab})
        broadcast_update(updated_tab)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:set_attention, tab_id, attention}, _from, state) do
    case get_tab(tab_id) do
      nil ->
        {:reply, :ok, state}

      tab ->
        updated_tab = Tab.set_attention(tab, attention)
        :ets.insert(@ets_table, {{:tab, tab_id}, updated_tab})
        broadcast_update(updated_tab)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:load_defaults, _from, state) do
    load_defaults_internal()
    load_admin_defaults_internal()
    broadcast_refresh()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:load_from_config, _from, state) do
    load_from_config_internal()
    load_admin_from_config_internal()
    broadcast_refresh()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:load_admin_defaults, _from, state) do
    load_admin_defaults_internal()
    broadcast_refresh()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_tab, tab_id, attrs}, _from, state) do
    case get_tab(tab_id) do
      nil ->
        {:reply, :ok, state}

      tab ->
        updated_tab =
          Enum.reduce(attrs, tab, fn
            {:label, v}, acc -> %{acc | label: v}
            {:icon, v}, acc -> %{acc | icon: v}
            {:path, v}, acc -> %{acc | path: v}
            {:priority, v}, acc -> %{acc | priority: v}
            {:visible, v}, acc -> %{acc | visible: v}
            {:permission, v}, acc -> %{acc | permission: v}
            {:group, v}, acc -> %{acc | group: v}
            {:metadata, v}, acc -> %{acc | metadata: Map.merge(acc.metadata, v)}
            _, acc -> acc
          end)

        :ets.insert(@ets_table, {{:tab, tab_id}, updated_tab})
        broadcast_update(updated_tab)
        {:reply, :ok, state}
    end
  end

  # Entity lifecycle events — invalidate the sidebar entity cache
  @impl true
  def handle_info({event, _entity_id}, state)
      when event in [:entity_created, :entity_updated, :entity_deleted] do
    if Code.ensure_loaded?(Entities) and
         function_exported?(Entities, :invalidate_entities_cache, 0) do
      Entities.invalidate_entities_cache()
    end

    broadcast_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Private helpers

  defp all_tabs do
    :ets.match_object(@ets_table, {{:tab, :_}, :_})
    |> Enum.map(fn {_, tab} -> tab end)
  rescue
    _ -> []
  end

  defp maybe_filter_visibility(tabs, nil, _include_hidden), do: tabs
  defp maybe_filter_visibility(tabs, _scope, true), do: tabs

  defp maybe_filter_visibility(tabs, scope, false) do
    Enum.filter(tabs, &Tab.visible?(&1, scope))
  end

  defp sort_tabs(tabs) do
    Enum.sort_by(tabs, & &1.priority)
  end

  # Filter tabs by level. :admin returns admin+all, :user returns user+all
  defp maybe_filter_level(tabs, nil), do: tabs

  defp maybe_filter_level(tabs, :admin) do
    Enum.filter(tabs, fn tab ->
      level = Map.get(tab, :level, :user)
      level in [:admin, :all]
    end)
  end

  defp maybe_filter_level(tabs, :user) do
    Enum.filter(tabs, fn tab ->
      level = Map.get(tab, :level, :user)
      level in [:user, :all]
    end)
  end

  defp maybe_filter_level(tabs, _), do: tabs

  # Filter out tabs whose associated module is disabled.
  # Precomputes enabled state per unique permission key to avoid
  # redundant DB queries (e.g., 5 "publishing" tabs = 1 query, not 5).
  defp maybe_filter_enabled(tabs) do
    enabled_cache =
      tabs
      |> Enum.map(& &1.permission)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(fn perm ->
        enabled =
          try do
            Permissions.feature_enabled?(perm)
          rescue
            _ -> false
          end

        {perm, enabled}
      end)

    Enum.filter(tabs, fn tab ->
      case tab.permission do
        nil -> true
        perm -> Map.get(enabled_cache, perm, true)
      end
    end)
  end

  # Filter tabs by permission access
  defp maybe_filter_permission(tabs, nil), do: tabs

  defp maybe_filter_permission(tabs, scope) do
    Enum.filter(tabs, &Tab.permission_granted?(&1, scope))
  end

  defp clear_namespace_tabs(namespace) do
    # Find and remove all tabs for this namespace
    pattern = {{:namespace, namespace, :_}, :_}

    :ets.match_object(@ets_table, pattern)
    |> Enum.each(fn {{:namespace, ^namespace, tab_id}, _} ->
      :ets.delete(@ets_table, {:tab, tab_id})
      :ets.delete(@ets_table, {:namespace, namespace, tab_id})
    end)
  rescue
    _ -> :ok
  end

  defp load_defaults_internal do
    # Clear existing phoenix_kit namespace tabs first
    clear_namespace_tabs(:phoenix_kit)

    # Default PhoenixKit tabs
    defaults = [
      Tab.new!(
        id: :dashboard_home,
        label: "Dashboard",
        icon: "hero-home",
        path: "/dashboard",
        priority: 100,
        match: :exact,
        group: :main
      ),
      Tab.new!(
        id: :dashboard_settings,
        label: "Settings",
        icon: "hero-cog-6-tooth",
        path: "/dashboard/settings",
        priority: 900,
        match: :prefix,
        group: :account
      )
    ]

    # Add user dashboard tabs from enabled modules via registry
    module_tabs = enabled_user_dashboard_tabs()
    defaults = defaults ++ module_tabs

    # Default groups
    groups = [
      %Group{id: :main, label: nil, priority: 100},
      %Group{id: :shop, label: nil, priority: 200},
      %Group{id: :account, label: nil, priority: 900}
    ]

    Enum.each(defaults, fn tab ->
      :ets.insert(@ets_table, {{:tab, tab.id}, tab})
      :ets.insert(@ets_table, {{:namespace, :phoenix_kit, tab.id}, true})
    end)

    :ets.insert(@ets_table, {:groups, groups})
  end

  defp load_from_config_internal do
    # Load from user_dashboard_categories (admin-style config)
    load_from_categories_config()

    # Load tab configuration (flat list style)
    case Application.get_env(:phoenix_kit, :user_dashboard_tabs) do
      nil ->
        :ok

      tabs when is_list(tabs) ->
        Enum.each(tabs, fn tab_config ->
          case Tab.new(tab_config) do
            {:ok, tab} ->
              :ets.insert(@ets_table, {{:tab, tab.id}, tab})
              :ets.insert(@ets_table, {{:namespace, :config, tab.id}, true})

            {:error, _reason} ->
              # Log error but continue
              :ok
          end
        end)
    end

    # Load group configuration
    case Application.get_env(:phoenix_kit, :user_dashboard_tab_groups) do
      nil ->
        :ok

      groups when is_list(groups) ->
        converted =
          Enum.map(groups, fn
            %Group{} = g -> g
            map when is_map(map) -> Group.new(map)
          end)

        :ets.insert(@ets_table, {:groups, converted})
    end
  end

  # Load from user_dashboard_categories config (admin-style format)
  defp load_from_categories_config do
    alias PhoenixKit.Config.UserDashboardCategories

    categories = UserDashboardCategories.get_categories()

    if categories != [] do
      # Convert categories to tabs and register them
      tabs = UserDashboardCategories.to_tabs(categories)

      Enum.each(tabs, fn tab_config ->
        case Tab.new(tab_config) do
          {:ok, tab} ->
            :ets.insert(@ets_table, {{:tab, tab.id}, tab})
            :ets.insert(@ets_table, {{:namespace, :categories, tab.id}, true})

          {:error, _reason} ->
            # Log error but continue
            :ok
        end
      end)

      # Convert categories to groups and register them
      groups = UserDashboardCategories.to_groups(categories)
      existing_groups = get_groups()
      merged_groups = merge_groups(existing_groups, groups)
      :ets.insert(@ets_table, {:groups, merged_groups})
    end
  end

  # Merge groups, preferring existing groups with same ID
  defp merge_groups(existing, new) do
    existing_ids = MapSet.new(Enum.map(existing, & &1.id))

    new_groups =
      Enum.reject(new, fn group ->
        MapSet.member?(existing_ids, group.id)
      end)

    (existing ++ new_groups)
    |> Enum.sort_by(& &1.priority)
  end

  # Collect user dashboard tabs from all enabled modules via registry
  defp enabled_user_dashboard_tabs do
    ModuleRegistry.enabled_modules()
    |> Enum.flat_map(fn mod ->
      if function_exported?(mod, :user_dashboard_tabs, 0),
        do: mod.user_dashboard_tabs(),
        else: []
    end)
  rescue
    _ -> []
  end

  # --- Admin Tab Loading ---

  defp load_admin_defaults_internal do
    clear_namespace_tabs(:phoenix_kit_admin)

    tabs = AdminTabs.default_tabs()
    groups = AdminTabs.default_groups()

    Enum.each(tabs, fn tab ->
      :ets.insert(@ets_table, {{:tab, tab.id}, tab})
      :ets.insert(@ets_table, {{:namespace, :phoenix_kit_admin, tab.id}, true})
    end)

    # Merge admin groups with existing groups
    existing_groups = get_groups()
    merged = merge_groups(existing_groups, groups)
    :ets.insert(@ets_table, {:groups, merged})
  end

  defp load_admin_from_config_internal do
    # Load legacy AdminDashboardCategories config and convert to admin-level tabs
    load_legacy_admin_categories()

    # Load new :admin_dashboard_tabs config (highest precedence)
    case Application.get_env(:phoenix_kit, :admin_dashboard_tabs) do
      nil ->
        :ok

      tabs when is_list(tabs) ->
        Enum.each(tabs, fn tab_config ->
          # Auto-set level to :admin for admin dashboard tabs
          tab_config = Map.put_new(tab_config, :level, :admin)

          case Tab.new(tab_config) do
            {:ok, tab} ->
              :ets.insert(@ets_table, {{:tab, tab.id}, tab})
              :ets.insert(@ets_table, {{:namespace, :admin_config, tab.id}, true})

              # Auto-register custom permission key and cache view mapping
              auto_register_custom_permission(tab_config)

            {:error, _reason} ->
              :ok
          end
        end)
    end
  end

  # Registers a custom permission key derived from a tab config map.
  # Only registers if the permission key is NOT one of the built-in keys.
  # Also caches live_view → permission mapping for auth enforcement.
  defp auto_register_custom_permission(%{permission: perm} = tab_config)
       when is_binary(perm) or is_atom(perm) do
    perm = to_string(perm)

    builtin_keys = Permissions.core_section_keys() ++ Permissions.feature_module_keys()

    unless perm == "" or perm in builtin_keys do
      Permissions.register_custom_key(perm,
        label: Map.get(tab_config, :label),
        icon: Map.get(tab_config, :icon),
        description: Map.get(tab_config, :description)
      )
    end

    # Cache live_view module → permission mapping regardless of key type
    if perm != "" do
      case Map.get(tab_config, :live_view) do
        {view_module, _action} when is_atom(view_module) ->
          Permissions.cache_custom_view_permission(view_module, perm)

        _ ->
          :ok
      end
    end
  rescue
    error ->
      Logger.warning(
        "[Registry] Failed to register custom permission #{inspect(perm)}: #{Exception.message(error)}"
      )

      :ok
  end

  defp auto_register_custom_permission(_), do: :ok

  # Subscribe to entity definition lifecycle events for sidebar cache invalidation.
  # Guarded since the Entities module is optional.
  defp subscribe_to_entity_events do
    events_mod = PhoenixKit.Modules.Entities.Events

    if Code.ensure_loaded?(events_mod) and
         function_exported?(events_mod, :subscribe_to_entities, 0) do
      events_mod.subscribe_to_entities()
    end
  rescue
    error ->
      Logger.warning(
        "[Registry] Failed to subscribe to entity events: #{Exception.message(error)}"
      )

      :ok
  end

  # Convert legacy AdminDashboardCategories to admin-level Tab structs
  defp load_legacy_admin_categories do
    alias PhoenixKit.Config.AdminDashboardCategories

    categories = AdminDashboardCategories.get_categories()

    if categories != [] do
      Logger.info(
        "[PhoenixKit] Legacy :admin_dashboard_categories config detected. " <>
          "Consider migrating to :admin_dashboard_tabs format."
      )

      # Convert each category to admin-level tabs
      categories
      |> Enum.with_index()
      |> Enum.each(fn {category, cat_idx} ->
        # Create parent tab from category
        cat_id = :"admin_custom_#{cat_idx}"

        first_url =
          case category.subsections do
            [first | _] -> Map.get(first, :url, "/admin")
            _ -> "/admin"
          end

        parent = %Tab{
          id: cat_id,
          label: category.title,
          icon: category.icon || "hero-folder",
          path: first_url,
          priority: 700 + cat_idx * 10,
          level: :admin,
          match: :prefix,
          group: :admin_modules,
          subtab_display: :when_active,
          highlight_with_subtabs: false
        }

        :ets.insert(@ets_table, {{:tab, parent.id}, parent})
        :ets.insert(@ets_table, {{:namespace, :admin_legacy, parent.id}, true})

        # Create child tabs from subsections
        category.subsections
        |> Enum.with_index()
        |> Enum.each(fn {subsection, sub_idx} ->
          child_id = :"admin_custom_#{cat_idx}_#{sub_idx}"

          child = %Tab{
            id: child_id,
            label: subsection.title,
            icon: subsection.icon || "hero-document-text",
            path: subsection.url,
            priority: 701 + cat_idx * 10 + sub_idx,
            level: :admin,
            match: :prefix,
            parent: cat_id
          }

          :ets.insert(@ets_table, {{:tab, child.id}, child})
          :ets.insert(@ets_table, {{:namespace, :admin_legacy, child.id}, true})
        end)
      end)
    end
  end
end
