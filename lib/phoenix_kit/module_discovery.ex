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

  The cache is dropped by `clear_cache/0` and rebuilt by `refresh_cache/0`.
  `PhoenixKit.ModuleRegistry` refreshes it at boot and on `rescan/0` and drops it
  on `register/1` / `unregister/1`. Concurrent cold readers share one scan. The
  cache also reflects `config :phoenix_kit, :modules` as of the scan.
  """
  @spec cached_external_modules() :: [module()]
  def cached_external_modules do
    case :persistent_term.get(@cache_key, :unset) do
      :unset -> scan_once()
      modules -> modules
    end
  end

  # Concurrent cold readers (several LiveView mounts after a restart) queue on
  # one lock instead of each running the full scan; whoever gets it second finds
  # the cache already filled.
  defp scan_once do
    :global.trans({{__MODULE__, :scan}, self()}, fn ->
      case :persistent_term.get(@cache_key, :unset) do
        :unset -> refresh_cache()
        modules -> modules
      end
    end)
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
  within the filesystem's timestamp resolution is never missed.

  The assumption is that a rebuild leaves a new mtime or size on the files it
  writes, as Mix and `erlc` do. A file replaced by one of the same size *and* the
  same mtime (`cp -p`, `rsync -t` from an older build) is not seen — use
  `module_hash/0` where that matters.

  A miss costs one scan plus the `stat`s of the fingerprint (it builds the hash
  from the same directory listings the fingerprint needs, so nothing is listed or
  read twice); the first call of a VM is always a miss. Any error falls back to
  `module_hash/0`.
  """
  @spec module_hash_fast() :: binary()
  def module_hash_fast do
    with {fingerprint, hash, %{app_files: _, beam_files: _} = inventory} <-
           :persistent_term.get(@hash_memo_key, nil),
         {^fingerprint, _newest} <- scan_fingerprint(inventory, candidate_ebin_dirs()) do
      hash
    else
      _ -> recompute_module_hash()
    end
  rescue
    # A memo of another shape (module reloaded with a different layout) or a
    # failing stat must never take a Mix compile down; the honest answer exists.
    _ -> module_hash()
  end

  # Order matters: the fingerprint is taken BEFORE the scan, so a change landing
  # in between leaves a stale fingerprint (one more scan next time), never a
  # fresh one paired with an old hash. The code path is read ONCE, so the
  # inventory and the fingerprint describe the same directories.
  defp recompute_module_hash do
    dirs = candidate_ebin_dirs()
    inventory = scan_inventory(dirs)
    {fingerprint, newest} = scan_fingerprint(inventory, dirs)
    hash = hash_from_inventory(inventory)

    if newest < System.os_time(:second) - @settled_after_seconds do
      :persistent_term.put(@hash_memo_key, {fingerprint, hash, inventory})
    else
      :persistent_term.erase(@hash_memo_key)
    end

    hash
  end

  @doc false
  # Drops the remembered `module_hash_fast/0` fingerprint. For tests.
  @spec clear_hash_memo() :: :ok
  def clear_hash_memo do
    :persistent_term.erase(@hash_memo_key)
    :ok
  end

  # What the fingerprint stats: the `.app` files of every code-path dir, and the
  # beams of the dependent apps. Lists each directory once — slow path only —
  # and is what `hash_from_inventory/1` computes the hash from.
  defp scan_inventory(dirs) do
    app_files = Map.new(dirs, &{&1, files_with_extension(&1, ".app")})

    beam_files =
      for dir <- dirs, depends_on_phoenix_kit?(dir, app_files[dir]), into: %{} do
        {dir, files_with_extension(dir, ".beam")}
      end

    %{app_files: app_files, beam_files: beam_files}
  end

  # Same selection as `read_app_spec/1` + `ebin_depends_on_phoenix_kit?/1`: the
  # first `.app` of the directory.
  defp depends_on_phoenix_kit?(_dir, []), do: false

  defp depends_on_phoenix_kit?(dir, [app_file | _]) do
    case :file.consult(String.to_charlist(Path.join(dir, app_file))) do
      {:ok, [{:application, app, keys}]} ->
        app != :phoenix_kit and :phoenix_kit in Keyword.get(keys, :applications, [])

      _ ->
        false
    end
  rescue
    _ -> false
  end

  # `module_hash/0`, from the listings already in hand instead of walking the
  # disk again. Bit-for-bit the same value (a test compares them).
  defp hash_from_inventory(%{beam_files: beam_files}) do
    scanned =
      beam_files
      |> Enum.flat_map(fn {dir, names} ->
        Enum.map(names, &beam_phoenix_kit_module(Path.join(dir, &1)))
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    (scanned ++ Application.get_env(:phoenix_kit, :modules, []))
    |> Enum.uniq()
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:erlang.md5/1)
  rescue
    _ -> module_hash()
  end

  # Names with `extension`, sorted, excluding dotfiles exactly as the
  # `Path.wildcard/1` the scan itself uses does.
  defp files_with_extension(dir, extension) do
    case :file.list_dir(String.to_charlist(dir)) do
      {:ok, names} ->
        names
        |> Enum.map(&List.to_string/1)
        |> Enum.filter(&(Path.extname(&1) == extension and not String.starts_with?(&1, ".")))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  # `{fingerprint, newest_mtime}` for the current disk state of `dirs`, by `stat`
  # alone. A dir the inventory has never seen fingerprints as `:unknown`, so a
  # changed code path never matches — and such a fingerprint is never
  # remembered (its newest mtime is reported as `:infinity`; an atom sorts after
  # every number, so the "settled" comparison is false).
  defp scan_fingerprint(%{app_files: app_files, beam_files: beam_files}, dirs) do
    app_stats =
      Enum.map(dirs, fn dir ->
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

    newest =
      if Enum.any?(app_stats, &match?({_, :unknown}, &1)),
        do: :infinity,
        else: Enum.max(mtimes, fn -> 0 end)

    {{app_stats, beam_stats, Application.get_env(:phoenix_kit, :modules, [])}, newest}
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

  # `:file_info` is `{:file_info, size, type, access, atime, mtime, ...}`: element
  # 1 is the size, element 5 the mtime (POSIX seconds here).
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
