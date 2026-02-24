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
  Scans beam files of phoenix_kit-dependent apps for `@phoenix_kit_module` attribute.

  Only checks apps that explicitly list `:phoenix_kit` in their dependencies,
  keeping the scan fast and targeted.
  """
  @spec scan_beam_files() :: [module()]
  def scan_beam_files do
    phoenix_kit_dependent_apps()
    |> Enum.flat_map(&app_phoenix_kit_modules/1)
  rescue
    error ->
      Logger.warning("[ModuleDiscovery] Beam scanning failed: #{Exception.message(error)}")
      []
  end

  # Find all loaded applications that depend on :phoenix_kit
  defp phoenix_kit_dependent_apps do
    for {app, _, _} <- :application.loaded_applications(),
        app != :phoenix_kit,
        depends_on_phoenix_kit?(app) do
      app
    end
  end

  defp depends_on_phoenix_kit?(app) do
    case :application.get_key(app, :applications) do
      {:ok, apps} -> :phoenix_kit in apps
      _ -> false
    end
  end

  # Get all PhoenixKit modules from a specific app
  defp app_phoenix_kit_modules(app) do
    case :application.get_key(app, :modules) do
      {:ok, modules} ->
        Enum.filter(modules, &phoenix_kit_module?/1)

      _ ->
        # App modules not available via :application, try beam file scan
        scan_app_ebin(app)
    end
  end

  # Check if a module has the @phoenix_kit_module persisted attribute.
  # First tries :code.which/1 to locate the beam file, then reads attributes
  # via :beam_lib.chunks/2 without fully loading the module into the VM.
  defp phoenix_kit_module?(mod) do
    case :code.which(mod) do
      :non_existing ->
        # Module not on code path — try loading it first, then re-check
        case Code.ensure_loaded(mod) do
          {:module, _} ->
            case :code.which(mod) do
              beam_path when is_list(beam_path) -> check_beam_attribute(beam_path)
              _ -> false
            end

          _ ->
            false
        end

      beam_path when is_list(beam_path) ->
        check_beam_attribute(beam_path)

      _ ->
        false
    end
  end

  defp check_beam_attribute(mod_or_path) do
    case :beam_lib.chunks(mod_or_path, [:attributes]) do
      {:ok, {_, [{:attributes, attrs}]}} ->
        attrs[:phoenix_kit_module] == [true]

      _ ->
        false
    end
  end

  # Fallback: scan the ebin directory directly for beam files
  defp scan_app_ebin(app) do
    dir = Application.app_dir(app, "ebin")

    dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.filter(&phoenix_kit_beam_file?/1)
    |> Enum.map(&beam_file_to_module/1)
  rescue
    _ -> []
  end

  defp phoenix_kit_beam_file?(path) do
    case :beam_lib.chunks(String.to_charlist(path), [:attributes]) do
      {:ok, {_, [{:attributes, attrs}]}} ->
        attrs[:phoenix_kit_module] == [true]

      _ ->
        false
    end
  end

  # Using String.to_atom/1 is safe here — we're scanning known ebin directories
  # of apps that depend on :phoenix_kit, so these atoms are expected to exist.
  defp beam_file_to_module(path) do
    path
    |> Path.basename(".beam")
    |> String.to_atom()
  end
end
