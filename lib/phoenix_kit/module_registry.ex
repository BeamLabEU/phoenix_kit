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

  @doc """
  Collect all admin tabs from all registered modules.

  Note: iterates all modules and calls `admin_tabs/0` on each call.
  For cached access in rendering paths, use `PhoenixKit.Dashboard.Registry.get_admin_tabs/0`.
  """
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
        try do
          mod.children()
        rescue
          error ->
            Logger.warning(
              "[ModuleRegistry] #{inspect(mod)}.children/0 failed: #{Exception.message(error)}"
            )

            []
        end
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
    validate_modules(modules)
    :persistent_term.put(@pterm_key, modules)
    {:ok, %{modules: modules}}
  end

  @impl true
  def handle_call({:register, module}, _from, %{modules: modules} = state) do
    if module in modules do
      {:reply, :ok, state}
    else
      validate_module(module, modules)
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

  # Validate all modules at startup — check for duplicate keys, permission mismatches,
  # duplicate tab IDs, and tabs missing permission fields.
  defp validate_modules(modules) do
    modules
    |> Enum.reduce(%{}, fn mod, acc ->
      key = safe_call(mod, :module_key, nil)
      if is_nil(key), do: acc, else: check_duplicate_key(mod, key, acc)
    end)
    |> then(fn _seen -> :ok end)

    Enum.each(modules, &validate_permission_key_match/1)

    all_tabs = Enum.flat_map(modules, &safe_call(&1, :admin_tabs, []))
    warn_duplicate_tab_ids(all_tabs)
    warn_tabs_missing_permission(modules)
  end

  # Validate a single module being registered at runtime.
  defp validate_module(module, existing_modules) do
    key = safe_call(module, :module_key, nil)

    if key do
      existing_keys =
        existing_modules
        |> Enum.map(&safe_call(&1, :module_key, nil))
        |> Enum.reject(&is_nil/1)

      if key in existing_keys do
        Logger.warning(
          "[ModuleRegistry] Duplicate module_key #{inspect(key)} — " <>
            "#{inspect(module)} conflicts with an existing module. " <>
            "One will shadow the other in get_by_key/1 lookups."
        )
      end
    end

    validate_permission_key_match(module)
  end

  defp check_duplicate_key(mod, key, seen) do
    case Map.get(seen, key) do
      nil ->
        Map.put(seen, key, mod)

      existing_mod ->
        Logger.warning(
          "[ModuleRegistry] Duplicate module_key #{inspect(key)} — " <>
            "#{inspect(mod)} and #{inspect(existing_mod)} both declare it. " <>
            "One will shadow the other in get_by_key/1 lookups."
        )

        seen
    end
  end

  defp validate_permission_key_match(mod) do
    with key when is_binary(key) <- safe_call(mod, :module_key, nil),
         %{key: perm_key} <- safe_call(mod, :permission_metadata, nil),
         true <- perm_key != key do
      Logger.warning(
        "[ModuleRegistry] #{inspect(mod)} permission_metadata key #{inspect(perm_key)} " <>
          "does not match module_key #{inspect(key)}. " <>
          "This will cause permission checks and toggle events to use different keys."
      )
    end
  end

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

  defp warn_duplicate_tab_ids(tabs) do
    tabs
    |> Enum.map(& &1.id)
    |> Enum.frequencies()
    |> Enum.each(fn
      {id, count} when count > 1 ->
        Logger.warning(
          "[ModuleRegistry] Duplicate admin tab ID #{inspect(id)} found #{count} times. " <>
            "This will cause unpredictable sidebar behavior."
        )

      _ ->
        :ok
    end)
  end

  # Warn about admin tabs that have permission_metadata but no :permission field on tabs.
  # Custom roles will see the tab in the sidebar but get denied on click.
  defp warn_tabs_missing_permission(modules) do
    for mod <- modules,
        perm_meta = safe_call(mod, :permission_metadata, nil),
        perm_meta != nil,
        tab <- safe_call(mod, :admin_tabs, []),
        is_nil(Map.get(tab, :permission)) do
      Logger.warning(
        "[ModuleRegistry] #{inspect(mod)} tab #{inspect(tab.id)} has no :permission field. " <>
          "Custom roles will see the tab but get denied on click. " <>
          "Add permission: #{inspect(perm_meta.key)} to the tab definition."
      )
    end
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
        "[ModuleRegistry] #{inspect(mod)}.#{fun}/0 failed: #{Exception.message(error)}. " <>
          "Check that all required fields are valid (e.g. Tab paths must start with \"/\")."
      )

      default
  end
end
