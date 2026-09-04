defmodule PhoenixKit.Modules.Sitemap.Generator do
  @moduledoc """
  Main sitemap generator for PhoenixKit.

  Generates a `<sitemapindex>` at `/sitemap.xml` referencing per-module
  sitemap files at `/sitemaps/sitemap-{source}.xml`.

  ## Architecture

  - `/sitemap.xml` - Always a `<sitemapindex>` referencing per-module files
  - `/sitemaps/sitemap-static.xml` - Static pages
  - `/sitemaps/sitemap-routes.xml` - Router discovery
  - `/sitemaps/sitemap-publishing.xml` - Publishing posts (or per-blog files)
  - `/sitemaps/sitemap-shop.xml` - Shop products (auto-split at 50k)
  - `/sitemaps/sitemap-entities.xml` - Entities (or per-type files)

  HTML sitemaps are rendered by `PhoenixKit.Modules.Sitemap.HtmlGenerator`.

  ## Usage

      # Generate all sitemaps (index + per-module files)
      {:ok, result} = Generator.generate_all(base_url: "https://example.com")

      # Generate HTML sitemap (collects from all sources)
      {:ok, html} = Generator.generate_html(base_url: "https://example.com")

      # Backward compatible: generate_xml returns the sitemapindex
      {:ok, xml} = Generator.generate_xml(base_url: "https://example.com")
  """

  require Logger

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKit.Modules.Sitemap.Cache
  alias PhoenixKit.Modules.Sitemap.DomainMode
  alias PhoenixKit.Modules.Sitemap.FileStorage
  alias PhoenixKit.Modules.Sitemap.HtmlGenerator
  alias PhoenixKit.Modules.Sitemap.SchedulerWorker
  alias PhoenixKit.Modules.Sitemap.SitemapFile
  alias PhoenixKit.Modules.Sitemap.Sources.Source
  alias PhoenixKit.Modules.Sitemap.UrlEntry
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @max_urls_per_file 50_000
  @xml_declaration ~s(<?xml version="1.0" encoding="UTF-8"?>)
  @urlset_open ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">)
  @urlset_close "</urlset>"
  @sitemapindex_open ~s(<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">)
  @sitemapindex_close "</sitemapindex>"

  @valid_xsl_styles ["table", "minimal"]

  # ── Main entry point ───────────────────────────────────────────────

  @doc """
  Generates all sitemaps: per-module files and the sitemapindex.

  ## Options

  - `:base_url` - Base URL for building full URLs (required)
  - `:xsl_style` - XSL stylesheet style: "table" or "minimal" (default: "table")
  - `:xsl_enabled` - Enable XSL stylesheet reference (default: true)

  ## Returns

      {:ok, %{
        index_xml: "<?xml ...sitemapindex...",
        modules: [
          %{filename: "sitemap-static", url_count: 3, lastmod: ~U[...]}
        ],
        total_urls: 150
      }}
  """
  @spec generate_all(keyword()) :: {:ok, map()} | {:error, any()}
  def generate_all(opts \\ []) do
    base_url = Keyword.get(opts, :base_url)

    if is_nil(base_url) do
      {:error, :base_url_required}
    else
      do_generate_all(base_url, opts)
    end
  end

  defp do_generate_all(base_url, opts) do
    xsl_style = Keyword.get(opts, :xsl_style, "table")
    xsl_enabled = Keyword.get(opts, :xsl_enabled, true)

    cond do
      crawlers_no_index?() and not sitemap_exempt_from_no_index?() ->
        do_generate_no_index(xsl_style, xsl_enabled)

      Sitemap.flat_mode?() ->
        do_generate_flat(base_url, opts, get_sources(), xsl_style, xsl_enabled)

      true ->
        do_generate_index(base_url, opts, get_sources(), xsl_style, xsl_enabled)
    end
  end

  # When the Crawlers module's global `noindex` directive is active the site is
  # asking search engines not to index it, so we publish an empty (but valid)
  # `<urlset>` rather than advertising crawlable URLs, for both flat and index
  # modes. Note this makes `/sitemap.xml` serve a `<urlset>` (not a
  # `<sitemapindex>`) while noindex is on — an empty urlset is schema-valid and
  # harmless. Any leftover per-module files are removed.
  #
  # Keyed on `no_index_enabled?/0` alone (not `module_enabled?/0`) to stay in
  # lockstep with the `<meta name="robots" content="noindex">` directive host
  # layouts emit for the same setting — an empty sitemap always pairs with a
  # noindex meta, UNLESS the operator has explicitly opted the sitemap out via
  # `Crawlers.sitemap_exempt_from_no_index?/0` (see the caller in
  # `do_generate_all/2`). That second flag only ever narrows this branch —
  # it cannot fire on its own, and the meta directive itself is untouched by
  # it — so the lockstep still holds for every install that hasn't set it.
  defp do_generate_no_index(xsl_style, xsl_enabled) do
    Logger.debug("Sitemap: crawlers_no_index active — publishing empty sitemap")

    xml = build_urlset_xml([], xsl_style, xsl_enabled)
    FileStorage.save_index(xml)
    FileStorage.delete_all_modules()

    # Domain mode inherits noindex: an empty urlset per mapped host, so
    # previously-generated real-URL files stop being served the moment
    # noindex flips on (mirrors delete_all_modules for the legacy set).
    for %{host: host} <- DomainMode.domains() do
      FileStorage.write_domain_sitemap(host, "sitemap", xml)
    end

    cleanup_stale_domain_dirs()

    {:ok, %{index_xml: xml, modules: [], total_urls: 0}}
  end

  # Defensive: never let a Crawlers lookup error break sitemap generation.
  defp crawlers_no_index? do
    Crawlers.no_index_enabled?()
  rescue
    _ -> false
  catch
    # An unreachable database RAISES on an unowned checkout but EXITS on a
    # dead pool; rescue alone leaves the exit path unguarded.
    :exit, _ -> false
  end

  # Defensive, same as crawlers_no_index?/0 above. Errs toward `false` (not
  # exempt) on lookup failure, i.e. toward the pre-existing blank-on-noindex
  # behavior rather than toward silently publishing a full sitemap.
  defp sitemap_exempt_from_no_index? do
    Crawlers.sitemap_exempt_from_no_index?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Static pages (home page, and whatever else a host lists in
  # `sitemap_static_routes` / `sitemap_custom_urls`) are collected for the site
  # default language only: in a prefix install a "/fr/..." static page has no
  # localized route. A language with a domain of its own does serve them — from
  # its own host, prefix-free — so its copies are collected HERE, for the domain
  # files alone.
  #
  # Deliberately not folded into the shared collection: these entries carry a
  # locale prefix that only means something to `DomainMode.rebuild_for_domains/2`,
  # which strips it while re-hosting. In the legacy set (served verbatim to
  # unmapped hosts) nothing would rewrite them, and `https://<primary>/fr/` is
  # usually not a page at all.
  defp domain_static_entries(opts, base_url) do
    static = PhoenixKit.Modules.Sitemap.Sources.Static

    if static in get_sources() do
      mapped = MapSet.new(DomainMode.domains(), & &1.language)

      get_languages()
      |> Enum.reject(& &1.is_default)
      |> Enum.filter(&MapSet.member?(mapped, &1.code))
      |> Enum.flat_map(fn %{code: code} ->
        static.collect(
          Keyword.merge(opts,
            base_url: base_url,
            language: code,
            is_default_language: false,
            domain_pass: true
          )
        )
      end)
    else
      []
    end
  end

  # Multi-domain post-processing (DomainMode): one flat urlset per mapped
  # host (its language's entries, re-hosted prefix-free, cross-domain
  # alternates), with the 50k splitter per host. `entries` may be passed in
  # (flat mode reuses its collection) or nil (index mode — collected here).
  # Inactive provider ⇒ no-op; stale host dirs are always cleaned up.
  defp generate_domain_sitemaps(entries, base_url, opts, xsl_style, xsl_enabled) do
    if DomainMode.active?() do
      # Index mode re-collects here (flat mode passes its entries through).
      # Accepted trade-off: one extra collection pass per scheduled/on-demand
      # generation, in exchange for zero restructuring of the per-module
      # legacy path. Content changing between the two passes within one run
      # can skew module stats vs domain files until the next generation.
      #
      # Deliberately NOT `force: true` here: index mode's own per-module
      # files honor each source's `enabled?/0` (see `generate_module/2`),
      # and domain files must match that guarantee. Flat mode's pre-existing
      # force-collect (a documented, separate trade-off) only reaches this
      # function via the already-collected `entries` argument, so it is
      # untouched by this line — forcing it here would additionally leak
      # disabled-module URLs into index mode, which never leaked before.
      entries = entries || collect_all_entries(opts, get_sources())

      per_host =
        DomainMode.rebuild_for_domains(entries ++ domain_static_entries(opts, base_url), base_url)

      for {host, host_entries} <- per_host do
        write_domain_files(host, host_entries, xsl_style, xsl_enabled)
      end

      Logger.info("Sitemap: Generated domain sitemaps for #{map_size(per_host)} hosts")
    end

    cleanup_stale_domain_dirs()
    :ok
  end

  defp write_domain_files(host, entries, xsl_style, xsl_enabled) do
    if length(entries) > @max_urls_per_file do
      chunks = Enum.chunk_every(entries, @max_urls_per_file)

      filenames =
        chunks
        |> Enum.with_index(1)
        |> Enum.map(fn {chunk, i} ->
          filename = "sitemap-#{i}"
          xml = build_urlset_xml(chunk, xsl_style, xsl_enabled)
          FileStorage.write_domain_sitemap(host, filename, xml)
          Cache.put({:domain_xml, host, filename}, xml)
          filename
        end)

      index_xml = build_domain_index_xml(host, filenames, xsl_style, xsl_enabled)
      FileStorage.write_domain_sitemap(host, "sitemap", index_xml)
      Cache.put({:domain_xml, host, "sitemap"}, index_xml)
    else
      xml = build_urlset_xml(entries, xsl_style, xsl_enabled)
      FileStorage.write_domain_sitemap(host, "sitemap", xml)
      Cache.put({:domain_xml, host, "sitemap"}, xml)
    end
  end

  defp build_domain_index_xml(host, filenames, xsl_style, xsl_enabled) do
    lastmod = DateTime.utc_now() |> DateTime.to_iso8601()

    # Same prefix handling as the legacy generate_index/4 — hosts served
    # under a non-root url_prefix must reference their chunks there too.
    prefix =
      case PhoenixKit.Config.get_url_prefix() do
        "/" -> ""
        p -> String.trim_trailing(p, "/")
      end

    entries_xml =
      Enum.map_join(filenames, "\n", fn filename ->
        "  <sitemap>\n    <loc>https://#{host}#{prefix}/sitemaps/#{filename}.xml</loc>\n    <lastmod>#{lastmod}</lastmod>\n  </sitemap>"
      end)

    [
      @xml_declaration,
      build_index_xsl_line(xsl_style, xsl_enabled),
      @sitemapindex_open,
      entries_xml,
      @sitemapindex_close
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # Hosts with generated dirs that are no longer in the provider list.
  defp cleanup_stale_domain_dirs do
    active_hosts = MapSet.new(DomainMode.domains(), & &1.host)

    for host <- FileStorage.list_domain_hosts(),
        host not in active_hosts do
      FileStorage.delete_domain_files(host)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp do_generate_index(base_url, opts, sources, xsl_style, xsl_enabled) do
    Logger.info("Sitemap: Generating sitemapindex from #{length(sources)} sources")

    # Generate per-module files
    module_infos =
      sources
      |> Enum.flat_map(fn source_module ->
        generate_module(source_module, opts)
      end)

    # Build and save sitemapindex
    index_xml = generate_index(module_infos, base_url, xsl_style, xsl_enabled)
    FileStorage.save_index(index_xml)

    # Clean up stale module files from disabled sources
    cleanup_stale_modules(module_infos)

    generate_domain_sitemaps(nil, base_url, opts, xsl_style, xsl_enabled)

    total_urls = Enum.reduce(module_infos, 0, fn info, acc -> acc + info.url_count end)

    Logger.info(
      "Sitemap: Generated #{length(module_infos)} module files, #{total_urls} total URLs"
    )

    {:ok,
     %{
       index_xml: index_xml,
       modules: module_infos,
       total_urls: total_urls
     }}
  end

  defp do_generate_flat(base_url, opts, sources, xsl_style, xsl_enabled) do
    Logger.info("Sitemap: Generating flat sitemap from #{length(sources)} sources")

    flat_opts = Keyword.put(opts, :force, true)
    entries = collect_all_entries(flat_opts, sources)
    xml = build_urlset_xml(entries, xsl_style, xsl_enabled)
    FileStorage.save_index(xml)

    # Clean up any leftover per-module files
    FileStorage.delete_all_modules()

    generate_domain_sitemaps(entries, base_url, opts, xsl_style, xsl_enabled)

    total_urls = length(entries)

    Logger.info("Sitemap: Generated flat sitemap with #{total_urls} URLs")

    {:ok,
     %{
       index_xml: xml,
       modules: [
         %SitemapFile{filename: "flat", url_count: total_urls, lastmod: UtilsDate.utc_now()}
       ],
       total_urls: total_urls
     }}
  end

  # ── Per-module generation ──────────────────────────────────────────

  @doc """
  Generates sitemap file(s) for a single source module.

  Returns a list of `%SitemapFile{}` structs (one per file generated).
  Empty sources produce no files and return [].
  """
  @spec generate_module(module(), keyword()) :: [SitemapFile.t()]
  def generate_module(source_module, opts \\ []) do
    if Source.valid_source?(source_module) and source_module.enabled?() do
      do_generate_module(source_module, opts)
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "Sitemap: Failed to generate module #{inspect(source_module)}: #{inspect(error)}"
      )

      []
  end

  defp do_generate_module(source_module, opts) do
    xsl_style = Keyword.get(opts, :xsl_style, "table")
    xsl_enabled = Keyword.get(opts, :xsl_enabled, true)
    base_filename = Source.get_sitemap_filename(source_module)

    # Check for sub-sitemaps (per-group splitting)
    case Source.get_sub_sitemaps(source_module, opts) do
      nil ->
        # Single file: collect all entries for this source
        entries = collect_source_entries(source_module, opts)
        build_and_save_module_files(entries, base_filename, xsl_style, xsl_enabled)

      sub_maps when is_list(sub_maps) ->
        # Per-group files
        sub_maps
        |> Enum.flat_map(fn {group_name, entries} ->
          filename = "#{base_filename}-#{group_name}"
          build_and_save_module_files(entries, filename, xsl_style, xsl_enabled)
        end)
    end
  end

  # Collect entries for a single source using multilingual collection
  defp collect_source_entries(source_module, opts) do
    languages = get_languages()
    multilingual_enabled = length(languages) > 1

    if multilingual_enabled do
      collect_multilingual_entries(opts, [source_module], languages)
    else
      collect_single_language_entries(opts, [source_module])
    end
  end

  # Build urlset XML, auto-split at 50k, save files, return module_info list
  defp build_and_save_module_files(entries, filename, xsl_style, xsl_enabled) do
    if entries == [] do
      # Clean up any existing file for empty source
      FileStorage.delete_module(filename)
      []
    else
      if length(entries) > @max_urls_per_file do
        # Auto-split into numbered files
        entries
        |> Enum.chunk_every(@max_urls_per_file)
        |> Enum.with_index(1)
        |> Enum.map(fn {chunk, index} ->
          numbered_filename = "#{filename}-#{index}"
          xml = build_urlset_xml(chunk, xsl_style, xsl_enabled)
          FileStorage.save_module(numbered_filename, xml)
          Cache.put_module(numbered_filename, xml)

          %SitemapFile{
            filename: numbered_filename,
            url_count: length(chunk),
            lastmod: latest_lastmod(chunk)
          }
        end)
      else
        xml = build_urlset_xml(entries, xsl_style, xsl_enabled)
        FileStorage.save_module(filename, xml)
        Cache.put_module(filename, xml)

        [
          %SitemapFile{
            filename: filename,
            url_count: length(entries),
            lastmod: latest_lastmod(entries)
          }
        ]
      end
    end
  end

  # ── Sitemapindex generation ────────────────────────────────────────

  @doc """
  Builds `<sitemapindex>` XML from a list of `%SitemapFile{}` structs.
  """
  @spec generate_index([SitemapFile.t()], String.t(), String.t(), boolean()) :: String.t()
  def generate_index(module_infos, base_url, xsl_style \\ "table", xsl_enabled \\ true) do
    xsl_line = build_index_xsl_line(xsl_style, xsl_enabled)
    normalized_base = String.trim_trailing(base_url, "/")
    prefix = PhoenixKit.Config.get_url_prefix()
    normalized_prefix = if prefix == "/", do: "", else: prefix

    sitemap_entries =
      module_infos
      |> Enum.map(fn info ->
        loc = "#{normalized_base}#{normalized_prefix}/sitemaps/#{info.filename}.xml"
        lastmod_str = format_lastmod(info.lastmod)

        """
          <sitemap>
            <loc>#{UrlEntry.escape_xml(loc)}</loc>
            <lastmod>#{lastmod_str}</lastmod>
          </sitemap>
        """
      end)

    [
      @xml_declaration,
      xsl_line,
      @sitemapindex_open,
      Enum.join(sitemap_entries, "\n"),
      @sitemapindex_close
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # ── Backward-compatible public API ─────────────────────────────────

  @doc """
  Generates XML sitemap. Returns the sitemapindex XML.

  Delegates to `generate_all/1` and returns the index XML for backward compatibility.
  """
  @spec generate_xml(keyword()) ::
          {:ok, String.t()} | {:ok, String.t(), [map()]} | {:error, any()}
  def generate_xml(opts \\ []) do
    base_url = Keyword.get(opts, :base_url)

    if is_nil(base_url) do
      {:error, :base_url_required}
    else
      case generate_all(opts) do
        {:ok, %{index_xml: xml, modules: modules}} ->
          {:ok, xml, modules}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Generates HTML sitemap from all enabled sources.

  Delegates to `PhoenixKit.Modules.Sitemap.HtmlGenerator`.

  ## Options

  - `:base_url` - Base URL for building full URLs (required)
  - `:style` - Display style: "hierarchical", "grouped", or "flat" (default: "hierarchical")
  - `:cache` - Enable/disable caching (default: true)
  - `:title` - Page title (default: "Sitemap")
  """
  @spec generate_html(keyword()) :: {:ok, String.t()} | {:error, any()}
  def generate_html(opts \\ []) do
    base_url = Keyword.get(opts, :base_url)
    style = Keyword.get(opts, :style, "hierarchical")
    cache_enabled = Keyword.get(opts, :cache, true)

    cond do
      !base_url ->
        {:error, :base_url_required}

      style not in ["hierarchical", "grouped", "flat"] ->
        {:error, :invalid_style}

      crawlers_no_index?() ->
        # noindex active: never advertise URLs and never serve a stale cached
        # HTML sitemap — render an empty one, bypassing the cache.
        HtmlGenerator.generate(opts, [], :"html_#{style}", cache: false)

      true ->
        cache_key = :"html_#{style}"

        if cache_enabled do
          case Cache.get(cache_key) do
            {:ok, cached} ->
              Logger.debug("Sitemap: Using cached HTML sitemap (#{style})")
              {:ok, cached}

            :error ->
              entries = collect_all_entries(opts)
              HtmlGenerator.generate(opts, entries, cache_key)
          end
        else
          entries = collect_all_entries(opts)
          HtmlGenerator.generate(opts, entries, cache_key, cache: false)
        end
    end
  end

  @doc """
  Collects URL entries from all enabled sources.

  When the Languages module is enabled, automatically collects entries for all
  enabled languages and adds hreflang alternate links.
  """
  @spec collect_all_entries(keyword(), [module()]) :: [UrlEntry.t()]
  def collect_all_entries(opts \\ [], sources \\ get_sources()) do
    languages = get_languages()
    multilingual_enabled = length(languages) > 1

    Logger.debug(
      "Sitemap: Collecting entries from #{length(sources)} sources, " <>
        "languages: #{inspect(Enum.map(languages, & &1.code))}, multilingual: #{multilingual_enabled}"
    )

    if multilingual_enabled do
      collect_multilingual_entries(opts, sources, languages)
    else
      collect_single_language_entries(opts, sources)
    end
  end

  @doc """
  Invalidates all cached sitemaps.
  """
  @spec invalidate_cache() :: :ok
  def invalidate_cache do
    Logger.debug("Sitemap: Invalidating cache")
    Cache.invalidate()
  end

  @doc """
  Invalidates cache AND triggers async regeneration.
  """
  @spec invalidate_and_regenerate() :: {:ok, Oban.Job.t()} | {:error, term()}
  def invalidate_and_regenerate do
    Logger.info("Sitemap: Invalidating cache and triggering regeneration")
    Cache.invalidate()
    SchedulerWorker.regenerate_now()
  end

  @doc """
  Gets a specific sitemap part by index (1-based).

  Legacy function for backward compatibility with old numbered sitemap parts.
  """
  @spec get_sitemap_part(integer()) :: {:ok, String.t()} | {:error, :not_found}
  def get_sitemap_part(index) when is_integer(index) and index > 0 do
    case Cache.get(:parts) do
      {:ok, parts} when is_list(parts) ->
        case Enum.find(parts, fn part -> part.index == index end) do
          nil -> {:error, :not_found}
          %{xml: xml} -> {:ok, xml}
        end

      _ ->
        {:error, :not_found}
    end
  end

  def get_sitemap_part(_), do: {:error, :not_found}

  # ── Internal: source list ──────────────────────────────────────────

  @doc false
  def get_sources do
    base_sources =
      Application.get_env(:phoenix_kit, :sitemap, [])
      |> Keyword.get(:sources, default_sources())

    # Append sitemap sources contributed by external modules (e.g. Entities)
    # via the PhoenixKit.Module `sitemap_sources/0` callback. Deduplicated so
    # a module already listed in host config / defaults isn't run twice.
    #
    # Semantics note: a host `config :phoenix_kit, sitemap: [sources: [...]]`
    # is now a BASE list that module-contributed sources EXTEND — it no longer
    # fully replaces them. A host that intentionally pruned `:sources` will
    # still get an opted-in module's source appended. Only sources from
    # *enabled* modules are appended (see `all_sitemap_sources/0`), so a disabled
    # module emits nothing even in flat mode (where collection is forced and the
    # per-source `enabled?/0` is bypassed). In index mode the source's own
    # `enabled?/0` is still honored as a secondary gate (see `generate_module/2`).
    (base_sources ++ module_sitemap_sources())
    |> Enum.uniq()
  end

  defp module_sitemap_sources do
    PhoenixKit.ModuleRegistry.all_sitemap_sources()
  rescue
    _ -> []
  end

  defp default_sources do
    [
      PhoenixKit.Modules.Sitemap.Sources.RouterDiscovery,
      PhoenixKit.Modules.Sitemap.Sources.Static,
      PhoenixKit.Modules.Sitemap.Sources.Publishing,
      PhoenixKit.Modules.Sitemap.Sources.Posts,
      PhoenixKit.Modules.Sitemap.Sources.Shop
    ]
  end

  # ── Internal: entry collection ─────────────────────────────────────

  defp collect_single_language_entries(opts, sources) do
    sources
    |> Enum.flat_map(fn source_module ->
      entries = Source.safe_collect(source_module, opts)
      Logger.debug("Sitemap: Collected #{length(entries)} entries from #{inspect(source_module)}")
      entries
    end)
    |> UrlEntry.dedupe_by_loc()
    |> Enum.sort_by(& &1.loc)
  end

  defp collect_multilingual_entries(opts, sources, languages) do
    base_url = Keyword.get(opts, :base_url)
    all_language_codes = Enum.map(languages, & &1.code)

    entries_by_language =
      languages
      |> Task.async_stream(
        fn lang ->
          language_opts =
            opts ++
              [
                language: lang.code,
                is_default_language: lang.is_default,
                all_languages: all_language_codes
              ]

          entries =
            sources
            |> Enum.flat_map(fn source_module ->
              Source.safe_collect(source_module, language_opts)
            end)

          {lang.code, entries}
        end,
        ordered: false,
        max_concurrency: System.schedulers_online() * 2,
        timeout: 60_000
      )
      |> Enum.reduce(%{}, fn
        {:ok, {lang_code, entries}}, acc ->
          Map.put(acc, lang_code, entries)

        {:exit, reason}, acc ->
          Logger.warning("Sitemap: Language collection failed: #{inspect(reason)}")
          acc
      end)

    all_entries =
      entries_by_language
      |> Enum.flat_map(fn {_lang, entries} -> entries end)

    non_default_codes =
      languages
      |> Enum.reject(& &1.is_default)
      |> Enum.map(& &1.code)

    alternates_by_canonical =
      all_entries
      |> Enum.filter(& &1.canonical_path)
      |> Enum.group_by(& &1.canonical_path)
      |> Enum.map(fn {canonical_path, entries} ->
        default_entry =
          Enum.find(entries, fn e ->
            # Case-insensitive: enabled codes are stored BCP-47 ("en-GB")
            # while sibling-dialect URLs render lowercase ("/en-gb/…") — a
            # case-sensitive contains? let a sibling entry pass as the
            # default and claim x-default.
            loc_down = String.downcase(e.loc)

            not Enum.any?(non_default_codes, fn code ->
              String.contains?(loc_down, "/#{String.downcase(code)}/")
            end)
          end) || List.first(entries)

        alternates =
          entries
          |> Enum.map(fn entry ->
            lang_code = extract_language_from_entry(entry, base_url)
            %{hreflang: lang_code, href: entry.loc}
          end)

        alternates =
          if default_entry do
            alternates ++ [%{hreflang: "x-default", href: default_entry.loc}]
          else
            alternates
          end

        {canonical_path, alternates}
      end)
      |> Map.new()

    all_entries
    |> Enum.map(fn entry ->
      if entry.canonical_path do
        alternates = Map.get(alternates_by_canonical, entry.canonical_path, [])
        %{entry | alternates: alternates}
      else
        entry
      end
    end)
    |> UrlEntry.dedupe_by_loc()
    |> Enum.sort_by(& &1.loc)
  end

  defp extract_language_from_entry(entry, base_url) do
    path =
      if base_url do
        String.replace(entry.loc, base_url, "")
      else
        entry.loc
      end

    case Regex.run(~r/^\/([a-z]{2,3}(?:-[A-Za-z]{2,4})?)(?:\/|$)/, path) do
      [_, lang] -> lang
      _ -> Routes.get_default_admin_locale()
    end
  end

  # ── Internal: XML building ─────────────────────────────────────────

  defp build_urlset_xml(entries, xsl_style, xsl_enabled) do
    xml_urls = Enum.map(entries, &UrlEntry.to_xml/1)
    xsl_line = build_xsl_line(xsl_style, xsl_enabled)

    [@xml_declaration, xsl_line, @urlset_open, Enum.join(xml_urls, "\n"), @urlset_close]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp build_xsl_line(xsl_style, true) when xsl_style in @valid_xsl_styles do
    prefix = PhoenixKit.Config.get_url_prefix()
    normalized_prefix = if prefix == "/", do: "", else: prefix
    version = UtilsDate.utc_now() |> DateTime.to_unix()

    ~s(<?xml-stylesheet type="text/xsl" href="#{normalized_prefix}/assets/sitemap/#{xsl_style}?v=#{version}"?>)
  end

  defp build_xsl_line(_, _), do: ""

  defp build_index_xsl_line(xsl_style, true) when xsl_style in @valid_xsl_styles do
    prefix = PhoenixKit.Config.get_url_prefix()
    normalized_prefix = if prefix == "/", do: "", else: prefix
    version = UtilsDate.utc_now() |> DateTime.to_unix()

    ~s(<?xml-stylesheet type="text/xsl" href="#{normalized_prefix}/assets/sitemap-index/#{xsl_style}?v=#{version}"?>)
  end

  defp build_index_xsl_line(_, _), do: ""

  # ── Internal: helpers ──────────────────────────────────────────────

  defp get_languages do
    if Languages.enabled?() do
      case Languages.get_enabled_languages() do
        languages when is_list(languages) and languages != [] ->
          languages
          |> Enum.map(fn lang ->
            %{
              code: Languages.DialectMapper.extract_base(lang.code || "en"),
              is_default: lang.is_default
            }
          end)

        _ ->
          [%{code: "en", is_default: true}]
      end
    else
      [%{code: "en", is_default: true}]
    end
  rescue
    _ -> [%{code: "en", is_default: true}]
  end

  defp latest_lastmod(entries) do
    entries
    |> Enum.map(& &1.lastmod)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> UtilsDate.utc_now()
      dates -> dates |> Enum.map(&normalize_to_datetime/1) |> Enum.max(DateTime)
    end
  end

  defp format_lastmod(nil), do: UtilsDate.utc_now() |> DateTime.to_iso8601()
  defp format_lastmod(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_lastmod(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp format_lastmod(%Date{} = d), do: Date.to_iso8601(d)
  defp format_lastmod(_), do: UtilsDate.utc_now() |> DateTime.to_iso8601()

  defp normalize_to_datetime(%DateTime{} = dt), do: dt

  defp normalize_to_datetime(%NaiveDateTime{} = ndt) do
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  defp normalize_to_datetime(%Date{} = d) do
    DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
  end

  defp normalize_to_datetime(_), do: UtilsDate.utc_now()

  # Remove module files that are no longer generated by any enabled source
  defp cleanup_stale_modules(current_module_infos) do
    current_filenames = MapSet.new(Enum.map(current_module_infos, & &1.filename))
    existing_files = FileStorage.list_module_files()

    Enum.each(existing_files, fn file ->
      unless MapSet.member?(current_filenames, file) do
        Logger.debug("Sitemap: Cleaning up stale module file: #{file}.xml")
        FileStorage.delete_module(file)
      end
    end)
  end
end
