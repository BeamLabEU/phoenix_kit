defmodule PhoenixKit.ModuleRegistry do
  @moduledoc """
  Runtime registry of all PhoenixKit modules (internal and external).

  External modules are auto-discovered from beam files via `PhoenixKit.ModuleDiscovery`.
  Any dep that depends on `:phoenix_kit` and uses `use PhoenixKit.Module` is found
  automatically — no config line needed.

  ## External Module Registration

  External hex packages are auto-discovered. Just add the dep, at the
  package's current release:

      {:phoenix_kit_hello_world, "~> X.Y"}

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
      ModuleRegistry.all_email_settings_sections() # Collect Emails Transactional page sections
      ModuleRegistry.all_email_templates()   # Collect emails for the admin email preview
      ModuleRegistry.all_api_tools()         # Collect API tools of enabled modules
      ModuleRegistry.all_api_problems()      # Collect API error codes of enabled modules
      ModuleRegistry.all_header_widgets()    # Collect admin header widgets of enabled modules
      ModuleRegistry.all_user_dashboard_tabs() # Collect user dashboard tabs
      ModuleRegistry.all_children()          # Collect supervisor child specs
      ModuleRegistry.all_permission_metadata() # Collect permission metadata
      ModuleRegistry.feature_enabled_checks()  # Build {mod, :enabled?} map
      ModuleRegistry.get_by_key("tickets")   # Find module by key
      ModuleRegistry.get_module_key_for_namespace("PhoenixKitTickets")
                                             # Resolve top-level namespace → key
  """

  use GenServer

  alias PhoenixKit.API.ControlFields
  alias PhoenixKit.API.Problem
  alias PhoenixKit.API.Tool
  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.HeaderWidget
  alias PhoenixKit.Integrations.Providers

  require Logger

  @pterm_key {PhoenixKit, :registered_modules}

  # A rescan that does have to read the disk reads every beam of every
  # phoenix_kit-dependent dep; on a cold disk or a CPU-starved host that outlives
  # GenServer's 5 s default, and at boot the caller is `Application.start/2`.
  @rescan_timeout :timer.minutes(1)

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

  Cheap when nothing changed: the disk is checked with `stat` and the beams are
  read only when a dep was added, removed or rebuilt since the last scan
  (`PhoenixKit.ModuleDiscovery.current_external_modules/0`). `timeout` bounds the
  call for the case where it does have to scan (default one minute).
  """
  @spec rescan() :: {:ok, [module()]}
  @spec rescan(timeout()) :: {:ok, [module()]}
  def rescan(timeout \\ @rescan_timeout) do
    GenServer.call(__MODULE__, :rescan, timeout)
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
  catch
    # A dead database pool exits instead of raising, and `enabled?/0` usually reads a
    # setting. This runs on the API request path, so an exit must read as "not enabled".
    :exit, _reason -> false
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

  @doc """
  Collect email settings sections contributed by all **enabled** modules,
  for the core Emails Transactional settings page
  (`/admin/settings/email-sending`).

  Mirrors `all_settings_tabs/0`'s `safe_call` pattern, but — like
  `all_sitemap_sources/0` — iterates `enabled_modules/0` rather than
  `all_modules/0`: a disabled module must not inject a `live_component`
  that assumes its own supervised state is running.
  """
  @spec all_email_settings_sections() :: [PhoenixKit.Module.email_settings_section()]
  def all_email_settings_sections do
    enabled_modules()
    |> Enum.flat_map(&safe_call(&1, :email_settings_sections, []))
  end

  @doc """
  Collect the emails enabled modules send (`c:PhoenixKit.Module.email_templates/0`),
  each tagged with `:module`, the module that declared it.

  Enabled modules only, like `all_email_settings_sections/0`: a disabled
  module sends nothing, so the preview has none of its emails to show.
  """
  @spec all_email_templates() :: [map()]
  def all_email_templates do
    enabled_modules()
    |> Enum.flat_map(fn mod ->
      mod
      |> safe_call(:email_templates, [])
      |> List.wrap()
      |> Enum.flat_map(fn
        entry when is_map(entry) ->
          [Map.put(entry, :module, mod)]

        entry ->
          warn_once_bad_email_template(mod, entry)
          []
      end)
    end)
  end

  # The preview page collects these on every mount; one warning per module is
  # enough to say its callback returned something that is not an entry.
  defp warn_once_bad_email_template(mod, entry) do
    key = {__MODULE__, :warned_bad_email_template, mod}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning(
        "[ModuleRegistry] #{inspect(mod)}.email_templates/0 returned a non-map entry, " <>
          "ignored: #{inspect(entry, limit: 5, printable_limit: 80)}"
      )
    end
  end

  @doc "Collect all user dashboard tabs from all registered modules."
  @spec all_user_dashboard_tabs() :: [PhoenixKit.Dashboard.Tab.t()]
  def all_user_dashboard_tabs do
    all_modules()
    |> Enum.flat_map(&safe_call(&1, :user_dashboard_tabs, []))
    |> Enum.map(&Tab.resolve_path(&1, :user_dashboard))
  end

  @doc """
  Collect the profile settings tabs (`c:PhoenixKit.Module.profile_settings_tabs/0`) of the
  **enabled** modules, as `PhoenixKit.ProfileSettingsTab` structs tagged with `:module`.
  Duplicate ids are resolved before enablement, matching the compiled routes: disabling
  the first declaring module cannot hand its URL to a different module's tab.
  Only modules whose declarations survive are asked whether they are enabled.
  """
  @spec all_profile_settings_tabs() :: [PhoenixKit.ProfileSettingsTab.t()]
  def all_profile_settings_tabs do
    all_modules()
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :profile_settings_tabs, 0) and
        function_exported?(mod, :enabled?, 0)
    end)
    |> Enum.flat_map(&PhoenixKit.ProfileSettingsTab.from_module/1)
    |> PhoenixKit.ProfileSettingsTab.drop_duplicates()
    |> Enum.filter(&safe_enabled?(&1.module))
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
  Collect media reorganizer source modules contributed by all **enabled**
  modules.

  Each entry implements `PhoenixKit.Modules.Storage.Reorganizer.Source`.
  Iterates `enabled_modules/0`, like `all_sitemap_sources/0`: a disabled
  module's records must not be touched by a reorganizer run.
  """
  @spec all_media_reorganizers() :: [module()]
  def all_media_reorganizers do
    enabled_modules()
    |> Enum.map(&safe_call(&1, :media_reorganizer, nil))
    |> Enum.filter(&is_atom/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  The orphan-check file references every module supplies, by owning OTP app.

  Returns `%{app => {:ok, [{table, dynamic}]} | {:error, reason}}` for each
  registered module that implements `c:PhoenixKit.Module.file_references/0`.
  Iterates `all_modules/0`, **not** `enabled_modules/0`: a disabled module's
  data still holds its files, and dropping its references would make them
  look orphaned. A module whose callback raises, or returns something that is
  not a list of `{table, dynamic}` pairs, is reported as `{:error, reason}`
  rather than skipped; the caller fails closed.
  """
  @spec all_file_references() :: %{
          atom() => {:ok, [{String.t(), Ecto.Query.dynamic_expr()}]} | {:error, String.t()}
        }
  def all_file_references do
    for mod <- all_modules(),
        Code.ensure_loaded?(mod),
        function_exported?(mod, :file_references, 0),
        app = Application.get_application(mod),
        into: %{} do
      {app, file_reference_pairs(mod)}
    end
  end

  @doc false
  def file_reference_pairs(mod) do
    case mod.file_references() do
      pairs when is_list(pairs) ->
        if Enum.all?(pairs, &match?({table, _} when is_binary(table), &1)),
          do: {:ok, pairs},
          else: {:error, "#{inspect(mod)}.file_references/0 returned a malformed entry"}

      other ->
        {:error, "#{inspect(mod)}.file_references/0 returned #{inspect(other)}"}
    end
  rescue
    error ->
      {:error, "#{inspect(mod)}.file_references/0 raised: #{Exception.message(error)}"}
  catch
    kind, reason ->
      {:error, "#{inspect(mod)}.file_references/0 #{kind}: #{inspect(reason)}"}
  end

  @doc """
  The table manifests modules supply, by owning OTP app.

  Returns `%{app => %{manifest: module, migrations: module}}` for each
  registered module that implements `c:PhoenixKit.Module.expected_schema/0`
  with a manifest module and has a `migration_module/0`. Iterates
  `all_modules/0`: a disabled module's tables are still there to verify. A
  callback that raises, or a module that is not loaded or does not export the
  manifest functions, is left out; repair then says nothing about that module.
  """
  @spec all_expected_schemas() :: %{atom() => %{manifest: module(), migrations: module()}}
  def all_expected_schemas do
    for mod <- all_modules(),
        Code.ensure_loaded?(mod),
        function_exported?(mod, :expected_schema, 0),
        app = Application.get_application(mod),
        {:ok, entry} <- [expected_schema_entry(mod)],
        into: %{} do
      {app, entry}
    end
  end

  @doc false
  def expected_schema_entry(mod) do
    manifest = mod.expected_schema()
    migrations = mod.migration_module()

    if usable_manifest?(manifest) and is_atom(migrations) and not is_nil(migrations) and
         Code.ensure_loaded?(migrations),
       do: {:ok, %{manifest: manifest, migrations: migrations}},
       else: :error
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp usable_manifest?(manifest) when is_atom(manifest) and not is_nil(manifest) do
    Code.ensure_loaded?(manifest) and
      Enum.all?([objects: 1, data_invariants: 1, chain_hash: 0], fn {fun, arity} ->
        function_exported?(manifest, fun, arity)
      end)
  end

  defp usable_manifest?(_), do: false

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
    # Computed once: the capture form re-evaluated it for every catalog entry.
    installed = installed_otp_apps()

    known_external_packages()
    |> Enum.reject(&MapSet.member?(installed, &1.package))
  end

  # "Installed" is the union of two questions, because a `phoenix_kit_*` package
  # is not necessarily a feature module. Discovery answers "does it implement
  # `PhoenixKit.Module`?", which misses infrastructure dependencies core pulls in
  # for itself — `phoenix_kit_templates` is one, and without the second check it
  # would be advertised on the Modules page as available to install while
  # already being a transitive dependency of core with no UI to install.
  #
  # Loaded applications answer "is it there at all?", and miss a `runtime: false`
  # dependency whose beams discovery can still see. Neither check subsumes the
  # other, so both are consulted.
  defp installed_otp_apps do
    discovered =
      PhoenixKit.ModuleDiscovery.cached_external_modules()
      |> Enum.map(&Application.get_application/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new(&Atom.to_string/1)

    :application.loaded_applications()
    |> MapSet.new(fn {name, _description, _version} -> Atom.to_string(name) end)
    |> MapSet.union(discovered)
  end

  @doc "Returns all feature module key strings from registered modules."
  @spec all_feature_keys() :: [String.t()]
  def all_feature_keys do
    all_permission_metadata()
    |> Enum.map(& &1.key)
    |> Enum.filter(&valid_base_key?/1)
    |> Enum.sort()
  end

  @valid_sub_key_pattern ~r/^[a-z][a-z0-9_]*$/
  @max_sub_key_length 50

  # A base permission key must NOT contain a dot: the dot composes base+sub
  # into a sub-key ("calendar" + "view_others" = "calendar.view_others"). A
  # base literally named "calendar.view_others" would be indistinguishable
  # from that composed sub-key — granting one would cascade the other's base,
  # and revoking a base would delete the other module's row. Same pattern as
  # sub-keys, dot excluded.
  @valid_base_key_pattern ~r/^[a-z][a-z0-9_]*$/

  @doc """
  Whether a module base permission key is well-formed (lowercase, no dots,
  within length). A dotted base key would collide with composed sub-keys, so
  the permission plumbing ignores base keys that fail this check.
  """
  @spec valid_base_key?(String.t()) :: boolean()
  def valid_base_key?(key) when is_binary(key) do
    Regex.match?(@valid_base_key_pattern, key) and String.length(key) <= @max_sub_key_length
  end

  def valid_base_key?(_), do: false

  @doc """
  Returns the sub-permissions declared by registered modules, keyed by the
  parent module key. Each entry carries the COMPOSED dotted key
  (`"calendar.view_others"`) plus its label, description and `opt_in` (`true`
  when the module declared the sub-permission with `opt_in: true`, meaning the
  Admin role is not given it automatically).

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

  defp valid_sub_permissions(%{key: base, sub_permissions: subs})
       when is_list(subs) and is_binary(base) do
    if valid_base_key?(base) do
      valid_sub_permissions_for(base, subs)
    else
      Logger.warning(
        "[ModuleRegistry] Dropping sub-permissions of #{inspect(base)}: " <>
          "base key must not contain a dot (collides with composed sub-keys)"
      )

      []
    end
  end

  defp valid_sub_permissions(_meta), do: []

  defp valid_sub_permissions_for(base, subs) do
    subs
    |> Enum.filter(&valid_sub_permission?(base, &1))
    |> Enum.uniq_by(& &1.key)
    |> Enum.map(fn sub ->
      %{
        key: "#{base}.#{sub.key}",
        label: sub.label,
        description: Map.get(sub, :description, ""),
        opt_in: Map.get(sub, :opt_in) == true
      }
    end)
  end

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

  @doc """
  Returns the optional gettext `{backend, domain}` pairs registered modules
  declare for translating their permission labels (see
  `t:PhoenixKit.Module.permission_meta/0`). Modules without a
  `gettext_backend` are absent from the map.
  """
  @spec permission_gettext() :: %{String.t() => {module(), String.t()}}
  def permission_gettext do
    all_permission_metadata()
    |> Enum.reduce(%{}, fn meta, acc ->
      case Map.get(meta, :gettext_backend) do
        nil ->
          acc

        backend when is_atom(backend) ->
          # A backend that can't answer dgettext/3 would raise at render
          # time (see Permissions.localized_module_label/1) — drop it here
          # so one bad module can't break the permissions matrix.
          if Code.ensure_loaded?(backend) and function_exported?(backend, :__gettext__, 1) do
            Map.put(acc, meta.key, {backend, Map.get(meta, :gettext_domain) || "default"})
          else
            Logger.warning(
              "[ModuleRegistry] Ignoring gettext_backend #{inspect(backend)} of " <>
                "#{inspect(meta.key)}: not a loaded Gettext backend (no __gettext__/1)"
            )

            acc
          end

        _ ->
          acc
      end
    end)
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
      invalidate_module_derived_caches()
      # Not part of `invalidate_module_derived_caches/0`: `rescan/0` calls that
      # right after `load_modules/0` has refreshed the scan cache and must not
      # wipe it.
      PhoenixKit.ModuleDiscovery.clear_cache()
      {:reply, :ok, %{state | modules: updated}}
    end
  end

  def handle_call({:unregister, module}, _from, %{modules: modules} = state) do
    updated = List.delete(modules, module)
    :persistent_term.put(@pterm_key, updated)
    invalidate_module_derived_caches()
    PhoenixKit.ModuleDiscovery.clear_cache()
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
        invalidate_module_derived_caches()

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

  # Anything cached OFF the registered-module set has to be dropped whenever
  # that set changes, or it keeps answering from the module list that was
  # current the first time it was asked. `Providers.all/0` caches
  # `builtin ++ external_providers()` in `persistent_term` with no TTL, and
  # `all_modules/0` defaults to `[]` before `init/1` runs — so a provider
  # contributed by a module that arrives later (`rescan/0` from the parent's
  # `Application.start/2`, a runtime `register/1`, a dev hot-reload) stayed
  # invisible for the life of the VM. That was survivable while an unknown
  # key merely fell back to `scopes_of/1`'s `[:system]` default; since
  # `Integrations.add_connection/4` began rejecting unregistered keys
  # outright (`{:error, :unknown_provider}`, PR #765) it means a legitimately
  # installed provider cannot be connected at all until a restart.
  defp invalidate_module_derived_caches do
    Providers.clear_cache()
    :ok
  end

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
    # A boot needs this three times in a row — `static_children/0` while
    # `PhoenixKit.Supervisor` builds its children, `init/1`, then `rescan/0` from
    # `PhoenixKit.boot/1` — and each used to re-read every beam of every dependent
    # dep. `current_external_modules/0` reads them once and answers the later calls
    # from that scan while a `stat` fingerprint of the disk is unchanged, so a dep
    # added or rebuilt in between is still found. A scan that saw a file younger
    # than two seconds (a boot right after a compile) is not remembered, and the
    # next call scans again. It also leaves the runtime scan
    # cache warm, so the admin pages never pay for a cold scan; nothing after this
    # in either path may clear it.
    external = PhoenixKit.ModuleDiscovery.current_external_modules()
    (internal ++ external) |> Enum.uniq()
  end

  # All bundled PhoenixKit modules. This is the ONE remaining enumeration
  # of internal modules. When a module is extracted to its own hex package,
  # remove it from this list and add it to :modules config instead.
  defp internal_modules do
    [
      PhoenixKit.Modules.Crawlers,
      PhoenixKit.Modules.Sitemap,
      PhoenixKit.Modules.Storage,
      PhoenixKit.Notifications
    ]
  end

  @doc """
  The kinds of job run (`PhoenixKit.Jobs.Kind`) the enabled modules declare
  with `PhoenixKit.Module.job_kinds/0`. A kind that is not a loaded module is
  left out, with one warning.
  """
  @spec all_job_kinds() :: [module()]
  def all_job_kinds do
    enabled_modules()
    |> Enum.flat_map(fn mod -> mod |> safe_call(:job_kinds, []) |> List.wrap() end)
    |> Enum.filter(
      &(is_atom(&1) and Code.ensure_loaded?(&1) and function_exported?(&1, :kind, 0))
    )
    |> Enum.uniq()
  end

  @doc """
  Collect the API tools (`c:PhoenixKit.Module.api_tools/0`) of the **enabled** modules,
  each tagged with `:module`, the module that declared it.

  A disabled module's tools cannot be called, so they are left out (`disabled_api_tool?/3`
  is the other side of that). So are the tools of a module whose key is in `hidden_keys`
  (the install's `api_disabled_modules` setting: the module's API is switched off). An entry
  that is not a valid `PhoenixKit.API.Tool` (`PhoenixKit.API.Tool.validate/1`) is dropped
  with one warning per module, and so is a tool in core's `system.` namespace (those skip
  the scope and permission checks and belong to `PhoenixKit.API.CoreTools` alone). A name
  declared twice for one audience keeps the first (registration order), again with one
  warning; the keys are removed before that, so switching the first module off hands the
  name to the second. A module whose `api_tools/0` raises contributes nothing and is
  reported once.

  This is not a gate. With the default `hidden_keys` it returns the tools of modules whose
  API is switched off; only `PhoenixKit.API.Registry` applies the install's settings, so a
  transport must ask it for tools.

  Every call asks every module again (`enabled?/0` and `api_tools/0` are not cached), so a
  caller that serves requests should call it once per request and keep the result.
  """
  @spec all_api_tools([String.t()]) :: [Tool.t()]
  def all_api_tools(hidden_keys \\ []) do
    enabled_modules()
    |> Enum.reject(&api_hidden?(&1, hidden_keys))
    |> Enum.flat_map(&module_api_tools/1)
    |> drop_duplicate_api_tools()
  end

  @doc """
  True when a registered module that is switched **off** declares the API tool `name` for
  `audience`.

  This is the "module disabled" test of `PhoenixKit.API.Registry.find/2`. It asks only the
  disabled modules for their tools, and it looks at the audience, so an anonymous caller
  cannot learn that an admin tool exists by asking for it on the public side. A module
  whose key is in `hidden_keys` (its API is switched off) does not count: its tools answer
  like a name nobody has.
  """
  @spec disabled_api_tool?(String.t(), :admin | :public, [String.t()]) :: boolean()
  def disabled_api_tool?(name, audience, hidden_keys \\ []) do
    (all_modules() -- enabled_modules())
    |> Enum.reject(&api_hidden?(&1, hidden_keys))
    |> Enum.flat_map(&module_api_tools/1)
    |> Enum.any?(&(&1.name == name and &1.audience == audience))
  end

  @doc """
  The names of the API tools declared for `audience` by **every** registered module,
  switched on or off, sorted and without duplicates.

  This is for enumeration only (for instance a screen listing the tools that can be hidden
  or granted). It is not a gate: `PhoenixKit.API.Registry.find/2` decides whether a tool
  can be called. The tools go through the same validation as in `all_api_tools/0`, so an
  invalid tool and a `system.` name declared by a module are left out, and a module whose
  `api_tools/0` raises contributes nothing.
  """
  @spec api_tool_names(:admin | :public) :: [String.t()]
  def api_tool_names(audience) when audience in [:admin, :public] do
    all_modules()
    |> Enum.flat_map(&module_api_tools/1)
    |> Enum.filter(&(&1.audience == audience))
    |> Enum.map(& &1.name)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Every registered module that declares at least one valid API tool, switched on or off, in
  registration order: `%{module, key, name, enabled?, tools}`, where `tools` are its tools
  tagged with `:module` (validated as in `all_api_tools/1`) and `key` is `nil` for a module
  without a usable `module_key/0`.

  For enumeration only (what could be offered, and what keeps it closed); it is not a gate:
  `PhoenixKit.API.Registry` decides what is callable.
  """
  @spec api_module_tools() :: [
          %{
            module: module(),
            key: String.t() | nil,
            name: String.t(),
            enabled?: boolean(),
            tools: [Tool.t(), ...]
          }
        ]
  def api_module_tools do
    enabled = enabled_modules()

    Enum.flat_map(all_modules(), fn mod ->
      case module_api_tools(mod) do
        [] ->
          []

        tools ->
          [
            %{
              module: mod,
              key: api_module_key(mod),
              name: api_module_name(mod),
              enabled?: mod in enabled,
              tools: tools
            }
          ]
      end
    end)
  end

  @doc """
  Collect the API error codes (`c:PhoenixKit.Module.api_problems/0`) of the **enabled**
  modules as `%{code => %{status, title, advice}}`.

  This is read when an error is answered (`PhoenixKit.API.Problem`), never on the success
  path. A code that is one of core's (`PhoenixKit.API.Problem.core_code?/1`) cannot be
  overridden, so that declaration is dropped with a warning; so is an entry with a code that
  is not an atom, a `status` outside `400..599`, a `title` that is not a non-empty string
  or an `advice` that is neither a string nor `nil`. A code declared by two modules keeps
  the first (registration order), again with one warning. A module whose
  `api_problems/0` raises, or returns something that is not a map, contributes nothing
  and is reported once.

  Like `all_api_tools/1` it asks every module again on every call.
  """
  @spec all_api_problems() :: %{
          atom() => %{status: 400..599, title: String.t(), advice: String.t() | nil}
        }
  def all_api_problems do
    enabled_modules()
    |> Enum.flat_map(&module_api_problems/1)
    |> Enum.reduce(%{}, fn {mod, code, problem}, acc ->
      if Map.has_key?(acc, code) do
        warn_once(
          {:duplicate_api_problem, mod, code},
          "[ModuleRegistry] #{inspect(mod)}.api_problems/0 declares #{inspect(code)}, " <>
            "which another module already declared, ignored"
        )

        acc
      else
        Map.put(acc, code, problem)
      end
    end)
  end

  @doc """
  The registered modules that declare at least one valid API tool, switched on or off,
  sorted by name: `%{module, key, name, enabled?, tools, audiences, writes?}` (`tools` is
  how many, `audiences` the audiences they serve, `writes?` whether one of them is an admin
  tool that writes, `PhoenixKit.API.ControlFields.write_tool?/1`).

  For the screens that list them (the API switch per module in Settings -> API, the badge
  on the Modules page). It is not a gate: `PhoenixKit.API.Registry` decides what is callable.
  """
  @spec api_modules() :: [
          %{
            module: module(),
            key: String.t(),
            name: String.t(),
            enabled?: boolean(),
            tools: pos_integer(),
            audiences: [Tool.audience()],
            writes?: boolean()
          }
        ]
  def api_modules do
    enabled = enabled_modules()

    all_modules()
    |> Enum.flat_map(fn mod ->
      case {module_api_tools(mod), api_module_key(mod)} do
        {[_ | _] = tools, key} when is_binary(key) ->
          [
            %{
              module: mod,
              key: key,
              name: api_module_name(mod),
              enabled?: mod in enabled,
              tools: length(tools),
              audiences: tools |> Enum.map(& &1.audience) |> Enum.uniq() |> Enum.sort(),
              writes?:
                Enum.any?(tools, &(&1.audience == :admin and ControlFields.write_tool?(&1)))
            }
          ]

        {[_ | _], _no_key} ->
          warn_once(
            {:api_module_without_key, mod},
            "[ModuleRegistry] #{inspect(mod)} declares API tools but has no usable " <>
              "module_key/0, so its API cannot be switched off"
          )

          []

        {[], _key} ->
          []
      end
    end)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @doc """
  Collect the admin header widgets (`c:PhoenixKit.Module.header_widgets/0`) of the
  **enabled** modules, as `PhoenixKit.HeaderWidget` structs tagged with `:module`.

  Only a module that defines `header_widgets/0` is asked (and only then is its `enabled?/0`
  called), so an install without such modules pays nothing for this on the layout's render
  path. An entry that is not a valid widget is dropped with one warning per module, a widget
  whose id was already taken by an earlier one is dropped with one warning, and a module
  whose `header_widgets/0` raises contributes nothing and is reported once.
  """
  @spec all_header_widgets() :: [HeaderWidget.t()]
  def all_header_widgets do
    all_modules()
    |> Enum.filter(&(header_widgets_exported?(&1) and header_widgets_enabled?(&1)))
    |> Enum.flat_map(&module_header_widgets/1)
    |> drop_duplicate_header_widgets()
  end

  @doc """
  The header widgets to render for one layout render: `all_header_widgets/0`, each with
  `:session` computed by its session function from `assigns` (the layout's assigns).

  A widget whose session function returns `nil` is dropped without a word (no widget for
  this user); one whose session function raises, or returns something that is not a map with
  string keys, is dropped with one warning. The keys the cookie session owns
  (`PhoenixKit.HeaderWidget.reserved_session_keys/0`) are removed from the session, with one
  warning per module and widget.
  """
  @spec header_widgets_for(map()) :: [HeaderWidget.t()]
  def header_widgets_for(assigns) when is_map(assigns) do
    Enum.flat_map(all_header_widgets(), fn widget ->
      case HeaderWidget.resolve_session(widget, assigns) do
        {:ok, resolved, dropped} ->
          warn_reserved_session_keys(widget, dropped)
          [resolved]

        :skip ->
          []

        {:error, reason} ->
          warn_once(
            {:header_widget_session, widget.module, widget.id},
            "[ModuleRegistry] #{inspect(widget.module)} header widget #{inspect(widget.id)} " <>
              "skipped: #{reason}"
          )

          []
      end
    end)
  end

  defp warn_reserved_session_keys(_widget, []), do: :ok

  defp warn_reserved_session_keys(widget, dropped) do
    warn_once(
      {:header_widget_reserved_keys, widget.module, widget.id},
      "[ModuleRegistry] #{inspect(widget.module)} header widget #{inspect(widget.id)} " <>
        "session keys dropped, they belong to the cookie session: #{Enum.join(dropped, ", ")}"
    )
  end

  defp header_widgets_exported?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :header_widgets, 0)
  end

  defp header_widgets_enabled?(mod) do
    function_exported?(mod, :enabled?, 0) and safe_enabled?(mod)
  end

  defp module_header_widgets(mod) do
    mod
    |> call_header_widgets()
    |> List.wrap()
    |> Enum.flat_map(fn entry ->
      case HeaderWidget.new(entry) do
        {:ok, widget} ->
          [%{widget | module: mod}]

        {:error, reason} ->
          warn_once(
            {:bad_header_widget, mod},
            "[ModuleRegistry] #{inspect(mod)}.header_widgets/0 returned an invalid " <>
              "widget, ignored: #{reason}"
          )

          []
      end
    end)
  end

  # Like `call_api_tools/1`: this runs on every render of the admin layout, so a failing
  # callback is reported once per module.
  defp call_header_widgets(mod) do
    mod.header_widgets()
  rescue
    error ->
      warn_header_widgets_failed(mod, "raised #{inspect(error.__struct__)}")
  catch
    kind, _reason ->
      warn_header_widgets_failed(mod, "failed (#{kind})")
  end

  defp warn_header_widgets_failed(mod, detail) do
    warn_once(
      {:header_widgets_failed, mod},
      "[ModuleRegistry] #{inspect(mod)}.header_widgets/0 #{detail}"
    )

    []
  end

  defp drop_duplicate_header_widgets(widgets) do
    {kept, _seen} =
      Enum.reduce(widgets, {[], MapSet.new()}, fn widget, {kept, seen} ->
        if MapSet.member?(seen, widget.id) do
          warn_once(
            {:duplicate_header_widget, widget.id},
            "[ModuleRegistry] #{inspect(widget.module)} declares the header widget " <>
              "#{inspect(widget.id)} that another module already declared, ignored"
          )

          {kept, seen}
        else
          {[widget | kept], MapSet.put(seen, widget.id)}
        end
      end)

    Enum.reverse(kept)
  end

  defp api_module_name(mod) do
    case safe_call(mod, :module_name, nil) do
      name when is_binary(name) -> name
      _ -> inspect(mod)
    end
  end

  defp api_hidden?(_mod, []), do: false
  defp api_hidden?(mod, hidden_keys), do: api_module_key(mod) in hidden_keys

  @doc """
  The key a module's API switches are stored under (its `module_key/0`), or `nil` for a
  module without a usable one. `PhoenixKit.API.Executor` reads it to match a tool's
  `:module` against `api_session_write_modules`.
  """
  @spec api_module_key(module() | nil) :: String.t() | nil
  def api_module_key(nil), do: nil

  # Like `call_api_tools/1`, a failing `module_key/0` is reported once per module: the
  # switch is read on the request path, where `safe_call/3` would log on every request.
  def api_module_key(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :module_key, 0) do
      mod.module_key()
    end
  rescue
    error ->
      warn_module_key_failed(mod, Exception.message(error))
  catch
    kind, reason ->
      warn_module_key_failed(mod, inspect({kind, reason}))
  end

  defp warn_module_key_failed(mod, detail) do
    warn_once(
      {:module_key_failed, mod},
      "[ModuleRegistry] #{inspect(mod)}.module_key/0 failed: #{detail}"
    )

    nil
  end

  defp module_api_tools(mod) do
    mod
    |> call_api_tools()
    |> List.wrap()
    |> Enum.flat_map(&valid_api_tool(mod, &1))
  end

  # Unlike `safe_call/3`, a failing `api_tools/0` is reported once per module: this runs on
  # the request path of an endpoint that needs no login.
  defp call_api_tools(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :api_tools, 0) do
      mod.api_tools()
    else
      []
    end
  rescue
    error ->
      warn_api_tools_failed(mod, Exception.message(error))
  catch
    kind, reason ->
      warn_api_tools_failed(mod, inspect({kind, reason}))
  end

  defp warn_api_tools_failed(mod, detail) do
    warn_once(
      {:api_tools_failed, mod},
      "[ModuleRegistry] #{inspect(mod)}.api_tools/0 failed: #{detail}"
    )

    []
  end

  defp valid_api_tool(mod, %Tool{} = tool) do
    case Tool.validate(tool) do
      {:ok, tool} ->
        if Tool.system?(tool), do: reject_system_tool(mod, tool), else: [%{tool | module: mod}]

      {:error, messages} ->
        warn_once(
          {:bad_api_tool, mod},
          "[ModuleRegistry] #{inspect(mod)}.api_tools/0 returned an invalid tool, ignored: " <>
            Enum.join(messages, "; ")
        )

        []
    end
  end

  defp valid_api_tool(mod, entry) do
    warn_once(
      {:bad_api_tool, mod},
      "[ModuleRegistry] #{inspect(mod)}.api_tools/0 returned something that is not a " <>
        "PhoenixKit.API.Tool, ignored: #{inspect(entry, limit: 5, printable_limit: 80)}"
    )

    []
  end

  defp reject_system_tool(mod, tool) do
    warn_once(
      {:system_api_tool, mod},
      "[ModuleRegistry] #{inspect(mod)}.api_tools/0 declares #{tool.name}, but the " <>
        "\"system.\" namespace is reserved for core, ignored"
    )

    []
  end

  defp drop_duplicate_api_tools(tools) do
    {kept, _seen} =
      Enum.reduce(tools, {[], MapSet.new()}, fn tool, {kept, seen} ->
        key = {tool.audience, tool.name}

        if MapSet.member?(seen, key) do
          warn_once(
            {:duplicate_api_tool, key},
            "[ModuleRegistry] #{inspect(tool.module)} declares the API tool #{tool.name} " <>
              "(#{tool.audience}) that another module already declared, ignored"
          )

          {kept, seen}
        else
          {[tool | kept], MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(kept)
  end

  defp module_api_problems(mod) do
    case call_api_problems(mod) do
      %{} = problems ->
        Enum.flat_map(problems, fn {code, entry} -> valid_api_problem(mod, code, entry) end)

      other ->
        warn_once(
          {:bad_api_problems, mod},
          "[ModuleRegistry] #{inspect(mod)}.api_problems/0 returned something that is not a " <>
            "map, ignored: #{inspect(other, limit: 5, printable_limit: 80)}"
        )

        []
    end
  end

  # Runs when an error is answered by an endpoint that needs no login: a failing callback
  # is reported once per module, like `call_api_tools/1`.
  defp call_api_problems(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :api_problems, 0) do
      mod.api_problems()
    else
      %{}
    end
  rescue
    error ->
      warn_api_problems_failed(mod, Exception.message(error))
  catch
    kind, reason ->
      warn_api_problems_failed(mod, inspect({kind, reason}))
  end

  defp warn_api_problems_failed(mod, detail) do
    warn_once(
      {:api_problems_failed, mod},
      "[ModuleRegistry] #{inspect(mod)}.api_problems/0 failed: #{detail}"
    )

    %{}
  end

  defp valid_api_problem(mod, code, entry) when is_atom(code) do
    if Problem.core_code?(code) do
      warn_once(
        {:shadowed_api_problem, mod, code},
        "[ModuleRegistry] #{inspect(mod)}.api_problems/0 declares #{inspect(code)}, " <>
          "but that code belongs to core and cannot be overridden, ignored"
      )

      []
    else
      case normalize_api_problem(entry) do
        {:ok, problem} -> [{mod, code, problem}]
        {:error, reason} -> warn_bad_api_problem(mod, code, reason)
      end
    end
  end

  defp valid_api_problem(mod, code, _entry),
    do: warn_bad_api_problem(mod, code, "the code is not an atom")

  defp normalize_api_problem(%{status: status, title: title} = entry)
       when is_integer(status) and status in 400..599 and is_binary(title) and title != "" do
    case Map.get(entry, :advice) do
      advice when is_nil(advice) or is_binary(advice) ->
        {:ok, %{status: status, title: title, advice: advice}}

      _other ->
        {:error, "advice must be a string or nil"}
    end
  end

  defp normalize_api_problem(%{} = entry) do
    {:error,
     "needs a status in 400..599 and a non-empty title, got " <>
       inspect(Map.take(entry, [:status, :title]), limit: 5, printable_limit: 80)}
  end

  defp normalize_api_problem(entry),
    do: {:error, "is not a map: #{inspect(entry, limit: 5, printable_limit: 80)}"}

  defp warn_bad_api_problem(mod, code, reason) do
    warn_once(
      {:bad_api_problem, mod, code},
      "[ModuleRegistry] #{inspect(mod)}.api_problems/0 has an invalid entry " <>
        "#{inspect(code, limit: 5, printable_limit: 80)} (#{reason}), ignored"
    )

    []
  end

  # Collectors run on the request path: log a given problem once per node.
  defp warn_once(key, message) do
    pterm = {__MODULE__, :warned, key}

    unless :persistent_term.get(pterm, false) do
      :persistent_term.put(pterm, true)
      Logger.warning(message)
    end

    :ok
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
  #
  # `personal: true` opts out: those tabs lead to a page showing the viewer
  # their own data, which is deliberately permission-free, and warning about
  # them would train people to ignore a warning that is usually right.
  defp warn_tabs_missing_permission(modules) do
    for mod <- modules,
        perm_meta = safe_call(mod, :permission_metadata, nil),
        perm_meta != nil,
        tab <- safe_call(mod, :admin_tabs, []),
        not Map.get(tab, :personal, false),
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

  `PhoenixKit.boot/1` calls it — pipe the supervisor result into that from
  the host's `Application.start/2` (`mix phoenix_kit.install` / `update` wire
  it in). A host that still calls this function itself after
  `Supervisor.start_link/2` gets the same behaviour.

  **Does nothing with `update_mode` on** (`mix phoenix_kit.update` and
  `mix phoenix_kit.doctor` start the host that way) and returns `%{}`. The
  callbacks are one-shot data transitions whose "already done" checks
  usually read `PhoenixKit.Settings`, which answers nil in that mode while
  writes still go through — so they redid their work on every update or
  doctor run (granting back a permission an Owner had revoked, re-stamping
  markers). The update task also starts the host before it migrates, so
  they would run against the old schema. The host's next ordinary start
  runs them. The check is here, not at a call site, so `boot/1`, a direct
  call and the deprecated `PhoenixKit.Integrations.run_legacy_migrations/0`
  are all covered.

  Returns a summary map: `%{module_atom => :ok | {:error, term()}}`.
  """
  @spec run_all_legacy_migrations() :: %{module() => :ok | {:error, term()}}
  def run_all_legacy_migrations do
    if Application.get_env(:phoenix_kit, :update_mode, false) do
      Logger.debug("[ModuleRegistry] update_mode: module legacy migrations skipped")
      %{}
    else
      run_each_legacy_migration()
    end
  end

  defp run_each_legacy_migration do
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
  catch
    # A throw or exit in one module's callback must not take down the page
    # (or the boot) that collects every module's answer.
    kind, reason ->
      Logger.warning(
        "[ModuleRegistry] #{inspect(mod)}.#{fun}/0 failed: #{inspect({kind, reason})}"
      )

      default
  end
end
