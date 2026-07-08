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
      ModuleRegistry.get_module_key_for_namespace("PhoenixKitTickets")
                                             # Resolve top-level namespace → key
  """

  use GenServer

  alias PhoenixKit.Dashboard.Tab

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

  @doc """
  Rescan beam files and absorb any external modules that weren't known
  at registry init.

  Returns `{:ok, new_modules}` — the freshly-absorbed module atoms (often
  `[]` after the first call). Safe to call repeatedly.

  Intended use: parent app calls this from `Application.start/2` after
  `Supervisor.start_link/2` so late-loading `:phoenix_kit_<x>` deps
  whose beams are only available after PhoenixKit's own supervision tree
  is up get picked up deterministically — without timer-based polling.
  `mix phoenix_kit.install` and `mix phoenix_kit.update` wire this call
  in automatically; existing apps can call it manually.

  Also useful in dev for hot-reload recovery after recompiling a module
  package, or in tests that dynamically load fixture modules.
  """
  @spec rescan() :: {:ok, [module()]}
  def rescan do
    GenServer.call(__MODULE__, :rescan)
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
    |> Enum.map(&Tab.resolve_path(&1, :admin))
  end

  @doc "Collect all settings tabs from all registered modules."
  @spec all_settings_tabs() :: [PhoenixKit.Dashboard.Tab.t()]
  def all_settings_tabs do
    all_modules()
    |> Enum.flat_map(&safe_call(&1, :settings_tabs, []))
    |> Enum.map(&Tab.resolve_path(&1, :settings))
  end

  @doc "Collect all user dashboard tabs from all registered modules."
  @spec all_user_dashboard_tabs() :: [PhoenixKit.Dashboard.Tab.t()]
  def all_user_dashboard_tabs do
    all_modules()
    |> Enum.flat_map(&safe_call(&1, :user_dashboard_tabs, []))
    |> Enum.map(&Tab.resolve_path(&1, :user_dashboard))
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

  Returns `%{"storage" => {PhoenixKit.Modules.Storage, :enabled?}, ...}`
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

  @doc """
  Collect sitemap source modules contributed by all **enabled** modules.

  Each entry implements `PhoenixKit.Modules.Sitemap.Sources.Source`. The
  sitemap `Generator` appends these to its base source list (deduplicated)
  so module-owned content appears in the sitemap with no host config.

  Iterates `enabled_modules/0`, so a disabled module contributes nothing — even
  in flat-sitemap mode, where the `Generator` deliberately force-collects every
  source and bypasses each source's own `enabled?/0` (`force: true`, see
  `Sources.Source.safe_collect/2` and `Generator` flat-mode generation). Gating
  at the module level here keeps the "disabled module emits no URLs" guarantee
  in both modes. A contributed source's own `enabled?/0` remains a secondary
  gate in index mode (see `Generator.generate_module/2`).
  """
  @spec all_sitemap_sources() :: [module()]
  def all_sitemap_sources do
    enabled_modules()
    |> Enum.flat_map(&safe_call(&1, :sitemap_sources, []))
    |> Enum.uniq()
  end

  @doc """
  Collect top-level route path segments reserved by all installed modules.

  Each entry is a literal path segment (no slashes, e.g. `"legal"`) a module
  owns for its own LiveViews/controllers. A dispatcher that routes requests
  based on database-driven path segments (e.g. Publishing's group catch-all)
  should treat any segment in this list as NOT its own, even if it happens to
  have matching data, so it doesn't swallow a route another module owns.
  Declaring a prefix is passive — it changes nothing unless a dispatcher
  actively consults this function.

  Iterates `all_modules/0`, **not** `enabled_modules/0` (unlike
  `all_sitemap_sources/0`): the route this guards against is normally
  compiled into the host's router (e.g. `live "/legal", LegalLive`), which
  exists independent of the owning module's runtime enabled/disabled
  Settings toggle. Gating on `enabled_modules/0` would drop the reservation
  the moment a module is disabled while its data (and the host's compiled
  route) still exist, reopening the exact hijack this is meant to prevent
  for as long as the module stays disabled.

  Each module's returned segments are trimmed of leading/trailing slashes
  and non-list/non-string returns are dropped, so a malformed
  `reserved_route_prefixes/0` implementation (e.g. returning `"/legal"` or a
  bare string instead of a list) can't silently defeat the reservation or
  crash this per-request-hot-path aggregation.
  """
  @spec all_reserved_route_prefixes() :: [String.t()]
  def all_reserved_route_prefixes do
    all_modules()
    |> Enum.flat_map(fn mod ->
      mod
      |> safe_call(:reserved_route_prefixes, [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
    end)
    |> Enum.map(&String.trim(&1, "/"))
    |> Enum.uniq()
  end

  @doc """
  Collect modules that have versioned migrations.

  Returns a list of `{module_name, migration_module}` tuples for all registered
  modules that implement `migration_module/0` and return a non-nil value.
  """
  @spec modules_with_migrations() :: [{String.t(), module()}]
  def modules_with_migrations do
    all_modules()
    |> Enum.flat_map(fn mod ->
      case safe_call(mod, :migration_module, nil) do
        nil -> []
        migration_mod -> [{safe_call(mod, :module_name, inspect(mod)), migration_mod}]
      end
    end)
  end

  @doc "Find a registered module by its key string."
  @spec get_by_key(String.t()) :: module() | nil
  def get_by_key(key) when is_binary(key) do
    Enum.find(all_modules(), fn mod ->
      safe_call(mod, :module_key, nil) == key
    end)
  end

  @doc """
  Find a registered module's key by matching a top-level Elixir namespace.

  Used by the admin permission layer to resolve a plugin LiveView's namespace
  (e.g. `"PhoenixKitEntities"` from `PhoenixKitEntities.Web.Entities`) to the
  plugin's permission key (e.g. `"entities"`).

  Returns the key string or `nil` when no registered module matches.
  """
  @spec get_module_key_for_namespace(String.t()) :: String.t() | nil
  def get_module_key_for_namespace(top_namespace) when is_binary(top_namespace) do
    Enum.find_value(all_modules(), fn mod ->
      with [^top_namespace] <- Module.split(mod),
           key when is_binary(key) <- safe_call(mod, :module_key, nil) do
        key
      else
        _ -> nil
      end
    end)
  end

  @doc """
  Returns dependency warnings for the Modules page.

  Each warning is a map:
    %{module: module(), module_name: String.t(), requires_key: String.t()}

  Called on Modules page render — computes live (not hot path).
  """
  @spec dependency_warnings() :: [map()]
  def dependency_warnings do
    enabled_keys =
      enabled_modules()
      |> Enum.map(&safe_call(&1, :module_key, nil))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    all_modules()
    |> Enum.filter(&safe_enabled?/1)
    |> Enum.flat_map(fn mod ->
      required = safe_call(mod, :required_modules, [])
      missing = Enum.reject(required, &MapSet.member?(enabled_keys, &1))

      Enum.map(missing, fn req_key ->
        %{
          module: mod,
          module_name: safe_call(mod, :module_name, inspect(mod)),
          requires_key: req_key
        }
      end)
    end)
  end

  @doc """
  Returns known external PhoenixKit packages that are not currently installed.

  Used by the admin Modules page to inform users about available packages
  they can add as dependencies.
  """
  @spec not_installed_packages() :: [map()]
  def not_installed_packages do
    installed_otp_apps =
      PhoenixKit.ModuleDiscovery.discover_external_modules()
      |> Enum.map(&Application.get_application/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new(&Atom.to_string/1)

    known_external_packages()
    |> Enum.reject(&MapSet.member?(installed_otp_apps, &1.package))
  end

  @doc "Returns all feature module key strings from registered modules."
  @spec all_feature_keys() :: [String.t()]
  def all_feature_keys do
    all_permission_metadata()
    |> Enum.map(& &1.key)
    |> Enum.sort()
  end

  @valid_sub_key_pattern ~r/^[a-z][a-z0-9_]*$/
  @max_sub_key_length 50

  @doc """
  Returns the sub-permissions declared by registered modules, keyed by the
  parent module key. Each entry carries the COMPOSED dotted key
  (`"calendar.view_others"`) plus its label and description.

  Malformed declarations (bad key format, missing fields, key over
  #{@max_sub_key_length} chars, duplicate keys within one module) are dropped
  with a logged warning rather than raising — a broken module must not take
  down permission resolution for everyone else.
  """
  @spec sub_permission_map() :: %{String.t() => [map()]}
  def sub_permission_map do
    all_permission_metadata()
    |> Enum.reduce(%{}, fn meta, acc ->
      case valid_sub_permissions(meta) do
        [] -> acc
        subs -> Map.put(acc, meta.key, subs)
      end
    end)
  end

  defp valid_sub_permissions(%{key: base, sub_permissions: subs}) when is_list(subs) do
    subs
    |> Enum.filter(&valid_sub_permission?(base, &1))
    |> Enum.uniq_by(& &1.key)
    |> Enum.map(fn sub ->
      %{
        key: "#{base}.#{sub.key}",
        label: sub.label,
        description: Map.get(sub, :description, "")
      }
    end)
  end

  defp valid_sub_permissions(_meta), do: []

  defp valid_sub_permission?(base, %{key: key, label: label})
       when is_binary(key) and is_binary(label) do
    cond do
      not Regex.match?(@valid_sub_key_pattern, key) ->
        Logger.warning(
          "[ModuleRegistry] Dropping sub-permission #{inspect(key)} of #{inspect(base)}: " <>
            "key must match ~r/^[a-z][a-z0-9_]*$/"
        )

        false

      String.length(key) > @max_sub_key_length ->
        Logger.warning(
          "[ModuleRegistry] Dropping sub-permission #{inspect(key)} of #{inspect(base)}: " <>
            "key exceeds max length of #{@max_sub_key_length}"
        )

        false

      true ->
        true
    end
  end

  defp valid_sub_permission?(base, sub) do
    Logger.warning(
      "[ModuleRegistry] Dropping malformed sub-permission #{inspect(sub)} of #{inspect(base)}: " <>
        "expected %{key: binary, label: binary, description: binary}"
    )

    false
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

  def handle_call({:unregister, module}, _from, %{modules: modules} = state) do
    updated = List.delete(modules, module)
    :persistent_term.put(@pterm_key, updated)
    {:reply, :ok, %{state | modules: updated}}
  end

  def handle_call(:rescan, _from, %{modules: known} = state) do
    current = load_modules()

    case current -- known do
      [] ->
        {:reply, {:ok, []}, state}

      new_modules ->
        Enum.each(new_modules, &validate_module(&1, known))
        updated = known ++ new_modules
        :persistent_term.put(@pterm_key, updated)

        Logger.info(
          "[ModuleRegistry] Late-discovered #{length(new_modules)} module(s): " <>
            inspect(new_modules)
        )

        {:reply, {:ok, new_modules}, %{state | modules: updated}}
    end
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
    validate_module_dependencies(modules)
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
      PhoenixKit.Modules.Languages,
      PhoenixKit.Modules.Maintenance,
      PhoenixKit.Modules.SEO,
      PhoenixKit.Modules.Sitemap,
      PhoenixKit.Modules.Storage,
      PhoenixKit.Jobs,
      PhoenixKit.Notifications
    ]
  end

  @doc """
  Returns the full catalog of known external PhoenixKit packages.

  Fetches live from Hex.pm with a 10-minute in-memory cache.
  Merged with any entries from `config :phoenix_kit, extra_known_packages: [...]`.
  Config entries take precedence over Hex entries when the `package` field collides.
  """
  @spec known_external_packages() :: [map()]
  def known_external_packages do
    PhoenixKit.KnownPackages.list()
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

  defp validate_module_dependencies(modules) do
    all_keys =
      modules
      |> Enum.map(&safe_call(&1, :module_key, nil))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    for mod <- modules do
      required = safe_call(mod, :required_modules, [])

      for req_key <- required, not MapSet.member?(all_keys, req_key) do
        Logger.warning(
          "[ModuleRegistry] #{inspect(mod)} requires module #{inspect(req_key)} " <>
            "which is not registered. This module may not function correctly."
        )
      end
    end
  end

  @doc """
  Run every enabled module's `migrate_legacy/0` callback.

  Iterates registered modules, calls `migrate_legacy/0` on each that
  implements it, swallows per-module errors so the host-app boot can't
  be taken down by a flaky migration. Each module's implementation is
  expected to be idempotent (safe to re-run on every boot).

  Activity logging happens inside each module's `migrate_legacy/0` —
  this orchestrator only logs the per-module pass/fail outcome to the
  Logger, not to Activity.

  Designed to be called once from a host app's `Application.start/2`
  after the Repo and supervision tree are up:

      def start(_type, _args) do
        children = [...]
        result = Supervisor.start_link(children, opts)
        PhoenixKit.ModuleRegistry.run_all_legacy_migrations()
        result
      end

  Returns a summary map: `%{module_atom => :ok | {:error, term()}}`.
  """
  @spec run_all_legacy_migrations() :: %{module() => :ok | {:error, term()}}
  def run_all_legacy_migrations do
    all_modules()
    |> Enum.reduce(%{}, fn mod, acc ->
      Map.put(acc, mod, run_one_legacy_migration(mod))
    end)
  end

  defp run_one_legacy_migration(mod) do
    cond do
      not Code.ensure_loaded?(mod) ->
        {:error, :module_not_loaded}

      not function_exported?(mod, :migrate_legacy, 0) ->
        :ok

      true ->
        do_run_legacy_migration(mod)
    end
  end

  defp do_run_legacy_migration(mod) do
    case mod.migrate_legacy() do
      :ok ->
        :ok

      {:ok, _summary} ->
        :ok

      {:error, reason} = err ->
        Logger.warning(
          "[ModuleRegistry] #{inspect(mod)}.migrate_legacy/0 returned error: #{inspect(reason)}"
        )

        err

      other ->
        Logger.warning(
          "[ModuleRegistry] #{inspect(mod)}.migrate_legacy/0 returned unexpected shape: " <>
            inspect(other)
        )

        {:error, {:unexpected_return, other}}
    end
  rescue
    error ->
      Logger.warning(
        "[ModuleRegistry] #{inspect(mod)}.migrate_legacy/0 raised: #{Exception.message(error)}"
      )

      {:error, error}
  catch
    :exit, reason ->
      Logger.warning(
        "[ModuleRegistry] #{inspect(mod)}.migrate_legacy/0 exited: #{inspect(reason)}"
      )

      {:error, {:exit, reason}}
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
