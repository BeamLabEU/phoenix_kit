defmodule PhoenixKit.ModuleDiscovery do
  @moduledoc """
  Zero-config auto-discovery of external PhoenixKit modules.

  Uses the same pattern as Elixir's protocol consolidation: scans `.beam` files
  for persisted `@phoenix_kit_module` attributes via `:beam_lib.chunks/2`.
  No module loading required — pure file I/O.

  ## How It Works

  1. `use PhoenixKit.Module` persists `@phoenix_kit_module true` in the `.beam` file
  2. This module scans only deps that depend on `:phoenix_kit` (fast, targeted)
  3. Reads the persisted attribute from each beam file without loading the module
  4. Works at both compile time (route generation) and runtime (ModuleRegistry)

  ## Fallback

  Also reads `Application.get_env(:phoenix_kit, :modules, [])` for backwards
  compatibility. Both sources are merged and deduplicated.
  """

  require Logger

  @cache_key {__MODULE__, :external_modules}

  @doc """
  Discovers external PhoenixKit modules from beam files + config fallback.

  Returns a deduplicated list of module atoms that implement `PhoenixKit.Module`.
  Excludes internal modules (those in the `PhoenixKit.Modules` namespace that are
  bundled with PhoenixKit itself).
  """
  @spec discover_external_modules() :: [module()]
  def discover_external_modules do
    scanned = scan_beam_files()
    configured = Application.get_env(:phoenix_kit, :modules, [])
    Enum.uniq(scanned ++ configured)
  end

  @doc """
  Like `discover_external_modules/0`, but scans the disk once per VM and then
  answers from `:persistent_term`.

  **Runtime callers only** (the admin Modules page, `PhoenixKit.ModuleRegistry`).
  The scan reads every beam file of every phoenix_kit-dependent dep, which takes
  seconds on a cold or busy disk, while the set it finds only changes when the
  release is rebuilt. Compile-time callers (router macros, `module_hash/0`, the
  Mix compilers) must keep using `discover_external_modules/0`: a long-lived
  `iex -S mix` / code-reloader VM recompiles against a changing disk and has to
  see it.

  The cache is dropped by `clear_cache/0` and rebuilt by `refresh_cache/0`;
  `PhoenixKit.ModuleRegistry` does both wherever it registers, unregisters or
  rescans. It also reflects `config :phoenix_kit, :modules` as of the first read.
  """
  @spec cached_external_modules() :: [module()]
  def cached_external_modules do
    case :persistent_term.get(@cache_key, :unset) do
      :unset -> refresh_cache()
      modules -> modules
    end
  end

  @doc """
  Scans the disk now (`discover_external_modules/0`), stores the result for
  `cached_external_modules/0` and returns it.
  """
  @spec refresh_cache() :: [module()]
  def refresh_cache do
    modules = discover_external_modules()
    :persistent_term.put(@cache_key, modules)
    modules
  end

  @doc "Drops the cached scan; the next `cached_external_modules/0` call scans again."
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc """
  Returns a deterministic hash of the current set of discovered external modules.

  Used by `__mix_recompile__?/0` (injected into the host router) to detect when
  modules are added or removed, triggering router recompilation. Always scans the
  disk — it must never be answered from the runtime cache.
  """
  @spec module_hash() :: binary()
  def module_hash do
    discover_external_modules()
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:erlang.md5/1)
  end

  @doc """
  Scans beam files of phoenix_kit-dependent apps for `@phoenix_kit_module` attribute.

  Walks dependency `ebin` directories on disk (pure file I/O) rather than relying
  on `:application.loaded_applications/0`, so it is deterministic at compile time —
  it returns the same set whether or not the apps happen to be loaded yet. An app
  qualifies when its `<app>.app` lists `:phoenix_kit` in `applications`; its beams
  are then read with `:beam_lib.chunks/2` to keep the ones carrying
  `@phoenix_kit_module true`. No module loading required.
  """
  @spec scan_beam_files() :: [module()]
  def scan_beam_files do
    phoenix_kit_dependent_ebin_dirs()
    |> Enum.flat_map(&beam_modules_in_dir/1)
    |> Enum.uniq()
  rescue
    error ->
      Logger.warning("[ModuleDiscovery] Beam scanning failed: #{Exception.message(error)}")
      []
  end

  @doc """
  Returns the names of dependency apps on disk that declare `:phoenix_kit` in their
  `applications` (i.e. via `extra_applications`).

  Filesystem-based, independent of load state. Used by the CSS-sources compiler to
  warn when discovery yields zero sources even though phoenix_kit-dependent deps
  are present.
  """
  @spec phoenix_kit_dependent_apps() :: [atom()]
  def phoenix_kit_dependent_apps do
    phoenix_kit_dependent_ebin_dirs()
    |> Enum.map(&app_name_for_ebin/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  # ebin directories whose `<app>.app` depends on :phoenix_kit (excludes phoenix_kit itself).
  defp phoenix_kit_dependent_ebin_dirs do
    candidate_ebin_dirs()
    |> Enum.filter(&ebin_depends_on_phoenix_kit?/1)
  end

  # All ebin directories that might hold compiled deps. The code path covers both
  # compile time and runtime: during `mix compile` the `deps.loadpaths` task prepends
  # every dep's ebin to the code path *before* compilers run, so freshly compiled deps
  # are present even on a cold build (`rm -rf _build`); at runtime it holds the loaded
  # apps' ebins. Crucially this is independent of `:application.loaded_applications/0`,
  # which is what made discovery nondeterministic at compile time.
  defp candidate_ebin_dirs do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  defp ebin_depends_on_phoenix_kit?(dir) do
    case read_app_spec(dir) do
      {app, keys} ->
        app != :phoenix_kit and :phoenix_kit in Keyword.get(keys, :applications, [])

      nil ->
        false
    end
  end

  defp app_name_for_ebin(dir) do
    case read_app_spec(dir) do
      {app, _keys} -> app
      nil -> nil
    end
  end

  # Reads the `<app>.app` resource file from an ebin dir as `{app_name, keys}`.
  # Pure file read — does not load the application.
  defp read_app_spec(dir) do
    with [app_file | _] <- Path.wildcard(Path.join(dir, "*.app")),
         {:ok, [{:application, app, keys}]} <- :file.consult(String.to_charlist(app_file)) do
      {app, keys}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp beam_modules_in_dir(dir) do
    dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.map(&beam_phoenix_kit_module/1)
    |> Enum.reject(&is_nil/1)
  end

  # Reads the persisted `@phoenix_kit_module` attribute via :beam_lib.chunks/2
  # without loading the module. Returns the module atom (which :beam_lib resolves
  # from the beam itself, so no String.to_existing_atom fragility) or nil.
  defp beam_phoenix_kit_module(path) do
    case :beam_lib.chunks(String.to_charlist(path), [:attributes]) do
      {:ok, {module, [{:attributes, attrs}]}} ->
        if attrs[:phoenix_kit_module] == [true], do: module

      _ ->
        nil
    end
  end
end
