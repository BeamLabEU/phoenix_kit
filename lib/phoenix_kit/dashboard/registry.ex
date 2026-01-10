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

  alias PhoenixKit.Dashboard.{Badge, Tab}

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
  - `:path` - The current path (for active state detection)
  - `:include_hidden` - Include tabs that would be hidden (default: false)

  ## Examples

      Registry.get_tabs()
      Registry.get_tabs(scope: socket.assigns.phoenix_kit_current_scope)
  """
  @spec get_tabs(keyword()) :: [Tab.t()]
  def get_tabs(opts \\ []) do
    scope = opts[:scope]
    include_hidden = opts[:include_hidden] || false

    all_tabs()
    |> maybe_filter_visibility(scope, include_hidden)
    |> sort_tabs()
  end

  @doc """
  Gets a specific tab by ID.
  """
  @spec get_tab(atom()) :: Tab.t() | nil
  def get_tab(tab_id) when is_atom(tab_id) do
    case :ets.lookup(@ets_table, {:tab, tab_id}) do
      [{_, tab}] -> tab
      [] -> nil
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
  Gets all registered groups, sorted by priority.
  """
  @spec get_groups() :: [map()]
  def get_groups do
    case :ets.lookup(@ets_table, :groups) do
      [{:groups, groups}] -> Enum.sort_by(groups, & &1.priority)
      [] -> []
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
  @spec register_groups([map()]) :: :ok
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
          Phoenix.PubSub.subscribe(PhoenixKit.PubSub, Registry.pubsub_topic())
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
    Phoenix.PubSub.broadcast(PhoenixKit.PubSub, @pubsub_topic, {:tab_updated, tab})
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Broadcasts a full tab list refresh to all subscribers.
  """
  @spec broadcast_refresh() :: :ok
  def broadcast_refresh do
    Phoenix.PubSub.broadcast(PhoenixKit.PubSub, @pubsub_topic, :tabs_refreshed)
    :ok
  rescue
    _ -> :ok
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

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for tab storage
    :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])

    # Load defaults and config
    load_defaults_internal()
    load_from_config_internal()

    {:ok, %{namespaces: MapSet.new([:phoenix_kit])}}
  end

  @impl true
  def handle_call({:register, namespace, tabs}, _from, state) do
    Enum.each(tabs, fn tab ->
      :ets.insert(@ets_table, {{:tab, tab.id}, tab})
      :ets.insert(@ets_table, {{:namespace, namespace, tab.id}, true})
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
    :ets.insert(@ets_table, {:groups, groups})
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
    broadcast_refresh()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:load_from_config, _from, state) do
    load_from_config_internal()
    broadcast_refresh()
    {:reply, :ok, state}
  end

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

  defp load_defaults_internal do
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

    # Add tickets tab if module is enabled (checking at runtime)
    defaults =
      if tickets_enabled?() do
        ticket_tab =
          Tab.new!(
            id: :dashboard_tickets,
            label: "My Tickets",
            icon: "hero-ticket",
            path: "/dashboard/tickets",
            priority: 800,
            match: :prefix,
            group: :account
          )

        defaults ++ [ticket_tab]
      else
        defaults
      end

    # Default groups
    groups = [
      %{id: :main, label: nil, priority: 100},
      %{id: :account, label: nil, priority: 900}
    ]

    Enum.each(defaults, fn tab ->
      :ets.insert(@ets_table, {{:tab, tab.id}, tab})
      :ets.insert(@ets_table, {{:namespace, :phoenix_kit, tab.id}, true})
    end)

    :ets.insert(@ets_table, {:groups, groups})
  end

  defp load_from_config_internal do
    # Load tab configuration
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
        :ets.insert(@ets_table, {:groups, groups})
    end
  end

  defp tickets_enabled? do
    Code.ensure_loaded?(PhoenixKit.Modules.Tickets) and
      function_exported?(PhoenixKit.Modules.Tickets, :enabled?, 0) and
      apply(PhoenixKit.Modules.Tickets, :enabled?, [])
  rescue
    _ -> false
  end
end
