defmodule Mix.Tasks.Compile.PhoenixKitJsSources do
  @moduledoc """
  Mix compiler that vendors PhoenixKit's JS hooks into the host app.

  This compiler keeps the vendored files current on **every** `mix compile`:

  1. `priv/static/assets/vendor/phoenix_kit.js` — a straight copy of
     PhoenixKit's own core hooks file. Previously this was only copied once,
     by `mix phoenix_kit.install`/`mix phoenix_kit.update` (`File.cp/2` in
     `PhoenixKit.Install.JsIntegration`) — a deploy that does `rm -rf
     priv/static` + rebuild without re-running `phoenix_kit.update` (i.e. most
     CI/CD pipelines) shipped a 404 on this file, silently breaking every
     PhoenixKit JS hook. Vendoring it from a compiler makes it self-healing:
     it comes back on the next `mix compile`, with zero dependency on
     `phoenix_kit.update` ever having run again after install.
  2. `priv/static/assets/vendor/phoenix_kit_modules.js` — external modules
     declare prebuilt hook bundles via `js_sources/0` (see `PhoenixKit.Module`);
     this compiler discovers them via `PhoenixKit.ModuleDiscovery`, resolves
     each bundle's absolute path via `:code.priv_dir/1` (works for Hex installs
     and path deps alike), and concatenates them (each wrapped in an IIFE so
     their top-level scopes can't collide) into this file, followed by a merge
     that folds each bundle's `window.<Global>` into `window.PhoenixKitHooks`
     (which the host spreads into `LiveSocket`).

  3. `priv/static/assets/vendor/lib/admin-<version>-<hash>.js` — the second
     half of PhoenixKit's hook bundle. `phoenix_kit.js` holds the hooks a
     public page can render and a stub under the name of every hook that
     belongs to the admin area or the user dashboard; the first stub to mount
     loads this file (as the `"admin"` library named in the install facts).
     Public pages never download it. See
     `dev_docs/plans/2026-10-27-public-admin-js-split.md`.

  Every write is diffed against the existing file first, so a `mix compile`
  that changes nothing doesn't touch any file (avoids live-reload thrash).

  ## Minified in production

  In production (or with `config :phoenix_kit, minify_libraries: true`) the
  vendored `phoenix_kit.js`, `phoenix_kit_modules.js` and the admin bundle are
  minified with the host's own esbuild — the binary `mix assets.deploy`
  installs, so run `mix assets.setup` before the compile that builds a release.
  A host without it, or a minify that fails, gets the readable files and a
  note, never a failed build. `config :phoenix_kit, js_minifier: {Mod, :fun}`
  names another minifier. Minifying what is already minified is harmless, so
  a host that runs the result through its own pipeline loses nothing.

  ## Where the browser finds the libraries

  The facts in `phoenix_kit_modules.js` carry the URL the library files are
  served from (`window.PHOENIX_KIT_LIB_BASE`, `/assets/vendor/lib/` unless
  `config :phoenix_kit, library_base_url: "…"` says otherwise), so they are
  found wherever that file itself is served from. A value the host puts on
  `window` first wins.

  The two `<script>` tags are **stable**: adding or removing a JS-bearing
  module only changes `phoenix_kit_modules.js`'s content on the next compile —
  never the host's layout — so it stays zero-config like `css_sources/0`.

  ## Setup (one-time, by `mix phoenix_kit.install`)

      # mix.exs
      compilers: [:phoenix_kit_js_sources, :phoenix_live_view] ++ Mix.compilers()

      # root.html.heex, before app.js
      <script src={~p"/assets/vendor/phoenix_kit.js"}></script>
      <script src={~p"/assets/vendor/phoenix_kit_modules.js"}></script>

  Failures are loud: a missing core JS file (corrupted/incomplete dependency
  fetch) or a declared module bundle that can't be resolved raises a compile
  error rather than silently shipping "unknown hook" console errors.

  ## This is a fast path, not the only way

  It used to be the only way, on the reasoning that a hook had to be in the
  host's single `LiveSocket` at construction time because a nested LiveView
  could not register one at runtime. That stopped being true in LiveView 1.1:
  `getHookDefinition/1` resolves a hook name when its element mounts, and falls
  back to a `script[data-phx-runtime-hook="Name"]` in the document whose
  `window.phx_hook_<Name>()` returns the callbacks. LiveView re-creates such a
  script when a patch adds it, so it works on a page delivered over the socket
  as well as in the first HTML.

  A module can therefore ship its hooks itself and ask nothing of the host —
  `phoenix_kit_boards` does, after two releases where `js_sources/0` alone
  silently delivered nothing to hosts that bundle dependency JS their own way.
  The host's own registration still wins (`getHookDefinition` checks
  `liveSocket.hooks` first), so the two never collide and this compiler stays
  the cheaper path where it is set up.

  What it must not be is a *silent* requirement. `PhoenixKitWeb.Integration`
  warns at compile time when installed modules declare `js_sources/0` and this
  compiler is absent from the host's `:compilers` — the state where those
  modules' hooks are never delivered, no error appears anywhere, and only the
  feature is missing.
  """

  use Mix.Task.Compiler

  alias PhoenixKit.Install.ViewerLibraries

  require Logger

  @core_js_filename "phoenix_kit.js"
  @admin_js_filename "phoenix_kit_admin.js"
  @core_js_output "priv/static/assets/vendor/phoenix_kit.js"

  @output "priv/static/assets/vendor/phoenix_kit_modules.js"

  @impl true
  def run(_args) do
    # Ensure all dep applications are loaded so module discovery + priv_dir work.
    for dep <- Mix.Dep.cached() do
      Application.ensure_loaded(dep.app)
    end

    vendor_all(File.cwd!())
    {:ok, []}
  end

  @doc """
  Vendors everything the browser half needs into `root`, together: the core
  bundle, the viewer/editor libraries (`PhoenixKit.Install.ViewerLibraries`)
  and `#{@output}` — the module bundles plus the install facts naming those
  libraries. The bundle names no library URL of its own any more, so it must
  never arrive without the facts; `mix phoenix_kit.update` and
  `phoenix_kit.install` call this same function for hosts that do not run
  the compiler.
  """
  def vendor_all(root) do
    vendor_core_js_file(root)

    specs = collect_specs()
    libs = ViewerLibraries.vendor!(root) |> Map.put("admin", vendor_admin_bundle(root, specs))

    content = specs |> build_content(libs) |> ViewerLibraries.maybe_minify(@output)

    path = Path.join(root, @output)
    write_if_changed(path, content, length(specs))
    :ok
  end

  # ── Core hooks file vendoring ───────────────────────────────────────

  # Copies PhoenixKit's own priv/static/assets/phoenix_kit.js into the host's
  # vendor/ directory. Runs on every compile — unlike the old one-shot
  # `File.cp/2` in `phoenix_kit.install`/`phoenix_kit.update`, this survives a
  # `rm -rf priv/static` in a deploy pipeline that only runs `mix compile`.
  defp vendor_core_js_file(root) do
    content =
      @core_js_filename
      |> read_core_asset!()
      |> ViewerLibraries.maybe_minify(@core_js_output)

    dest = Path.join(root, @core_js_output)

    existing =
      case File.read(dest) do
        {:ok, data} -> data
        _ -> nil
      end

    if existing != content do
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, content)
      Mix.shell().info("[PhoenixKit] Vendored #{@core_js_output}")
    end
  end

  # The admin half of the hook bundle, as a library of its own: a versioned,
  # content-hashed name under vendor/lib/, which the facts hand to
  # phoenix_kit.js. Returns the fact.
  defp vendor_admin_bundle(root, specs) do
    content = build_admin_content(read_core_asset!(@admin_js_filename), admin_specs(specs))
    vsn = to_string(Application.spec(:phoenix_kit, :vsn) || "0")
    ViewerLibraries.vendor_generated!(root, "admin", vsn, content)
  end

  # One of PhoenixKit's own bundles from its priv/, read from wherever the
  # dependency was installed. Fails loud: a missing file is a broken fetch.
  defp read_core_asset!(filename) do
    priv =
      case :code.priv_dir(:phoenix_kit) do
        {:error, :bad_name} ->
          Mix.raise("""
          Could not resolve the :phoenix_kit application's priv/ directory
          while vendoring #{filename}. Is :phoenix_kit listed as a
          dependency of this app?
          """)

        dir ->
          to_string(dir)
      end

    source = Path.join([priv, "static", "assets", filename])

    unless File.exists?(source) do
      Mix.raise("""
      Could not find #{filename} at #{source} — the :phoenix_kit
      dependency looks corrupted or incompletely fetched. Try `mix deps.get`.
      """)
    end

    File.read!(source)
  end

  # ── Discovery ────────────────────────────────────────────────────

  # Returns a deterministic list of %{app, file, global, source} maps.
  defp collect_specs do
    PhoenixKit.ModuleDiscovery.discover_external_modules()
    |> Enum.flat_map(fn mod ->
      if Code.ensure_loaded?(mod) and function_exported?(mod, :js_sources, 0) do
        mod.js_sources()
      else
        []
      end
    end)
    |> Enum.map(&normalize_entry/1)
    # Deterministic order; dedupe identical (app, file) declarations.
    |> Enum.uniq_by(fn s -> {s.app, s.file} end)
    |> Enum.sort_by(fn s -> {to_string(s.app), s.file} end)
    |> tap(&check_unique_globals/1)
    |> tap(&check_unique_hooks/1)
    |> Enum.map(&resolve_source/1)
  end

  # Two distinct bundles assigning the same window.<Global> would clobber each
  # other (last bundle wins; the merge dedupes the global), silently dropping the
  # earlier module's hooks. Fail loud instead.
  @doc false
  def check_unique_globals(specs) do
    dupes =
      specs
      |> Enum.group_by(& &1.global)
      |> Enum.filter(fn {_global, entries} -> length(entries) > 1 end)

    unless dupes == [] do
      detail =
        Enum.map_join(dupes, "\n", fn {global, entries} ->
          apps = Enum.map_join(entries, ", ", fn e -> "#{e.app}:#{e.file}" end)
          "  window.#{global} <- #{apps}"
        end)

      Mix.raise("""
      Multiple js_sources/0 bundles declare the same window global, so the later
      bundle would clobber the earlier one's hooks:

      #{detail}

      Each module's bundle must assign a unique window.<Global>. Rename one.
      """)
    end

    :ok
  end

  @doc false
  def normalize_entry(%{app: app, file: file, global: global} = entry)
      when is_atom(app) and is_binary(file) and is_binary(global) do
    # `global` is emitted as `window.<global>` in the generated JS, so an
    # invalid identifier (e.g. "foo-bar") would produce broken JS — fail loud.
    unless Regex.match?(~r/^[A-Za-z_$][A-Za-z0-9_$]*$/, global) do
      Mix.raise("""
      Invalid js_sources/0 :global #{inspect(global)} — must be a valid JavaScript
      identifier (it is emitted as window.<global> and folded into PhoenixKitHooks).
      """)
    end

    base = %{app: app, file: file, global: global}

    # A public entry keeps exactly the shape it always had; only an admin
    # entry carries the two extra keys.
    case Map.get(entry, :scope, :public) do
      :public ->
        base

      :admin ->
        Map.merge(base, %{scope: :admin, hooks: validate_hooks!(Map.get(entry, :hooks), base)})

      other ->
        Mix.raise("""
        Invalid js_sources/0 :scope #{inspect(other)} for #{inspect(app)}:#{file} — it is
        :public (the default: the bundle loads on every page) or :admin (it loads
        on demand, on the first mount of one of the hooks the entry lists).
        """)
    end
  end

  def normalize_entry(other) do
    Mix.raise("""
    Invalid js_sources/0 entry: #{inspect(other)}

    Each entry must be a map with :app (atom), :file (string, relative to the
    app's priv/), and :global (string, the window.<Name> the bundle assigns).
    """)
  end

  # An admin bundle is reached through stubs registered under the hook names the
  # entry declares — the compiler cannot see inside a prebuilt bundle, and a
  # hook the page does not have a name for can never be mounted. So the names
  # are required, and must be what LiveView will look up.
  defp validate_hooks!(hooks, %{app: app, file: file}) do
    valid? =
      is_list(hooks) and hooks != [] and
        Enum.all?(hooks, &(is_binary(&1) and Regex.match?(~r/^[A-Za-z_$][A-Za-z0-9_$]*$/, &1))) and
        length(Enum.uniq(hooks)) == length(hooks)

    unless valid? do
      Mix.raise("""
      Invalid js_sources/0 :hooks #{inspect(hooks)} for #{inspect(app)}:#{file}.

      An entry with `scope: :admin` must list, in `hooks:`, the name of every hook its
      bundle exports (distinct strings, valid JavaScript identifiers). The page gets a
      stub under each name; the bundle loads on the first mount of any of them.
      """)
    end

    hooks
  end

  # Two admin bundles declaring one hook name would be one stub, mounting
  # whichever body the later fold left behind.
  @doc false
  def check_unique_hooks(specs) do
    dupes =
      specs
      |> admin_specs()
      |> Enum.flat_map(fn s -> Enum.map(s.hooks, &{&1, s}) end)
      |> Enum.group_by(fn {name, _} -> name end, fn {_, s} -> "#{s.app}:#{s.file}" end)
      |> Enum.filter(fn {_name, apps} -> length(apps) > 1 end)

    unless dupes == [] do
      detail =
        Enum.map_join(dupes, "\n", fn {name, apps} -> "  #{name} <- #{Enum.join(apps, ", ")}" end)

      Mix.raise("""
      Multiple js_sources/0 admin bundles declare the same hook name, so one stub would
      stand for two bodies:

      #{detail}

      Namespace the hook names of each module (see PhoenixKit.Module.js_sources/0).
      """)
    end

    :ok
  end

  @doc false
  def admin_specs(specs), do: Enum.filter(specs, &(Map.get(&1, :scope, :public) == :admin))

  defp public_specs(specs), do: Enum.reject(specs, &(Map.get(&1, :scope, :public) == :admin))

  # Resolve the bundle's absolute path via the app's priv dir. Fail loud.
  defp resolve_source(%{app: app, file: file} = spec) do
    priv =
      case :code.priv_dir(app) do
        {:error, :bad_name} ->
          Mix.raise("""
          js_sources/0 references app #{inspect(app)}, but it isn't an available
          application. Add it as a dependency of the module declaring it.
          """)

        dir ->
          to_string(dir)
      end

    source = Path.join(priv, file)

    unless File.exists?(source) do
      Mix.raise("""
      js_sources/0 bundle not found: #{source}

      App #{inspect(app)} declared js_sources file #{inspect(file)} (resolved under
      its priv/), but no such file exists. The bundle must ship in the app's priv/.
      """)
    end

    Map.put(spec, :source, source)
  end

  # ── Content ──────────────────────────────────────────────────────

  @doc false
  def build_content(specs, libs \\ %{}) do
    public = public_specs(specs)
    admin = admin_specs(specs)

    """
    /* Auto-generated by PhoenixKit — do not edit manually.
       #{header_line(specs, public)} */
    #{globals_preamble(libs)}
    #{public_bundles(public)}#{admin_stubs(admin)}
    """
  end

  defp header_line([], _), do: "No external module declares js_sources/0."

  defp header_line(_specs, []),
    do: "No module bundle is loaded on every page (admin bundles load on demand)."

  defp header_line(_specs, _public),
    do: "Concatenated module hook bundles (js_sources/0), loaded before app.js."

  defp public_bundles([]), do: ""

  defp public_bundles(specs) do
    globals =
      specs
      |> Enum.map(& &1.global)
      |> Enum.uniq()
      |> Enum.map_join(",", fn g -> "window.#{g}||{}" end)

    # NOTE: `check_unique_globals/1` guarantees distinct window.<Global> names,
    # but this Object.assign is still last-write-wins on the HOOK NAMES inside
    # each bundle — and it folds over the core window.PhoenixKitHooks too. Two
    # modules exporting a same-named hook (or one shadowing a core hook) clobber
    # silently; we can't detect that without parsing the bundles. js_sources/0's
    # docs tell modules to namespace their hook names accordingly.
    """
    #{wrap_bundles(specs)}
    /* Fold each module's hooks into window.PhoenixKitHooks (spread into LiveSocket by app.js). */
    window.PhoenixKitHooks=Object.assign(window.PhoenixKitHooks||{},#{globals});
    """
  end

  # Wrap each prebuilt bundle in an IIFE so its top-level declarations can't
  # collide with another bundle's. Bundles export via window.<Global>, which
  # survives the wrapper. Leading `;` guards against ASI hazards.
  defp wrap_bundles(specs) do
    Enum.map_join(specs, "\n", fn %{app: app, source: source} ->
      body = File.read!(source)

      """
      /* #{app} */
      ;(function(){
      #{body}
      })();
      """
    end)
  end

  # The names of the hooks whose code is in the admin bundle. They are handed to
  # phoenix_kit.js, which registers a stub under each in window.PhoenixKitHooks
  # — whichever of the two scripts runs first: the names wait on the window for
  # a phoenix_kit.js that has not run yet, and go straight in when it has.
  defp admin_stubs([]), do: ""

  defp admin_stubs(specs) do
    names = specs |> Enum.flat_map(& &1.hooks) |> Enum.uniq() |> Jason.encode!()

    """
    /* Admin hooks of modules: stubs now, the code loads with the admin bundle on first use. */
    (function(n){var w=window;w.PhoenixKitModuleAdminHooks=(w.PhoenixKitModuleAdminHooks||[]).concat(n);if(w.PhoenixKitRegisterAdminStubs)w.PhoenixKitRegisterAdminStubs(n)})(#{names});
    """
  end

  @doc false
  # Core's admin file, then each admin module's bundle (wrapped like the public
  # ones), then the fold into the namespace the stubs read from. With no admin
  # module it is core's file as it is.
  def build_admin_content(core, []), do: core

  def build_admin_content(core, specs) do
    globals =
      specs
      |> Enum.map(& &1.global)
      |> Enum.uniq()
      |> Enum.map_join(",", fn g -> "window.#{g}||{}" end)

    """
    #{core}
    /* Admin hook bundles of modules (js_sources/0, scope: :admin). */
    #{wrap_bundles(specs)}
    window.PhoenixKitAdminHooks=Object.assign(window.PhoenixKitAdminHooks||{},#{globals});
    """
  end

  # Facts the vendored bundle cannot work out for itself, written into a file
  # that is already `<script>`-tagged so this needs no layout edit and no
  # `phoenix_kit.update` backfill.
  #
  # - `PHOENIX_KIT_PREFIX`: the bundle guessed `"/phoenix_kit"`, so every host
  #   on a custom prefix requested consent config from a path that does not
  #   exist. It now knows.
  # - `PHOENIX_KIT_CONSENT_AVAILABLE`: whether `phoenix_kit_legal` is installed
  #   at all. When it is not, the bundle skips the request instead of firing one
  #   per page load just to be told 204.
  #
  # - `PHOENIX_KIT_LIBS`: the vendored viewer/editor libraries' file names
  #   (and, only when the host opted in, a CDN fallback URL each), so the
  #   bundle loads them from this host's origin without naming a version.
  #
  # This file loads after `phoenix_kit.js`, which is fine: the consent code
  # reads both on `DOMContentLoaded`, and the library loader reads the
  # library facts when a library is first needed — both after both scripts
  # have run.
  defp globals_preamble(libs) do
    prefix = PhoenixKit.Config.get_url_prefix()
    consent? = Code.ensure_loaded?(PhoenixKit.Modules.Legal)

    """
    /* Install facts for the vendored bundle. */
    window.PHOENIX_KIT_PREFIX=#{inspect(prefix)};
    window.PHOENIX_KIT_CONSENT_AVAILABLE=#{consent?};
    #{ViewerLibraries.base_js()}
    #{ViewerLibraries.facts_js(libs)}
    """
  end

  defp write_if_changed(path, content, spec_count) do
    existing =
      case File.read(path) do
        {:ok, data} -> data
        _ -> nil
      end

    if existing != content do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)

      Mix.shell().info("[PhoenixKit] Updated #{@output} with #{spec_count} module hook bundle(s)")
    end
  end
end
