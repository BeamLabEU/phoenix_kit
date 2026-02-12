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

  ## Usage

      # Generate all sitemaps (index + per-module files)
      {:ok, result} = Generator.generate_all(base_url: "https://example.com")

      # Generate HTML sitemap (collects from all sources)
      {:ok, html} = Generator.generate_html(base_url: "https://example.com")

      # Backward compatible: generate_xml returns the sitemapindex
      {:ok, xml} = Generator.generate_xml(base_url: "https://example.com")
  """

  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKit.Modules.Sitemap.Cache
  alias PhoenixKit.Modules.Sitemap.FileStorage
  alias PhoenixKit.Modules.Sitemap.SchedulerWorker
  alias PhoenixKit.Modules.Sitemap.Sources.Source
  alias PhoenixKit.Modules.Sitemap.UrlEntry
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
    sources = get_sources()

    if Sitemap.flat_mode?() do
      do_generate_flat(base_url, opts, sources, xsl_style, xsl_enabled)
    else
      do_generate_index(base_url, opts, sources, xsl_style, xsl_enabled)
    end
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

  defp do_generate_flat(_base_url, opts, sources, xsl_style, xsl_enabled) do
    Logger.info("Sitemap: Generating flat sitemap from #{length(sources)} sources")

    flat_opts = Keyword.put(opts, :force, true)
    entries = collect_all_entries(flat_opts, sources)
    xml = build_urlset_xml(entries, xsl_style, xsl_enabled)
    FileStorage.save_index(xml)

    # Clean up any leftover per-module files
    FileStorage.delete_all_modules()

    total_urls = length(entries)

    Logger.info("Sitemap: Generated flat sitemap with #{total_urls} URLs")

    {:ok,
     %{
       index_xml: xml,
       modules: [%{filename: "flat", url_count: total_urls, lastmod: DateTime.utc_now()}],
       total_urls: total_urls
     }}
  end

  # ── Per-module generation ──────────────────────────────────────────

  @doc """
  Generates sitemap file(s) for a single source module.

  Returns a list of module_info maps (one per file generated).
  Empty sources produce no files and return [].
  """
  @spec generate_module(module(), keyword()) :: [map()]
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

          %{
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
          %{
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
  Builds `<sitemapindex>` XML from a list of module_info maps.
  """
  @spec generate_index([map()], String.t(), String.t(), boolean()) :: String.t()
  def generate_index(module_infos, base_url, xsl_style \\ "table", xsl_enabled \\ true) do
    xsl_line = build_index_xsl_line(xsl_style, xsl_enabled)
    normalized_base = String.trim_trailing(base_url, "/")
    prefix = PhoenixKit.Config.get_url_prefix()
    normalized_prefix = if prefix == "/", do: "", else: prefix

    sitemap_entries =
      module_infos
      |> Enum.map(fn info ->
        loc = "#{normalized_base}#{normalized_prefix}/sitemaps/#{info.filename}.xml"
        lastmod_str = format_lastmod(info[:lastmod])

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

      true ->
        cache_key = :"html_#{style}"

        if cache_enabled do
          case Cache.get(cache_key) do
            {:ok, cached} ->
              Logger.debug("Sitemap: Using cached HTML sitemap (#{style})")
              {:ok, cached}

            :error ->
              generate_and_cache_html(opts, cache_key)
          end
        else
          generate_and_cache_html(opts, cache_key, cache: false)
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
    Application.get_env(:phoenix_kit, :sitemap, [])
    |> Keyword.get(:sources, default_sources())
  end

  defp default_sources do
    [
      PhoenixKit.Modules.Sitemap.Sources.RouterDiscovery,
      PhoenixKit.Modules.Sitemap.Sources.Static,
      PhoenixKit.Modules.Sitemap.Sources.Publishing,
      PhoenixKit.Modules.Sitemap.Sources.Entities,
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
    |> Enum.uniq_by(& &1.loc)
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
            not Enum.any?(non_default_codes, fn code ->
              String.contains?(e.loc, "/#{code}/")
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
    |> Enum.uniq_by(& &1.loc)
    |> Enum.sort_by(& &1.loc)
  end

  defp extract_language_from_entry(entry, base_url) do
    path =
      if base_url do
        String.replace(entry.loc, base_url, "")
      else
        entry.loc
      end

    case Regex.run(~r/^\/([a-z]{2})(?:\/|$)/, path) do
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
    version = DateTime.utc_now() |> DateTime.to_unix()

    ~s(<?xml-stylesheet type="text/xsl" href="#{normalized_prefix}/assets/sitemap/#{xsl_style}?v=#{version}"?>)
  end

  defp build_xsl_line(_, _), do: ""

  defp build_index_xsl_line(xsl_style, true) when xsl_style in @valid_xsl_styles do
    prefix = PhoenixKit.Config.get_url_prefix()
    normalized_prefix = if prefix == "/", do: "", else: prefix
    version = DateTime.utc_now() |> DateTime.to_unix()

    ~s(<?xml-stylesheet type="text/xsl" href="#{normalized_prefix}/assets/sitemap-index/#{xsl_style}?v=#{version}"?>)
  end

  defp build_index_xsl_line(_, _), do: ""

  # ── Internal: HTML generation ──────────────────────────────────────

  defp generate_and_cache_html(opts, cache_key, cache_opts \\ []) do
    entries = collect_all_entries(opts)
    style = Keyword.get(opts, :style, "hierarchical")
    title = Keyword.get(opts, :title, "Sitemap")
    cache_enabled = Keyword.get(cache_opts, :cache, true)

    html =
      case style do
        "hierarchical" -> generate_hierarchical_html(entries, title)
        "grouped" -> generate_grouped_html(entries, title)
        "flat" -> generate_flat_html(entries, title)
      end

    result = {:ok, html}

    if cache_enabled do
      Cache.put(cache_key, html)
      FileStorage.save("html_#{style}", html)
    end

    result
  end

  defp html_head(title) do
    """
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>#{UrlEntry.escape_xml(title)}</title>
        <style>
          :root {
            --base-100: #ffffff;
            --base-200: #f3f4f6;
            --base-content: #1f2937;
            --primary: #3b82f6;
            color-scheme: light dark;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --base-100: #1f2937;
              --base-200: #374151;
              --base-content: #f3f4f6;
              --primary: #60a5fa;
            }
          }
          * { box-sizing: border-box; margin: 0; padding: 0; }
          body {
            font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background-color: var(--base-100);
            color: var(--base-content);
            line-height: 1.5;
          }
          .container { width: 100%; max-width: 1280px; margin: 0 auto; }
          .px-4 { padding-left: 1rem; padding-right: 1rem; }
          .py-8 { padding-top: 2rem; padding-bottom: 2rem; }
          .max-w-4xl { max-width: 56rem; }
          .max-w-6xl { max-width: 72rem; }
          .text-4xl { font-size: 2.25rem; font-weight: 700; }
          .text-lg { font-size: 1.125rem; }
          .text-sm { font-size: 0.875rem; }
          .font-bold { font-weight: 700; }
          .font-semibold { font-weight: 600; }
          .text-center { text-align: center; }
          .mb-2 { margin-bottom: 0.5rem; }
          .mb-4 { margin-bottom: 1rem; }
          .mb-6 { margin-bottom: 1.5rem; }
          .mb-8 { margin-bottom: 2rem; }
          .mt-2 { margin-top: 0.5rem; }
          .ml-4 { margin-left: 1rem; }
          .card {
            background-color: var(--base-200);
            border-radius: 0.75rem;
            box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
          }
          .card-body { padding: 1.5rem; }
          .card-title {
            font-size: 1.25rem;
            font-weight: 600;
            margin-bottom: 0.5rem;
          }
          .grid { display: grid; gap: 1rem; }
          .gap-4 { gap: 1rem; }
          @media (min-width: 768px) {
            .md\\:grid-cols-2 { grid-template-columns: repeat(2, 1fr); }
            .md\\:columns-2 { column-count: 2; }
          }
          @media (min-width: 1024px) {
            .lg\\:columns-3 { column-count: 3; }
          }
          ul { list-style: none; }
          .list-disc { list-style-type: disc; }
          .list-inside { list-style-position: inside; }
          .space-y-1 > * + * { margin-top: 0.25rem; }
          .space-y-2 > * + * { margin-top: 0.5rem; }
          a.link {
            color: var(--primary);
            text-decoration: none;
            transition: opacity 0.15s;
          }
          a.link:hover { opacity: 0.8; text-decoration: underline; }
          .text-muted { opacity: 0.7; }
          .columns-1 { column-count: 1; }
        </style>
    """
  end

  defp generate_hierarchical_html(entries, title) do
    grouped =
      entries
      |> Enum.group_by(fn entry -> entry.category || "Other" end)
      |> Enum.sort_by(fn {category, _} -> category end)

    category_sections =
      Enum.map_join(grouped, "\n", fn {category, category_entries} ->
        letter_groups =
          category_entries
          |> Enum.group_by(fn entry ->
            t = entry.title || entry.loc
            String.upcase(String.at(t, 0) || "")
          end)
          |> Enum.sort_by(fn {letter, _} -> letter end)

        letter_sections =
          Enum.map_join(letter_groups, "\n", fn {letter, letter_entries} ->
            links =
              letter_entries
              |> Enum.sort_by(fn entry -> entry.title || entry.loc end)
              |> Enum.map_join("\n          ", fn entry ->
                display_title = entry.title || entry.loc

                ~s(<li><a href="#{UrlEntry.escape_xml(entry.loc)}" class="link">#{UrlEntry.escape_xml(display_title)}</a></li>)
              end)

            """
                  <div class="mb-4">
                    <h4 class="text-sm font-semibold text-muted mb-2">#{letter}</h4>
                    <ul class="ml-4 space-y-1">
                      #{links}
                    </ul>
                  </div>
            """
          end)

        """
              <div class="card mb-4">
                <div class="card-body">
                  <h3 class="card-title text-lg">#{UrlEntry.escape_xml(category)}</h3>
                  <div class="mt-2">
        #{letter_sections}
                  </div>
                </div>
              </div>
        """
      end)

    """
    <!DOCTYPE html>
    <html>
      <head>
    #{html_head(title)}</head>
      <body>
        <div class="container px-4 py-8 max-w-6xl">
          <h1 class="text-4xl font-bold mb-8 text-center">#{UrlEntry.escape_xml(title)}</h1>
          <div class="grid md:grid-cols-2 gap-4">
    #{category_sections}
          </div>
        </div>
      </body>
    </html>
    """
  end

  defp generate_grouped_html(entries, title) do
    grouped =
      entries
      |> Enum.group_by(fn entry ->
        entry.category || (entry.source && to_string(entry.source)) || "Other"
      end)
      |> Enum.sort_by(fn {group, _} -> group end)

    sections =
      Enum.map_join(grouped, "\n", fn {group, group_entries} ->
        links =
          group_entries
          |> Enum.sort_by(fn entry -> entry.title || entry.loc end)
          |> Enum.map_join("\n          ", fn entry ->
            display_title = entry.title || entry.loc

            ~s(<li><a href="#{UrlEntry.escape_xml(entry.loc)}" class="link">#{UrlEntry.escape_xml(display_title)}</a></li>)
          end)

        """
              <div class="card mb-6">
                <div class="card-body">
                  <h2 class="card-title">#{UrlEntry.escape_xml(group)}</h2>
                  <ul class="list-disc list-inside space-y-2 mt-2">
        #{links}
                  </ul>
                  <div class="text-sm text-muted mt-2">
                    #{length(group_entries)} page#{if length(group_entries) != 1, do: "s", else: ""}
                  </div>
                </div>
              </div>
        """
      end)

    """
    <!DOCTYPE html>
    <html>
      <head>
    #{html_head(title)}</head>
      <body>
        <div class="container px-4 py-8 max-w-4xl">
          <h1 class="text-4xl font-bold mb-8 text-center">#{UrlEntry.escape_xml(title)}</h1>
    #{sections}
        </div>
      </body>
    </html>
    """
  end

  defp generate_flat_html(entries, title) do
    links =
      entries
      |> Enum.sort_by(fn entry -> entry.title || entry.loc end)
      |> Enum.map_join("\n          ", fn entry ->
        display_title = entry.title || entry.loc

        ~s(<li><a href="#{UrlEntry.escape_xml(entry.loc)}" class="link">#{UrlEntry.escape_xml(display_title)}</a></li>)
      end)

    """
    <!DOCTYPE html>
    <html>
      <head>
    #{html_head(title)}</head>
      <body>
        <div class="container px-4 py-8 max-w-4xl">
          <h1 class="text-4xl font-bold mb-8 text-center">#{UrlEntry.escape_xml(title)}</h1>
          <div class="card">
            <div class="card-body">
              <p class="text-muted mb-4">Total: #{length(entries)} pages</p>
              <ul class="list-disc list-inside space-y-2 columns-1 md:columns-2 lg:columns-3">
    #{links}
              </ul>
            </div>
          </div>
        </div>
      </body>
    </html>
    """
  end

  # ── Internal: helpers ──────────────────────────────────────────────

  defp get_languages do
    if Languages.enabled?() do
      case Languages.get_enabled_languages() do
        languages when is_list(languages) and languages != [] ->
          languages
          |> Enum.map(fn lang ->
            %{
              code: Languages.DialectMapper.extract_base(lang["code"] || lang[:code] || "en"),
              is_default: lang["is_default"] || lang[:is_default] || false
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
      [] -> DateTime.utc_now()
      dates -> dates |> Enum.map(&normalize_to_datetime/1) |> Enum.max(DateTime)
    end
  end

  defp format_lastmod(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp format_lastmod(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_lastmod(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp format_lastmod(%Date{} = d), do: Date.to_iso8601(d)
  defp format_lastmod(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp normalize_to_datetime(%DateTime{} = dt), do: dt

  defp normalize_to_datetime(%NaiveDateTime{} = ndt) do
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  defp normalize_to_datetime(%Date{} = d) do
    DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
  end

  defp normalize_to_datetime(_), do: DateTime.utc_now()

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
