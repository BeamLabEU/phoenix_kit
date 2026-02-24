defmodule PhoenixKit.ModuleRegistry do
  @moduledoc """
  Runtime registry of all PhoenixKit modules (internal and external).

  External modules are auto-discovered from beam files via `PhoenixKit.ModuleDiscovery`.
  Any dep that depends on `:phoenix_kit` and uses `use PhoenixKit.Module` is found
  automatically — no config line needed.

  ## External Module Registration

  External hex packages are auto-discovered. Just add the dep:

      {:phoenix_kit_hello_world, "~> 0.1.0"}

  For explicit registration (backwards compatible):

      config :phoenix_kit, :modules, [PhoenixKitHelloWorld]

  ## Runtime Registration

      PhoenixKit.ModuleRegistry.register(MyModule)
      PhoenixKit.ModuleRegistry.unregister(MyModule)

  ## Query API

      ModuleRegistry.all_modules()           # All registered module atoms
      ModuleRegistry.enabled_modules()       # Only currently enabled
      ModuleRegistry.all_admin_tabs()        # Collect admin tabs from all modules
      ModuleRegistry.all_settings_tabs()     # Collect settings tabs
      ModuleRegistry.all_user_dashboard_tabs() # Collect user dashboard tabs
      ModuleRegistry.all_children()          # Collect supervisor child specs
      ModuleRegistry.all_permission_metadata() # Collect permission metadata
      ModuleRegistry.feature_enabled_checks()  # Build {mod, :enabled?} map
      ModuleRegistry.get_by_key("tickets")   # Find module by key
  """

  use GenServer

  require Logger

  @pterm_key {PhoenixKit, :registered_modules}

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a module that implements PhoenixKit.Module behaviour."
  @spec register(module()) :: :ok
  def register(module) when is_atom(module) do
    GenServer.call(__MODULE__, {:register, module})
  end

  @doc "Unregister a module."
  @spec unregister(module()) :: :ok
  def unregister(module) when is_atom(module) do
    GenServer.call(__MODULE__, {:unregister, module})
  end

  @doc "Returns all registered module atoms."
  @spec all_modules() :: [module()]
  def all_modules do
    :persistent_term.get(@pterm_key, [])
  end

  @doc "Returns all registered modules that are currently enabled."
  @spec enabled_modules() :: [module()]
  def enabled_modules do
    Enum.filter(all_modules(), fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :enabled?, 0) and
        safe_enabled?(mod)
    end)
  end

  defp safe_enabled?(mod) do
    mod.enabled?()
  rescue
    error ->
      Logger.warning(
        "[ModuleRegistry] #{inspect(mod)}.enabled?/0 failed: #{Exception.message(error)}"
      )

      false
  end

  @doc "Collect all admin tabs from all registered modules."
  @spec all_admin_tabs() :: [PhoenixKit.Dashboard.Tab.t()]
  def all_admin_tabs do
    all_modules()
    |> Enum.flat_map(&safe_call(&1, :admin_tabs, []))
  end

  @doc "Collect all settings tabs from all registered modules."
  @spec all_settings_tabs() :: [PhoenixKit.Dashboard.Tab.t()]
  def all_settings_tabs do
    all_modules()
    |> Enum.flat_map(&safe_call(&1, :settings_tabs, []))
  end

  @doc "Collect all user dashboard tabs from all registered modules."
  @spec all_user_dashboard_tabs() :: [PhoenixKit.Dashboard.Tab.t()]
  def all_user_dashboard_tabs do
    all_modules()
    |> Enum.flat_map(&safe_call(&1, :user_dashboard_tabs, []))
  end

  @doc "Collect all supervisor child specs from all registered modules."
  @spec all_children() :: [Supervisor.child_spec()]
  def all_children do
    all_modules()
    |> Enum.flat_map(&safe_call(&1, :children, []))
  end

  @doc "Collect permission metadata from all registered modules."
  @spec all_permission_metadata() :: [PhoenixKit.Module.permission_meta()]
  def all_permission_metadata do
    all_modules()
    |> Enum.map(&safe_call(&1, :permission_metadata, nil))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Build a feature_enabled_checks map from registered modules.

  Returns `%{"tickets" => {PhoenixKit.Modules.Tickets, :enabled?}, ...}`
  """
  @spec feature_enabled_checks() :: %{String.t() => {module(), atom()}}
  def feature_enabled_checks do
    all_modules()
    |> Enum.reduce(%{}, fn mod, acc ->
      case safe_call(mod, :permission_metadata, nil) do
        %{key: key} -> Map.put(acc, key, {mod, :enabled?})
        _ -> acc
      end
    end)
  end

  @doc "Collect route modules from all registered modules."
  @spec all_route_modules() :: [module()]
  def all_route_modules do
    all_modules()
    |> Enum.map(&safe_call(&1, :route_module, nil))
    |> Enum.reject(&is_nil/1)
  end

  @doc "Find a registered module by its key string."
  @spec get_by_key(String.t()) :: module() | nil
  def get_by_key(key) when is_binary(key) do
    Enum.find(all_modules(), fn mod ->
      safe_call(mod, :module_key, nil) == key
    end)
  end

  @doc "Returns all feature module key strings from registered modules."
  @spec all_feature_keys() :: [String.t()]
  def all_feature_keys do
    all_permission_metadata()
    |> Enum.map(& &1.key)
    |> Enum.sort()
  end

  @doc "Returns permission labels map from registered modules."
  @spec permission_labels() :: %{String.t() => String.t()}
  def permission_labels do
    all_permission_metadata()
    |> Map.new(fn %{key: key, label: label} -> {key, label} end)
  end

  @doc "Returns permission icons map from registered modules."
  @spec permission_icons() :: %{String.t() => String.t()}
  def permission_icons do
    all_permission_metadata()
    |> Map.new(fn %{key: key, icon: icon} -> {key, icon} end)
  end

  @doc "Returns permission descriptions map from registered modules."
  @spec permission_descriptions() :: %{String.t() => String.t()}
  def permission_descriptions do
    all_permission_metadata()
    |> Map.new(fn %{key: key, description: desc} -> {key, desc} end)
  end

  @doc "Check if the registry has been initialized."
  @spec initialized?() :: boolean()
  def initialized? do
    :persistent_term.get(@pterm_key, :not_initialized) != :not_initialized
  end

  @doc """
  Collect supervisor child specs from the static module list.

  This does NOT require the GenServer to be running, making it safe to call
  from the PhoenixKit.Supervisor init (before the registry starts).
  """
  @spec static_children() :: [Supervisor.child_spec()]
  def static_children do
    load_modules()
    |> Enum.flat_map(fn mod ->
      if Code.ensure_loaded?(mod) and function_exported?(mod, :children, 0) do
        mod.children()
      else
        []
      end
    end)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    modules = load_modules()
    :persistent_term.put(@pterm_key, modules)
    {:ok, %{modules: modules}}
  end

  @impl true
  def handle_call({:register, module}, _from, %{modules: modules} = state) do
    if module in modules do
      {:reply, :ok, state}
    else
      updated = modules ++ [module]
      :persistent_term.put(@pterm_key, updated)
      {:reply, :ok, %{state | modules: updated}}
    end
  end

  @impl true
  def handle_call({:unregister, module}, _from, %{modules: modules} = state) do
    updated = List.delete(modules, module)
    :persistent_term.put(@pterm_key, updated)
    {:reply, :ok, %{state | modules: updated}}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp load_modules do
    internal = internal_modules()
    external = PhoenixKit.ModuleDiscovery.discover_external_modules()
    (internal ++ external) |> Enum.uniq()
  end

  # All bundled PhoenixKit modules. This is the ONE remaining enumeration
  # of internal modules. When a module is extracted to its own hex package,
  # remove it from this list and add it to :modules config instead.
  defp internal_modules do
    [
      PhoenixKit.Modules.AI,
      PhoenixKit.Modules.Billing,
      PhoenixKit.Modules.Comments,
      PhoenixKit.Modules.Connections,
      PhoenixKit.Modules.DB,
      PhoenixKit.Modules.Emails,
      PhoenixKit.Modules.Entities,
      PhoenixKit.Modules.Languages,
      PhoenixKit.Modules.Legal,
      PhoenixKit.Modules.Maintenance,
      PhoenixKit.Modules.Pages,
      PhoenixKit.Modules.Posts,
      PhoenixKit.Modules.Publishing,
      PhoenixKit.Modules.Referrals,
      PhoenixKit.Modules.SEO,
      PhoenixKit.Modules.Shop,
      PhoenixKit.Modules.Sitemap,
      PhoenixKit.Modules.Storage,
      PhoenixKit.Modules.Sync,
      PhoenixKit.Modules.Tickets,
      PhoenixKit.Jobs
    ]
  end

  # Safely call an optional callback on a module, returning the default
  # if the module isn't loaded or doesn't export the function.
  @spec safe_call(module(), atom(), term()) :: term()
  defp safe_call(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  rescue
    error ->
      Logger.warning(
        "[ModuleRegistry] #{inspect(mod)}.#{fun}/0 failed: #{Exception.message(error)}"
      )

      default
  end
end
