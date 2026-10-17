defmodule PhoenixKit.Install.ViewerLibraries do
  @moduledoc """
  Serves the viewer/editor libraries from the host's own origin.

  `phoenix_kit.js` used to lazy-load Fresco, Tessera, Etcher, Leaf,
  SortableJS, Panzoom and wavesurfer from `cdn.jsdelivr.net` at runtime. A host whose
  Content-Security-Policy is `script-src 'self'` silently lost the photo
  viewer's zoom, its sharper-version swap, annotations, the editor and the
  sortable lists; every viewer open made third-party requests; and the CDN
  tags had to be kept in step with the Hex versions by hand (they drifted
  twice). See `dev_docs/plans/2026-10-07-self-hosted-viewer-libraries.md`,
  Parts B1 and B2.

  `vendor!/1` copies each library into the host's
  `priv/static/assets/vendor/lib/` as `<name>-<version>-<hash>.js`:

    * The Hex libraries come from the **consumer's** installed dependency
      (`:code.priv_dir/1`), versioned by the consumer's loaded application
      version — not core's lockfile, which can resolve a different minor
      than the host does.
    * SortableJS, Panzoom, wavesurfer and Cally (npm-only) ship inside core, each
      at an exact version with its checksum, licence and provenance README
      (`priv/static/assets/vendor_libs/`).
    * The content hash is in the name because a path dependency can change
      its bytes without changing its version; with it, each name is
      cacheable for good.
    * Files are written only when absent and never deleted, so a rolling
      deploy or an open tab can still fetch the previous build's names —
      as far as the deployment itself keeps them (a clean release image does
      not; that retention is the deployment's, not the compiler's).

  ## Minified in production

  The Hex libraries are written readable, as published — Etcher alone is
  over a megabyte of commented source. A production build (or any build
  with `config :phoenix_kit, minify_libraries: true`) minifies them on the
  way in with the host's own esbuild, the binary `mix assets.deploy` already
  uses: Etcher goes from ~1.3 MB to ~450 KB (~370 KB to ~115 KB gzipped),
  Fresco from ~180 KB to ~60 KB. The minified copy is named
  `<name>-<version>-<hash>.min.js`, the hash still that of the source, so an
  unchanged library is not minified again. Dev builds keep the readable
  copy, so a stack trace points at real lines. A host without esbuild
  installed, or a minify that fails, gets the readable copy and a note —
  never a broken build. The libraries committed in core ship minified
  already and are copied as they are.

  It returns the facts the browser needs — `window.PHOENIX_KIT_LIBS`, written
  by the `:phoenix_kit_js_sources` compiler next to the module bundles — so
  `phoenix_kit.js` names no CDN, no tag and no version of its own. A CDN is
  used only when the host opts in (`config :phoenix_kit,
  library_cdn_fallback: true`), as a fallback after a failed local load,
  with a URL built from that same consumer version.
  """

  # The host's esbuild, when it has one: core only lists :esbuild for dev.
  @compile {:no_warn_undefined, Esbuild}

  @lib_dir "priv/static/assets/vendor/lib"

  # name: the key in window.PHOENIX_KIT_LIBS (and the file-name prefix).
  # source: {app, path under its priv/} — the file is the installed one.
  # version: :app_vsn for a Hex dep (the consumer's loaded version), or a
  #   fixed string for a library committed in core.
  # sha256: the committed file's checksum (core-committed libraries only).
  # cdn: the opt-in fallback URL, built from the same version.
  @libraries [
    %{
      name: "fresco",
      source: {:fresco, "static/fresco.js"},
      version: :app_vsn,
      cdn: "https://cdn.jsdelivr.net/gh/alexdont/fresco@v{vsn}/priv/static/fresco.js"
    },
    %{
      name: "tessera",
      source: {:tessera, "static/tessera.js"},
      version: :app_vsn,
      cdn: "https://cdn.jsdelivr.net/gh/alexdont/tessera@v{vsn}/priv/static/tessera.js"
    },
    %{
      name: "etcher",
      source: {:etcher, "static/etcher.js"},
      version: :app_vsn,
      cdn: "https://cdn.jsdelivr.net/gh/alexdont/etcher@v{vsn}/priv/static/etcher.js"
    },
    %{
      name: "leaf",
      source: {:leaf, "static/assets/leaf.js"},
      version: :app_vsn,
      cdn: "https://cdn.jsdelivr.net/gh/alexdont/leaf@v{vsn}/priv/static/assets/leaf.js"
    },
    %{
      name: "sortable",
      source: {:phoenix_kit, "static/assets/vendor_libs/sortablejs/Sortable.min.js"},
      version: "1.15.0",
      sha256: "8a9889aecc2f011e15031fed87eeb35ac75e62655a7b4889ba247ee8ea872474",
      cdn: "https://cdn.jsdelivr.net/npm/sortablejs@{vsn}/Sortable.min.js"
    },
    %{
      name: "panzoom",
      source: {:phoenix_kit, "static/assets/vendor_libs/panzoom/panzoom.min.js"},
      version: "4.6.0",
      sha256: "7bc8e4ee6bb95a76330b35b392922436cda207acf345e18b4491f62eb0599410",
      cdn: "https://cdn.jsdelivr.net/npm/@panzoom/panzoom@{vsn}/dist/panzoom.min.js"
    },
    # An ES module (loaded with import()); self-contained — no imports, no workers.
    %{
      name: "wavesurfer",
      source: {:phoenix_kit, "static/assets/vendor_libs/wavesurfer/wavesurfer.esm.js"},
      version: "7.12.12",
      sha256: "1bca765cc75bc4af079ecd1b2edd659b155e5d1715e75a29d68272d9f141f951",
      cdn: "https://cdn.jsdelivr.net/npm/wavesurfer.js@{vsn}/dist/wavesurfer.esm.js"
    },
    # An ES module (loaded with import()); self-contained. The calendar popup
    # of `<.date_input>`.
    %{
      name: "cally",
      source: {:phoenix_kit, "static/assets/vendor_libs/cally/cally.js"},
      version: "0.9.2",
      sha256: "4dcba6a3b8ec63b66ff2fbfc6cf47b7dee1eb4896eac89fe7487d82e28e15870",
      cdn: "https://cdn.jsdelivr.net/npm/cally@{vsn}/dist/cally.js"
    }
  ]

  @doc "The manifest: every library this module vendors."
  def libraries, do: @libraries

  @doc "Where the library files land, relative to the host's root."
  def lib_dir, do: @lib_dir

  @doc """
  Copies every library into `root`'s `#{@lib_dir}` and returns the facts
  map (`name => %{file, cdn}`). Raises when a library's source is missing:
  a dependency that is not where it should be is a broken install, and a
  silent skip is exactly what this replaces.
  """
  @spec vendor!(Path.t()) :: %{String.t() => %{file: String.t(), cdn: String.t() | nil}}
  def vendor!(root) do
    dir = Path.join(root, @lib_dir)
    File.mkdir_p!(dir)
    cdn? = Application.get_env(:phoenix_kit, :library_cdn_fallback, false) == true

    minify? = minify?()

    Map.new(@libraries, fn lib ->
      content = read_source!(lib)
      vsn = version!(lib)
      file = vendor_file!(dir, lib, vsn, content, minify? and lib.version == :app_vsn)

      {lib.name, %{file: file, cdn: if(cdn?, do: String.replace(lib.cdn, "{vsn}", vsn))}}
    end)
  end

  # The minified copy when asked for and esbuild can make it; otherwise the
  # source as it is. Either way only written when its name is not there yet.
  defp vendor_file!(dir, lib, vsn, content, true) do
    file = min_file_name(lib.name, vsn, content)
    dest = Path.join(dir, file)

    # A minified copy is written whole through a rename, so an existing,
    # non-empty file under its name is the finished one.
    if File.exists?(dest) and File.stat!(dest).size > 0 do
      file
    else
      case minify(content) do
        {:ok, small} ->
          write!(dest, small)
          Mix.shell().info("[PhoenixKit] Vendored #{@lib_dir}/#{file} (minified)")
          file

        {:error, reason} ->
          Mix.shell().info(
            "[PhoenixKit] Could not minify #{lib.name} (#{reason}); serving it unminified."
          )

          vendor_file!(dir, lib, vsn, content, false)
      end
    end
  end

  defp vendor_file!(dir, lib, vsn, content, false) do
    file = file_name(lib.name, vsn, content)
    dest = Path.join(dir, file)

    # The name carries the content hash, so a file of the wrong size is a
    # write that was cut short: write it again rather than trust it.
    unless File.exists?(dest) and File.stat!(dest).size == byte_size(content) do
      write!(dest, content)
      Mix.shell().info("[PhoenixKit] Vendored #{@lib_dir}/#{file}")
    end

    file
  end

  # The rename keeps a half-written file from ever sitting under the final name.
  defp write!(dest, content) do
    tmp = dest <> ".tmp"
    File.write!(tmp, content)
    File.rename!(tmp, dest)
  end

  @doc false
  # Production minifies; `config :phoenix_kit, minify_libraries: true/false`
  # says otherwise either way.
  def minify? do
    case Application.get_env(:phoenix_kit, :minify_libraries) do
      flag when is_boolean(flag) -> flag
      _ -> Mix.env() == :prod
    end
  end

  @doc false
  # The host's esbuild — the binary its own asset build installs — as a plain
  # transform: no bundling, so a script stays the script it was.
  @spec minify(binary()) :: {:ok, binary()} | {:error, String.t()}
  def minify(content) do
    with {:ok, bin} <- esbuild_bin() do
      stamp = System.unique_integer([:positive])
      input = Path.join(System.tmp_dir!(), "pk_minify_#{stamp}.js")
      output = Path.join(System.tmp_dir!(), "pk_minify_#{stamp}.min.js")

      try do
        File.write!(input, content)

        case System.cmd(bin, [input, "--minify", "--log-level=error", "--outfile=" <> output],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            case File.read(output) do
              {:ok, small} when byte_size(small) > 0 -> {:ok, small}
              _ -> {:error, "esbuild wrote nothing"}
            end

          {out, code} ->
            {:error, "esbuild exited #{code}: #{String.slice(out, 0, 200)}"}
        end
      after
        File.rm(input)
        File.rm(output)
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp esbuild_bin do
    if Code.ensure_loaded?(Esbuild) do
      bin = Esbuild.bin_path()
      if File.exists?(bin), do: {:ok, bin}, else: {:error, "esbuild is not installed"}
    else
      {:error, "the host has no :esbuild dependency"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "The JavaScript statement carrying the facts, for the install-facts preamble."
  @spec facts_js(map()) :: String.t()
  def facts_js(facts) do
    json =
      facts
      |> Enum.sort()
      |> Enum.map_join(",", fn {name, %{file: file, cdn: cdn}} ->
        "#{Jason.encode!(name)}:{\"file\":#{Jason.encode!(file)},\"cdn\":#{Jason.encode!(cdn)}}"
      end)

    "window.PHOENIX_KIT_LIBS={#{json}};"
  end

  @doc false
  def file_name(name, vsn, content), do: "#{name}-#{vsn}-#{hash8(content)}.js"

  @doc false
  # The source's hash, not the minified bytes': an unchanged library keeps its
  # name, so nothing is minified twice.
  def min_file_name(name, vsn, content), do: "#{name}-#{vsn}-#{hash8(content)}.min.js"

  defp hash8(content),
    do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> binary_part(0, 8)

  defp read_source!(%{name: name, source: {app, path}} = lib) do
    source =
      case :code.priv_dir(app) do
        {:error, :bad_name} ->
          Mix.raise("""
          Could not resolve the #{inspect(app)} application's priv/ directory while
          vendoring the #{name} library. Is #{inspect(app)} a dependency of this app?
          Try `mix deps.get`.
          """)

        dir ->
          Path.join(to_string(dir), path)
      end

    content =
      case File.read(source) do
        {:ok, content} ->
          content

        {:error, reason} ->
          Mix.raise("""
          Could not read the #{name} library at #{source} (#{inspect(reason)}) — the
          #{inspect(app)} dependency looks corrupted or incompletely fetched. Try
          `mix deps.get`.
          """)
      end

    verify_checksum!(lib, content, source)
    content
  end

  defp verify_checksum!(%{sha256: expected, name: name}, content, source) do
    actual = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    unless actual == expected do
      Mix.raise("""
      The vendored #{name} library at #{source} does not match its recorded
      checksum (expected #{expected}, got #{actual}). It must be the exact
      upstream file named in its README.
      """)
    end
  end

  defp verify_checksum!(_lib, _content, _source), do: :ok

  defp version!(%{version: :app_vsn, source: {app, _}, name: name}) do
    Application.load(app)

    case Application.spec(app, :vsn) do
      nil -> Mix.raise("Could not read the loaded version of #{inspect(app)} (#{name}).")
      vsn -> to_string(vsn)
    end
  end

  defp version!(%{version: vsn}) when is_binary(vsn), do: vsn
end
