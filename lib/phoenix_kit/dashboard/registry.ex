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
          path: "orders",
          priority: 100
        },
        %{
          id: :settings,
          label: "Settings",
          icon: "hero-cog-6-tooth",
          path: "settings",
          priority: 900
        }
      ]

  > Tab paths are relative by convention — `Tab.resolve_path/2` prepends the context prefix
  > (`/dashboard/`, `/admin/`, or `/admin/settings/`) at load time. Both relative and absolute
  > forms are accepted but relative is preferred.

  ## Runtime Registration

  Parent applications can register tabs at runtime:

      PhoenixKit.Dashboard.Registry.register(:my_app, [
        Tab.new!(id: :custom, label: "Custom", path: "custom", priority: 150)
      ])

  ## Groups

  Tabs can be organized into groups:

      config :phoenix_kit, :user_dashboard_tab_groups, [
        %{id: :main, label: nil, priority: 100},
        %{id: :farm, label: "Farm Management", priority: 200, icon: "hero-cube"},
        %{id: :account, label: "Account", priority: 900}
      ]

  Then assign tabs to groups:

      %{id: :printers, label: "Printers", path: "printers", group: :farm}

  ## PubSub Integration

  The registry can broadcast tab updates:

      PhoenixKit.Dashboard.Registry.update_tab_badge(:notifications, Badge.count(5))

  LiveViews subscribed to "phoenix_kit:dashboard:tabs" will receive updates.
  """

  use GenServer

  @compile {:no_warn_undefined,
            [
              {PhoenixKitEntities, :invalidate_entities_cache, 0},
              {PhoenixKitEntities.Events, :subscribe_to_entities, 0}
            ]}

  require Logger

  alias PhoenixKit.Dashboard.{AdminTabs, Badge, Group, Tab}
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.PubSubHelper
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Utils.Routes

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
        Tab.new!(id: :home, label: "Home", path: "", icon: "hero-home"),
        Tab.new!(id: :orders, label: "Orders", path: "orders")
      ])

      # Register a single tab
      Registry.register(:my_app, Tab.new!(id: :settings, label: "Settings", path: "settings"))
  """
  @spec register(atom(), Tab.t() | [Tab.t()]) :: :ok
  def register(namespace, %Tab{} = tab) do
    register(namespace, [tab])
  end

  def register(namespace, tabs) when is_atom(namespace) and is_list(tabs) do
    write_call({:register, namespace, tabs})
  end

  @doc """
  Registers tabs from a map/keyword configuration.

  Useful for registering tabs from config files.

  ## Examples

      Registry.register_from_config(:my_app, [
        %{id: :home, label: "Home", path: "", icon: "hero-home"},
        %{id: :orders, label: "Orders", path: "orders"}
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
    write_call({:unregister, namespace})
  end

  @doc """
  Unregisters a specific tab by ID.
  """
  @spec unregister_tab(atom()) :: :ok
  def unregister_tab(tab_id) when is_atom(tab_id) do
    write_call({:unregister_tab, tab_id})
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
  The admin path of the tab that declares `view` as its `live_view`, or
  `"/admin"` when nothing claims it.

  Sidebar active-state reads `assigns[:url_path]`, which the kit's on_mount
  chain fills in from a `:handle_params` hook. Two kinds of LiveView never get
  it: one rendered via `live_render/3` (an embed has no `handle_params`
  lifecycle at all) and a host LV that renders admin chrome without going
  through that chain. Both used to render with no tab highlighted and nothing
  to suggest why. A tab already knows its own path, so ask it.
  """
  @spec path_for_live_view(module()) :: String.t()
  def path_for_live_view(view) when is_atom(view) do
    get_admin_tabs(include_hidden: true)
    |> Enum.find_value(fn
      %Tab{live_view: {^view, _action}, path: path} when is_binary(path) -> path
      %Tab{live_view: ^view, path: path} when is_binary(path) -> path
      _ -> nil
    end) || "/admin"
  end

  def path_for_live_view(_), do: "/admin"

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
    write_call({:update_tab, tab_id, attrs})
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
    write_call({:register_groups, groups})
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
    write_call({:update_badge, tab_id, badge})
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
    write_call({:set_attention, tab_id, attention})
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

  # Every write goes through here.
  #
  # `mix phoenix_kit.update` boots the host application with a reduced
  # supervision tree that deliberately leaves this registry out, and then runs
  # the host's own start code. A host that hides a module's admin tab the way
  # PhoenixKit 1.7 documented — a `Registry.unregister_tab/1` call at boot —
  # therefore calls into a process that is not there. That is an exit, which no
  # `rescue` catches, so the update aborts *before migrating*: the user sees a
  # crash instead of an upgrade, and the database silently stays behind.
  #
  # In update mode, with the registry genuinely absent, a write is meaningless
  # (nothing renders an admin sidebar during a migration) so it is skipped. In
  # a normal boot the call still fails loudly, because there the same symptom
  # means a real ordering bug — the host registering tabs before PhoenixKit's
  # supervisor has started.
  #
  # The supported way to hide a tab is the declarative `:hidden_admin_tabs`
  # config, which applies at registry init and therefore survives a restart.
  defp write_call(message) do
    if update_mode?() and not is_pid(Process.whereis(__MODULE__)) do
      Logger.debug(
        "[Registry] skipping #{inspect(elem_or_atom(message))} — update mode, registry not running"
      )

      :ok
    else
      GenServer.call(__MODULE__, message)
    end
  end

  defp update_mode?, do: Application.get_env(:phoenix_kit, :update_mode, false)

  defp elem_or_atom(message) when is_tuple(message), do: elem(message, 0)
  defp elem_or_atom(message), do: message

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
    write_call(:load_defaults)
  end

  @doc """
  Loads tabs from application configuration.

  Reads from `:phoenix_kit, :user_dashboard_tabs` config key.
  """
  @spec load_from_config() :: :ok
  def load_from_config do
    write_call(:load_from_config)
  end

  @doc """
  Loads admin default tabs.

  Called during initialization.
  """
  @spec load_admin_defaults() :: :ok
  def load_admin_defaults do
    write_call(:load_admin_defaults)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for tab storage
    :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])

    # Subscribe to entity lifecycle events for cache invalidation
    subscribe_to_entity_events()

    # Defer DB-dependent tab loading to handle_continue so the supervisor is not blocked.
    # Tabs from config (Application.get_env) are ready immediately; module-enabled checks
    # and permission auto-grants that query the DB happen after init returns.
    {:ok, %{namespaces: MapSet.new([:phoenix_kit, :phoenix_kit_admin])},
     {:continue, :initialize_tabs}}
  end

  @doc """
  Admin tab ids the host has hidden:

      config :phoenix_kit, hidden_admin_tabs: [:admin_locations]

  "I want this module's data but not its UI" is an ordinary need — a host may
  install `phoenix_kit_locations` purely as a data layer and never want its
  admin section.

  Applied during registry **init**, not by `unregister_tab/1`. That function
  mutates GenServer state, and the registry rebuilds from
  `AdminTabs.default_tabs/0` whenever it initialises — so a supervisor restart
  would silently resurrect the hidden tabs mid-flight, with nothing to indicate
  it had happened. Applying it at the rebuild is what makes hiding survive.

  Hiding is cosmetic: it removes the sidebar entry, not the route or the
  permission. Use permissions to control access.
  """
  @spec hidden_admin_tabs() :: [atom()]
  def hidden_admin_tabs do
    :phoenix_kit
    |> Application.get_env(:hidden_admin_tabs, [])
    |> Enum.filter(&is_atom/1)
  end

  @doc """
  Drops the tabs listed in `:hidden_admin_tabs` from `tabs`.

  Public so the filter can be tested as the pure function it is — this is the
  exact composition `load_admin_defaults_internal/0` applies to
  `AdminTabs.default_tabs/0`.
  """
  @spec apply_hidden_admin_tabs([Tab.t()]) :: [Tab.t()]
  def apply_hidden_admin_tabs(tabs) do
    case hidden_admin_tabs() do
      [] -> tabs
      hidden -> Enum.reject(tabs, &(&1.id in hidden))
    end
  end

  @doc """
  Host overrides of where admin tabs sit in the sidebar:

      config :phoenix_kit, :admin_tab_order, %{
        admin_catalogue: 120,
        admin_crm: %{priority: 125, group: :admin_main}
      }

  A value is a priority, or a map / keyword list with `:priority` and/or
  `:group`. Entries with a non-atom id or an unusable value are ignored rather
  than taking the sidebar down on boot.

  Core already orders known module tabs (`AdminTabs.module_tab_order/0`); this
  is for the host's own preference. Like `:hidden_admin_tabs` it is applied
  inside the registry — on every rebuild and to every source of admin tabs
  (defaults, host `:admin_dashboard_tabs`, legacy categories, runtime
  `register/2`) — so neither a supervisor restart nor a module's
  `load_defaults/0` brings the old order back. `update_tab/2` from a host's
  boot code has neither property.
  """
  @spec admin_tab_order() :: %{atom() => map()}
  def admin_tab_order do
    case Application.get_env(:phoenix_kit, :admin_tab_order, %{}) do
      entries when is_map(entries) or is_list(entries) ->
        Enum.reduce(entries, %{}, fn
          {id, value}, acc when is_atom(id) ->
            case tab_order_attrs(value) do
              attrs when map_size(attrs) == 0 -> acc
              attrs -> Map.put(acc, id, attrs)
            end

          _other, acc ->
            acc
        end)

      _ ->
        %{}
    end
  end

  defp tab_order_attrs(priority) when is_integer(priority), do: %{priority: priority}

  defp tab_order_attrs(value) when is_map(value) or is_list(value) do
    if is_list(value) and not Keyword.keyword?(value) do
      %{}
    else
      value
      |> Map.new()
      |> Map.take([:priority, :group])
      |> Enum.filter(fn
        {:priority, p} -> is_integer(p)
        {:group, g} -> is_atom(g)
      end)
      |> Map.new()
    end
  end

  defp tab_order_attrs(_), do: %{}

  @doc """
  Applies `admin_tab_order/0` to `tabs` (admin tabs only — a user dashboard
  tab with the same id is not touched).

  Public so the override can be tested as the pure function it is — this is
  the exact step `load_admin_defaults_internal/0` applies after
  `apply_hidden_admin_tabs/1`.
  """
  @spec apply_admin_tab_order([Tab.t()]) :: [Tab.t()]
  def apply_admin_tab_order(tabs) do
    case admin_tab_order() do
      order when map_size(order) == 0 -> tabs
      order -> Enum.map(tabs, &order_admin_tab(&1, order))
    end
  end

  defp order_admin_tab(%Tab{level: :admin, id: id} = tab, order) do
    case Map.fetch(order, id) do
      {:ok, attrs} -> struct(tab, attrs)
      :error -> tab
    end
  end

  defp order_admin_tab(tab, _order), do: tab

  @impl true
  def handle_continue(:initialize_tabs, state) do
    # Load user dashboard defaults (includes enabled_user_dashboard_tabs → DB queries)
    load_defaults_internal()
    load_from_config_internal()

    # Load admin dashboard defaults (includes auto_register_custom_permission → DB)
    load_admin_defaults_internal()
    load_admin_from_config_internal()

    {:noreply, state}
  end

  @doc """
  Whether `tab` is named in `:hidden_admin_tabs`. Admin tabs only — a user
  dashboard tab of the same id is not affected.

  Applies to every source of admin tabs: the kit's and modules' defaults,
  the host's `:admin_dashboard_tabs` (and legacy categories), and tabs
  registered at runtime. Hiding drops the sidebar entry only; the permission
  mapping is still registered, so the route stays guarded exactly as before.
  """
  @spec hidden_admin_tab?(Tab.t()) :: boolean()
  def hidden_admin_tab?(%Tab{level: :admin, id: id}), do: id in hidden_admin_tabs()
  def hidden_admin_tab?(_tab), do: false

  @impl true
  def handle_call({:register, namespace, tabs}, _from, state) do
    tabs
    |> apply_admin_tab_order()
    |> Enum.each(fn tab ->
      unless hidden_admin_tab?(tab) do
        :ets.insert(@ets_table, {{:tab, tab.id}, tab})
        :ets.insert(@ets_table, {{:namespace, namespace, tab.id}, true})
      end

      # Auto-register custom permission keys for admin tabs. Thread
      # `auto_grant_admin` (default true) so a host registering a SENSITIVE tab
      # with `auto_grant_admin: false` isn't silently auto-granted to Admin —
      # the flag lives on the Tab struct, so this programmatic path preserves it
      # exactly like the `:admin_dashboard_tabs` config path.
      if tab.level == :admin and is_binary(tab.permission) do
        auto_register_custom_permission(%{
          permission: tab.permission,
          label: tab.label,
          icon: tab.icon,
          live_view: tab.live_view,
          # Map.get (not tab.auto_grant_admin) so a Tab struct persisted before
          # this field existed — possible across a hot code upgrade — defaults to
          # true instead of raising KeyError.
          auto_grant_admin: Map.get(tab, :auto_grant_admin, true)
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
  def handle_info({event, _entity_uuid}, state)
      when event in [:entity_created, :entity_updated, :entity_deleted] do
    if Code.ensure_loaded?(PhoenixKitEntities) and
         function_exported?(PhoenixKitEntities, :invalidate_entities_cache, 0) do
      PhoenixKitEntities.invalidate_entities_cache()
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

  defp maybe_filter_visibility(tabs, _scope, true), do: tabs

  # No scope to evaluate visibility functions against — those stay — but
  # hard-hidden tabs (visible: false, or parameterized paths) must not leak
  # just because the caller had no scope. They used to.
  defp maybe_filter_visibility(tabs, nil, false) do
    Enum.reject(tabs, &Tab.hard_hidden?/1)
  end

  defp maybe_filter_visibility(tabs, scope, false) do
    Enum.filter(tabs, &Tab.visible?(&1, scope))
  end

  # Ties are broken by id: `all_tabs/0` reads an ETS set, whose order is not
  # stable across restarts, so two tabs with one priority used to swap places
  # from boot to boot.
  @doc false
  def sort_tabs(tabs) do
    Enum.sort_by(tabs, &{&1.priority, to_string(&1.id)})
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

    # Default PhoenixKit tabs (relative paths, resolved to /dashboard/*)
    defaults =
      [
        Tab.new!(
          id: :dashboard_home,
          label: "Dashboard",
          icon: "hero-home",
          path: "",
          priority: 100,
          match: :exact,
          group: :main,
          gettext_backend: PhoenixKitWeb.Gettext
        ),
        Tab.new!(
          id: :dashboard_settings,
          label: "Settings",
          icon: "hero-cog-6-tooth",
          path: "settings",
          priority: 900,
          match: :prefix,
          group: :account,
          gettext_backend: PhoenixKitWeb.Gettext
        )
      ]
      |> Enum.map(&Tab.resolve_path(&1, :user_dashboard))

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
              tab = Tab.resolve_path(tab, :user_dashboard)
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
            tab = Tab.resolve_path(tab, :user_dashboard)
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
    |> Enum.map(&Tab.resolve_path(&1, :user_dashboard))
  rescue
    _ -> []
  end

  # --- Admin Tab Loading ---

  defp load_admin_defaults_internal do
    clear_namespace_tabs(:phoenix_kit_admin)

    tabs = AdminTabs.default_tabs() |> apply_hidden_admin_tabs() |> apply_admin_tab_order()
    groups = AdminTabs.default_groups()

    Enum.each(tabs, fn tab ->
      :ets.insert(@ets_table, {{:tab, tab.id}, tab})
      :ets.insert(@ets_table, {{:namespace, :phoenix_kit_admin, tab.id}, true})

      # Cache live_view → permission mapping for module tabs so auth can enforce permissions
      if tab.level == :admin and is_binary(tab.permission) do
        auto_register_custom_permission(%{
          permission: tab.permission,
          label: tab.label,
          icon: tab.icon,
          live_view: tab.live_view
        })
      end
    end)

    # Merge admin groups with existing groups
    existing_groups = get_groups()
    merged = merge_groups(existing_groups, groups)
    :ets.insert(@ets_table, {:groups, merged})
  end

  defp load_admin_from_config_internal do
    # Load legacy admin_dashboard_categories config and convert to admin-level tabs
    load_legacy_admin_categories()

    # Load :admin_dashboard_tabs config (highest precedence)
    case Application.get_env(:phoenix_kit, :admin_dashboard_tabs) do
      nil ->
        :ok

      tabs when is_list(tabs) ->
        Enum.each(tabs, fn tab_config ->
          # Auto-set level to :admin for admin dashboard tabs
          tab_config = Map.put_new(tab_config, :level, :admin)

          case Tab.new(tab_config) do
            {:ok, tab} ->
              insert_config_admin_tab(Tab.resolve_path(tab, :admin))

              # Auto-register custom permission key and cache view mapping
              auto_register_custom_permission(tab_config)

            {:error, _reason} ->
              :ok
          end
        end)
    end
  end

  defp insert_config_admin_tab(tab) do
    [tab] = apply_admin_tab_order([tab])

    unless hidden_admin_tab?(tab) do
      :ets.insert(@ets_table, {{:tab, tab.id}, tab})
      :ets.insert(@ets_table, {{:namespace, :admin_config, tab.id}, true})
    end
  end

  # Registers a custom permission key derived from a tab config map.
  # Only registers if the permission key is NOT one of the built-in keys.
  # Also caches live_view → permission mapping for auth enforcement.
  # Exposed as `@doc false def` (rather than `defp`) so unit tests can drive a
  # single tab config through registration without standing up the GenServer.
  # Not part of the public API.
  @doc false
  def auto_register_custom_permission(%{permission: perm} = tab_config)
      when is_binary(perm) or is_atom(perm) do
    perm = to_string(perm)

    # Integration keys are core-managed built-ins, NOT custom keys — include
    # them so a core tab carrying `integrations`/`integrations_system` isn't
    # re-registered via `register_custom_key/2` (which would double-list it in
    # `custom_keys()`). Auto-grant for these still flows through
    # `auto_grant_to_admin_roles/1`, whose opt-in guard keeps the PERSONAL
    # `integrations` key from ever reaching Admin automatically.
    builtin_keys =
      Permissions.core_section_keys() ++
        Permissions.integration_keys() ++ Permissions.feature_module_keys()

    # A tab may be gated on a SUB-permission ("shop.manage_settings"). Those
    # are declared through `permission_metadata/0` and stored as composed
    # dotted keys, which `register_custom_key/2` rejects outright — the raise
    # then skipped the view→permission caching below, so a module that gated
    # its settings page on a sub-key lost core's automatic view gate and
    # warned on every boot.
    unless perm == "" or perm in builtin_keys or Permissions.parent_key(perm) do
      # Forward the tab's gettext config so the permissions matrix renders
      # the key's label in the same locale the sidebar tab already does.
      Permissions.register_custom_key(perm,
        label: Map.get(tab_config, :label),
        icon: Map.get(tab_config, :icon),
        description: Map.get(tab_config, :description),
        gettext_backend: Map.get(tab_config, :gettext_backend),
        gettext_domain: Map.get(tab_config, :gettext_domain),
        auto_grant_admin: Map.get(tab_config, :auto_grant_admin, true),
        # Tabs sharing a permission re-register it once per tab and on every
        # reload; that is expected, so it does not warn (see
        # `Permissions.register_custom_key/2`).
        from_admin_tab: true
      )
    end

    # Auto-grant feature module keys to Admin role (register_custom_key
    # handles this for custom keys, but feature module keys skip that path)
    if perm != "" and perm in builtin_keys do
      Permissions.auto_grant_to_admin_roles(perm)
    end

    cache_view_permission(perm, Map.get(tab_config, :live_view))
  rescue
    error ->
      Logger.warning(
        "[Registry] Failed to register custom permission #{inspect(perm)}: #{Exception.message(error)}"
      )

      :ok
  end

  def auto_register_custom_permission(_), do: :ok

  # Caches a tab's live_view → permission mapping, regardless of key type.
  # Keyed by `{view_module, action}` when the tab names one — two tabs naming
  # the SAME module on different actions (e.g. a landing redirector and the
  # page it redirects to) must not collide on one shared module-only entry,
  # which is what let the later registration silently win over the earlier
  # one regardless of which action a visitor actually opened (#844). A tab
  # that names no action (host tabs predating this, or a module that never
  # disambiguates) falls back to the bare module key, unchanged.
  defp cache_view_permission("", _live_view), do: :ok

  # `{Mod, nil}` is the bare-module shape spelled as a tuple — key it the
  # same way, or an `:index` lookup would miss both the exact key and the
  # module-only fallback.
  defp cache_view_permission(perm, {view_module, nil}) when is_atom(view_module) do
    cache_view_permission(perm, view_module)
  end

  defp cache_view_permission(perm, {view_module, action})
       when is_atom(view_module) and is_atom(action) do
    Permissions.cache_custom_view_permission({view_module, action}, perm)
  end

  defp cache_view_permission(perm, view_module)
       when is_atom(view_module) and not is_nil(view_module) do
    Permissions.cache_custom_view_permission(view_module, perm)
  end

  defp cache_view_permission(_perm, _live_view), do: :ok

  # Subscribe to entity definition lifecycle events for sidebar cache invalidation.
  # Guarded since the Entities module is optional.
  defp subscribe_to_entity_events do
    events_mod = PhoenixKitEntities.Events

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

  # Load legacy admin_dashboard_categories config and convert to admin-level Tab structs
  defp load_legacy_admin_categories do
    alias PhoenixKit.Config.AdminDashboardCategories

    categories = AdminDashboardCategories.get_categories()

    if categories != [] do
      Logger.warning(
        "[PhoenixKit] Legacy :admin_dashboard_categories config detected. " <>
          "This format is deprecated. Please migrate to :admin_dashboard_tabs format."
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

        parent =
          %Tab{
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
          |> Tab.resolve_path(:admin)

        unless hidden_admin_tab?(parent) do
          :ets.insert(@ets_table, {{:tab, parent.id}, parent})
          :ets.insert(@ets_table, {{:namespace, :admin_legacy, parent.id}, true})
        end

        # Create child tabs from subsections
        category.subsections
        |> Enum.with_index()
        |> Enum.each(fn {subsection, sub_idx} ->
          create_legacy_child_tab(
            subsection,
            cat_idx,
            sub_idx,
            cat_id
          )
        end)
      end)
    end
  end

  # Creates a child tab from a legacy category subsection.
  defp create_legacy_child_tab(subsection, cat_idx, sub_idx, parent_id) do
    child_id = :"admin_custom_#{cat_idx}_#{sub_idx}"

    child = %Tab{
      id: child_id,
      label: subsection.title,
      icon: subsection.icon || "hero-document-text",
      path: subsection.url,
      priority: 701 + cat_idx * 10 + sub_idx,
      level: :admin,
      match: :prefix,
      parent: parent_id
    }

    # Auto-infer live_view module from URL path
    child = maybe_add_live_view(child, subsection.url)

    child = Tab.resolve_path(child, :admin)

    unless hidden_admin_tab?(child) do
      :ets.insert(@ets_table, {{:tab, child.id}, child})
      :ets.insert(@ets_table, {{:namespace, :admin_legacy, child.id}, true})
    end
  end

  # Adds live_view to tab if a corresponding module can be inferred from the URL.
  defp maybe_add_live_view(tab, url) do
    case infer_live_view_from_url(url) do
      {:ok, live_view} -> %{tab | live_view: {live_view, :index}}
      :error -> tab
    end
  end

  # Infers LiveView module name from admin URL path.
  # Pattern: /admin/category1/section1 -> AppWeb.PhoenixKit.Live.Admin.Category1.Section1
  defp infer_live_view_from_url("/admin/" <> path_segments) do
    app_base = Routes.phoenix_kit_app_base()

    path_segments
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Macro.camelize/1)
    |> case do
      [] ->
        :error

      segments ->
        module_name =
          Module.concat(
            [
              app_base,
              "PhoenixKit",
              "Live",
              "Admin"
            ] ++ segments
          )

        # Verify module exists before returning
        case Code.ensure_loaded(module_name) do
          {:module, _} -> {:ok, module_name}
          {:error, _} -> :error
        end
    end
  end

  defp infer_live_view_from_url(_), do: :error
end
