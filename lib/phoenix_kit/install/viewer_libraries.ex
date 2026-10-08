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
    * SortableJS, Panzoom and wavesurfer (npm-only) ship inside core, each
      at an exact version with its checksum, licence and provenance README
      (`priv/static/assets/vendor_libs/`).
    * The content hash is in the name because a path dependency can change
      its bytes without changing its version; with it, each name is
      cacheable for good.
    * Files are written only when absent and never deleted, so a rolling
      deploy or an open tab can still fetch the previous build's names —
      as far as the deployment itself keeps them (a clean release image does
      not; that retention is the deployment's, not the compiler's).

  It returns the facts the browser needs — `window.PHOENIX_KIT_LIBS`, written
  by the `:phoenix_kit_js_sources` compiler next to the module bundles — so
  `phoenix_kit.js` names no CDN, no tag and no version of its own. A CDN is
  used only when the host opts in (`config :phoenix_kit,
  library_cdn_fallback: true`), as a fallback after a failed local load,
  with a URL built from that same consumer version.
  """

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

    Map.new(@libraries, fn lib ->
      content = read_source!(lib)
      vsn = version!(lib)
      file = file_name(lib.name, vsn, content)
      dest = Path.join(dir, file)

      # The name carries the content hash, so a file of the wrong size is a
      # write that was cut short: write it again rather than trust it. The
      # rename keeps a half-written file from ever sitting under the final name.
      unless File.exists?(dest) and File.stat!(dest).size == byte_size(content) do
        tmp = dest <> ".tmp"
        File.write!(tmp, content)
        File.rename!(tmp, dest)
        Mix.shell().info("[PhoenixKit] Vendored #{@lib_dir}/#{file}")
      end

      {lib.name, %{file: file, cdn: if(cdn?, do: String.replace(lib.cdn, "{vsn}", vsn))}}
    end)
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
  def file_name(name, vsn, content) do
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    "#{name}-#{vsn}-#{hash}.js"
  end

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
