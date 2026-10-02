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

  @hash_memo_key {__MODULE__, :module_hash_memo}

  # An mtime this recent cannot be told apart from "changed again a moment
  # later" on a filesystem with whole-second timestamps, so a fingerprint that
  # contains one is never remembered.
  @settled_after_seconds 2

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
  Returns a deterministic hash of the current set of discovered external modules.

  Used at compile time for the hash baked into the host router (see
  `module_hash_fast/0` for the per-compile check in `__mix_recompile__?/0`) to detect when
  modules are added or removed, triggering router recompilation.
  """
  @spec module_hash() :: binary()
  def module_hash do
    discover_external_modules()
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:erlang.md5/1)
  end

  @doc """
  Same answer as `module_hash/0`, without re-reading the beams when nothing on
  disk changed since the last call.

  Meant for `__mix_recompile__?/0`, which Mix evaluates on every compile — and
  `Phoenix.CodeReloader` compiles on every dev request, so `module_hash/0` there
  re-ran the whole scan per HTTP request.

  It fingerprints what the scan reads, with `stat` only — no beam is opened and no
  directory is listed: the mtime of every code-path directory (a file added to or
  removed from one changes it), plus mtime and size of the `.app` files and of the
  beams of the dependent apps found by the last full scan (a dep that starts or
  stops depending on `:phoenix_kit`, a module gaining or losing
  `@phoenix_kit_module`), and `config :phoenix_kit, :modules`. The full scan runs
  when the fingerprint differs from the remembered one, and nothing is remembered
  while any of it is newer than #{@settled_after_seconds} seconds, so a change
  within the filesystem's timestamp resolution is never missed. The first call of
  a VM costs a scan, like `module_hash/0`.
  """
  @spec module_hash_fast() :: binary()
  def module_hash_fast do
    case :persistent_term.get(@hash_memo_key, nil) do
      {fingerprint, hash, inventory} ->
        case scan_fingerprint(inventory) do
          {^fingerprint, _newest} -> hash
          _ -> recompute_module_hash()
        end

      nil ->
        recompute_module_hash()
    end
  end

  # Order matters: the fingerprint is taken BEFORE the scan, so a change landing
  # in between leaves a stale fingerprint (one more scan next time), never a
  # fresh one paired with an old hash.
  defp recompute_module_hash do
    inventory = scan_inventory()
    {fingerprint, newest} = scan_fingerprint(inventory)
    hash = module_hash()

    if newest < System.os_time(:second) - @settled_after_seconds do
      :persistent_term.put(@hash_memo_key, {fingerprint, hash, inventory})
    else
      :persistent_term.erase(@hash_memo_key)
    end

    hash
  rescue
    # Whatever went wrong while stat-ing, the honest answer is still available.
    _ -> module_hash()
  end

  @doc false
  # Drops the remembered `module_hash_fast/0` fingerprint. For tests.
  @spec clear_hash_memo() :: :ok
  def clear_hash_memo do
    :persistent_term.erase(@hash_memo_key)
    :ok
  end

  # Which files the fingerprint stats: the `.app` files of every code-path dir
  # and the beams of the dependent apps. Lists directories — slow path only.
  defp scan_inventory do
    %{
      app_files: Map.new(candidate_ebin_dirs(), &{&1, files_with_extension(&1, ".app")}),
      beam_files:
        Map.new(phoenix_kit_dependent_ebin_dirs(), &{&1, files_with_extension(&1, ".beam")})
    }
  end

  defp files_with_extension(dir, extension) do
    case :file.list_dir(String.to_charlist(dir)) do
      {:ok, names} ->
        names
        |> Enum.map(&List.to_string/1)
        |> Enum.filter(&(Path.extname(&1) == extension))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  # `{fingerprint, newest_mtime}` for the current disk state, by `stat` alone.
  # A code-path dir the inventory has never seen fingerprints as `:unknown`, so
  # a changed code path never matches.
  defp scan_fingerprint(%{app_files: app_files, beam_files: beam_files}) do
    app_stats =
      Enum.map(candidate_ebin_dirs(), fn dir ->
        case app_files do
          %{^dir => names} -> dir_stats(dir, names)
          _ -> {dir, :unknown}
        end
      end)

    beam_stats =
      beam_files |> Enum.sort() |> Enum.map(fn {dir, names} -> dir_stats(dir, names) end)

    mtimes =
      for {_dir, dir_mtime, files} <-
            Enum.reject(app_stats, &match?({_, :unknown}, &1)) ++ beam_stats,
          mtime <- [dir_mtime | Enum.map(files, fn {_name, mtime, _size} -> mtime end)],
          do: mtime

    {{app_stats, beam_stats, Application.get_env(:phoenix_kit, :modules, [])},
     Enum.max(mtimes, fn -> 0 end)}
  end

  # `{dir, dir_mtime, [{name, mtime, size}]}`, mtimes in POSIX seconds. A missing
  # path stats as mtime 0 / size -1, so its disappearing changes the fingerprint.
  defp dir_stats(dir, names) do
    {dir_mtime, _size} = stat(dir)

    {dir, dir_mtime,
     Enum.map(names, fn name ->
       {mtime, size} = stat(Path.join(dir, name))
       {name, mtime, size}
     end)}
  end

  defp stat(path) do
    case :file.read_file_info(String.to_charlist(path), [:raw, {:time, :posix}]) do
      {:ok, info} -> {elem(info, 5), elem(info, 1)}
      {:error, _} -> {0, -1}
    end
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
