defmodule PhoenixKit.Sitemap.Generator do
  @moduledoc """
  Main sitemap generator for PhoenixKit.

  Generates XML and HTML sitemaps by collecting URL entries from all enabled
  sources (Entities, Blogging, Pages, etc.) and formatting them according to
  sitemaps.org protocol.

  ## Features

  - **XML Sitemap** - Standards-compliant XML sitemap for search engines
  - **HTML Sitemap** - Human-readable sitemap with 3 display styles
  - **Sitemap Index** - Automatic splitting for large sitemaps (>50,000 URLs)
  - **Caching** - ETS-based caching for fast repeated access
  - **Multi-source** - Collects from all enabled PhoenixKit modules

  ## Usage

      # Generate XML sitemap
      {:ok, xml} = Generator.generate_xml(base_url: "https://example.com")

      # Generate HTML sitemap (hierarchical style)
      {:ok, html} = Generator.generate_html(
        base_url: "https://example.com",
        style: "hierarchical"
      )

      # Clear cache when content changes
      Generator.invalidate_cache()

  ## HTML Styles

  - `"hierarchical"` - Tree structure with categories and nested lists
  - `"grouped"` - Sections grouped by source/category with headers
  - `"flat"` - Simple list of all URLs

  ## Sitemap Index

  When a sitemap exceeds 50,000 URLs or 50MB, it's automatically split into
  multiple part files with a sitemap index file pointing to them.

  ## Configuration

      config :phoenix_kit, :sitemap,
        cache_enabled: true,
        max_urls_per_file: 50_000,
        sources: [
          PhoenixKit.Sitemap.Sources.Static,
          PhoenixKit.Sitemap.Sources.Blogging
        ]
  """

  require Logger

  alias PhoenixKit.Sitemap.Cache
  alias PhoenixKit.Sitemap.Sources.Source
  alias PhoenixKit.Sitemap.UrlEntry

  @max_urls_per_file 50_000
  @xml_declaration ~s(<?xml version="1.0" encoding="UTF-8"?>)
  # Include xhtml namespace for hreflang alternate links
  @urlset_open ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">)
  @urlset_close "</urlset>"
  @sitemapindex_open ~s(<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">)
  @sitemapindex_close "</sitemapindex>"

  # Valid XSL styles
  @valid_xsl_styles ["table", "cards", "minimal"]

  @doc """
  Generates XML sitemap from all enabled sources.

  Returns either a single sitemap or a sitemap index if URLs exceed limit.

  ## Options

  - `:base_url` - Base URL for building full URLs (required)
  - `:language` - Preferred language for content (optional)
  - `:cache` - Enable/disable caching (default: true)
  - `:xsl_style` - XSL stylesheet style: "table", "cards", or "minimal" (optional)
  - `:xsl_enabled` - Enable XSL stylesheet reference in XML (default: true)

  ## XSL Stylesheets

  When `xsl_enabled` is true (default), the generated XML includes an XSL stylesheet
  reference that allows browsers to render the sitemap as a styled HTML page.

  Available styles:
  - `"table"` - Clean table layout similar to Yoast SEO
  - `"cards"` - Cards grouped by category
  - `"minimal"` - Simple list of links

  ## Returns

  - `{:ok, xml_string}` - Generated sitemap XML
  - `{:ok, xml_string, parts}` - Sitemap index with parts list
  - `{:error, reason}` - Generation failed

  ## Examples

      {:ok, xml} = Generator.generate_xml(base_url: "https://example.com")

      {:ok, xml} = Generator.generate_xml(
        base_url: "https://example.com",
        xsl_style: "cards"
      )

      {:ok, index_xml, parts} = Generator.generate_xml(
        base_url: "https://example.com",
        cache: false
      )
  """
  @spec generate_xml(keyword()) ::
          {:ok, String.t()} | {:ok, String.t(), [map()]} | {:error, any()}
  def generate_xml(opts \\ []) do
    base_url = Keyword.get(opts, :base_url)
    cache_enabled = Keyword.get(opts, :cache, true)

    if base_url do
      # Check cache first
      if cache_enabled do
        case Cache.get(:xml) do
          {:ok, cached} ->
            Logger.debug("Sitemap: Using cached XML sitemap")
            {:ok, cached}

          :error ->
            generate_and_cache_xml(opts)
        end
      else
        generate_and_cache_xml(opts, cache: false)
      end
    else
      {:error, :base_url_required}
    end
  end

  @doc """
  Generates HTML sitemap from all enabled sources.

  ## Options

  - `:base_url` - Base URL for building full URLs (required)
  - `:style` - Display style: "hierarchical", "grouped", or "flat" (default: "hierarchical")
  - `:language` - Preferred language for content (optional)
  - `:cache` - Enable/disable caching (default: true)
  - `:title` - Page title (default: "Sitemap")

  ## Examples

      {:ok, html} = Generator.generate_html(
        base_url: "https://example.com",
        style: "hierarchical"
      )

      {:ok, html} = Generator.generate_html(
        base_url: "https://example.com",
        style: "grouped",
        title: "Site Navigation"
      )
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

        # Check cache first
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
  enabled languages and adds hreflang alternate links between language versions.

  ## Options

  - `:base_url` - Base URL for building full URLs (required)
  - `:language` - Preferred language for content (optional, auto-detected if Languages enabled)
  - `:sources` - List of source modules to collect from (optional)
  - `:multilingual` - Enable multilingual collection (default: auto-detect from Languages module)

  ## Examples

      entries = Generator.collect_all_entries(base_url: "https://example.com")
      length(entries)  # => 1234
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

  # Collect entries for a single language (legacy behavior)
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

  # Collect entries for all languages and add hreflang alternates
  defp collect_multilingual_entries(opts, sources, languages) do
    base_url = Keyword.get(opts, :base_url)
    all_language_codes = Enum.map(languages, & &1.code)

    # Collect entries for each language IN PARALLEL
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

    # Group entries by canonical_path and add hreflang alternates
    all_entries =
      entries_by_language
      |> Enum.flat_map(fn {_lang, entries} -> entries end)

    # Get non-default language codes for default entry detection
    non_default_codes =
      languages
      |> Enum.reject(& &1.is_default)
      |> Enum.map(& &1.code)

    # Build alternates map by canonical_path
    alternates_by_canonical =
      all_entries
      |> Enum.filter(& &1.canonical_path)
      |> Enum.group_by(& &1.canonical_path)
      |> Enum.map(fn {canonical_path, entries} ->
        # Find default language entry for x-default
        # Entry from default language has no language prefix in loc
        default_entry =
          Enum.find(entries, fn e ->
            not Enum.any?(non_default_codes, fn code ->
              String.contains?(e.loc, "/#{code}/")
            end)
          end) || List.first(entries)

        alternates =
          entries
          |> Enum.map(fn entry ->
            # Extract language from entry (stored during collection)
            lang_code = extract_language_from_entry(entry, base_url)
            %{hreflang: lang_code, href: entry.loc}
          end)

        # Add x-default pointing to default language
        alternates =
          if default_entry do
            alternates ++ [%{hreflang: "x-default", href: default_entry.loc}]
          else
            alternates
          end

        {canonical_path, alternates}
      end)
      |> Map.new()

    # Add alternates to each entry
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

  # Extract language code from entry URL
  defp extract_language_from_entry(entry, base_url) do
    # Try to extract language from URL path
    path =
      if base_url do
        String.replace(entry.loc, base_url, "")
      else
        entry.loc
      end

    # Check for language prefix pattern like /en/, /et/, /fr/
    case Regex.run(~r/^\/([a-z]{2})(?:\/|$)/, path) do
      [_, lang] -> lang
      # Default to English if no prefix found
      _ -> "en"
    end
  end

  @doc """
  Invalidates all cached sitemaps.

  Should be called when content changes (new pages, updated content, etc).

  ## Examples

      Generator.invalidate_cache()
  """
  @spec invalidate_cache() :: :ok
  def invalidate_cache do
    Logger.debug("Sitemap: Invalidating cache")
    Cache.invalidate()
  end

  @doc """
  Gets a specific sitemap part by index (1-based).

  Used when sitemap is split into multiple files due to size limits.

  ## Examples

      {:ok, xml} = Generator.get_sitemap_part(1)
      {:error, :not_found} = Generator.get_sitemap_part(999)
  """
  @spec get_sitemap_part(integer()) :: {:ok, String.t()} | {:error, :not_found}
  def get_sitemap_part(index) when is_integer(index) and index > 0 do
    case Cache.get(:parts) do
      {:ok, parts} when is_list(parts) ->
        case Enum.find(parts, fn part -> part.index == index end) do
          nil -> {:error, :not_found}
          %{xml: xml} -> {:ok, xml}
        end

      :error ->
        {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  def get_sitemap_part(_), do: {:error, :not_found}

  # Private functions

  defp generate_and_cache_xml(opts, cache_opts \\ []) do
    entries = collect_all_entries(opts)
    base_url = Keyword.fetch!(opts, :base_url)
    cache_enabled = Keyword.get(cache_opts, :cache, true)

    result =
      if length(entries) > @max_urls_per_file do
        generate_sitemap_index(entries, base_url, opts)
      else
        generate_single_sitemap(entries, opts)
      end

    # Cache result
    if cache_enabled do
      case result do
        {:ok, xml} ->
          Cache.put(:xml, xml)
          {:ok, xml}

        {:ok, index_xml, parts} ->
          Cache.put(:xml, index_xml)
          Cache.put(:parts, parts)
          {:ok, index_xml, parts}
      end
    else
      result
    end
  end

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

    # Cache result
    if cache_enabled do
      Cache.put(cache_key, html)
    end

    result
  end

  defp generate_single_sitemap(entries, opts) do
    xml_urls = Enum.map(entries, &UrlEntry.to_xml/1)
    xsl_line = build_xsl_reference(opts)

    # XML declaration MUST be first, then XSL stylesheet PI, then content
    xml =
      [@xml_declaration, xsl_line, @urlset_open, Enum.join(xml_urls, "\n"), @urlset_close]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    {:ok, xml}
  end

  # Build XSL stylesheet reference for browser display
  # Uses relative URL to avoid CORS issues when accessing from different origins
  defp build_xsl_reference(opts) do
    xsl_enabled = Keyword.get(opts, :xsl_enabled, true)
    xsl_style = Keyword.get(opts, :xsl_style, "table")

    if xsl_enabled and xsl_style in @valid_xsl_styles do
      prefix = PhoenixKit.Config.get_url_prefix()
      # Relative URL - works regardless of domain/port the user accesses from
      xsl_url = "#{prefix}/assets/sitemap/#{xsl_style}"
      ~s(<?xml-stylesheet type="text/xsl" href="#{xsl_url}"?>)
    else
      ""
    end
  end

  defp generate_sitemap_index(entries, base_url, opts) do
    # Split entries into chunks
    chunks = Enum.chunk_every(entries, @max_urls_per_file)
    xsl_line = build_xsl_reference(opts)

    # Generate part files metadata
    parts =
      chunks
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, index} ->
        part_urls = Enum.map(chunk, &UrlEntry.to_xml/1)

        part_xml =
          [@xml_declaration, @urlset_open, Enum.join(part_urls, "\n"), @urlset_close]
          |> Enum.join("\n")

        lastmod =
          chunk
          |> Enum.map(& &1.lastmod)
          |> Enum.reject(&is_nil/1)
          |> case do
            [] ->
              DateTime.utc_now()

            dates ->
              dates
              |> Enum.map(&normalize_to_datetime/1)
              |> Enum.max(DateTime)
          end

        %{
          index: index,
          loc: "#{base_url}/sitemap-#{index}.xml",
          lastmod: lastmod,
          xml: part_xml,
          url_count: length(chunk)
        }
      end)

    # Generate sitemap index
    sitemap_entries =
      Enum.map(parts, fn part ->
        lastmod_str =
          case part.lastmod do
            %DateTime{} = dt -> DateTime.to_iso8601(dt)
            %NaiveDateTime{} = ndt -> NaiveDateTime.to_iso8601(ndt)
            %Date{} = d -> Date.to_iso8601(d)
            _ -> DateTime.utc_now() |> DateTime.to_iso8601()
          end

        """
          <sitemap>
            <loc>#{UrlEntry.escape_xml(part.loc)}</loc>
            <lastmod>#{lastmod_str}</lastmod>
          </sitemap>
        """
      end)

    # XML declaration MUST be first, then XSL stylesheet PI, then content
    index_xml =
      [
        @xml_declaration,
        xsl_line,
        @sitemapindex_open,
        Enum.join(sitemap_entries, "\n"),
        @sitemapindex_close
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    {:ok, index_xml, parts}
  end

  defp generate_hierarchical_html(entries, title) do
    # Group by category, then by first letter
    grouped =
      entries
      |> Enum.group_by(fn entry -> entry.category || "Other" end)
      |> Enum.sort_by(fn {category, _} -> category end)

    category_sections =
      Enum.map_join(grouped, "\n", fn {category, category_entries} ->
        # Group by first letter
        letter_groups =
          category_entries
          |> Enum.group_by(fn entry ->
            title = entry.title || entry.loc
            String.upcase(String.at(title, 0) || "")
          end)
          |> Enum.sort_by(fn {letter, _} -> letter end)

        letter_sections =
          Enum.map_join(letter_groups, "\n", fn {letter, letter_entries} ->
            links =
              letter_entries
              |> Enum.sort_by(fn entry -> entry.title || entry.loc end)
              |> Enum.map_join("\n          ", fn entry ->
                display_title = entry.title || entry.loc

                ~s(<li><a href="#{UrlEntry.escape_xml(entry.loc)}" class="link link-primary">#{UrlEntry.escape_xml(display_title)}</a></li>)
              end)

            """
                  <div class="mb-4">
                    <h4 class="text-sm font-semibold text-base-content/70 mb-2">#{letter}</h4>
                    <ul class="ml-4 space-y-1">
                      #{links}
                    </ul>
                  </div>
            """
          end)

        """
              <div class="card bg-base-200 shadow-sm mb-4">
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
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>#{UrlEntry.escape_xml(title)}</title>
      </head>
      <body>
        <div class="container mx-auto px-4 py-8 max-w-6xl">
          <h1 class="text-4xl font-bold mb-8 text-center">#{UrlEntry.escape_xml(title)}</h1>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
    #{category_sections}
          </div>
        </div>
      </body>
    </html>
    """
  end

  defp generate_grouped_html(entries, title) do
    # Group by source or category
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

            ~s(<li><a href="#{UrlEntry.escape_xml(entry.loc)}" class="link link-primary">#{UrlEntry.escape_xml(display_title)}</a></li>)
          end)

        """
              <div class="card bg-base-200 shadow-sm mb-6">
                <div class="card-body">
                  <h2 class="card-title">#{UrlEntry.escape_xml(group)}</h2>
                  <ul class="list-disc list-inside space-y-2 mt-2">
        #{links}
                  </ul>
                  <div class="text-sm text-base-content/60 mt-2">
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
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>#{UrlEntry.escape_xml(title)}</title>
      </head>
      <body>
        <div class="container mx-auto px-4 py-8 max-w-4xl">
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

        ~s(<li><a href="#{UrlEntry.escape_xml(entry.loc)}" class="link link-primary">#{UrlEntry.escape_xml(display_title)}</a></li>)
      end)

    """
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>#{UrlEntry.escape_xml(title)}</title>
      </head>
      <body>
        <div class="container mx-auto px-4 py-8 max-w-4xl">
          <h1 class="text-4xl font-bold mb-8 text-center">#{UrlEntry.escape_xml(title)}</h1>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <p class="text-base-content/70 mb-4">Total: #{length(entries)} pages</p>
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

  defp get_sources do
    # Get configured sources or use default list
    Application.get_env(:phoenix_kit, :sitemap, [])
    |> Keyword.get(:sources, default_sources())
  end

  defp default_sources do
    # List of default source modules
    # RouterDiscovery first to auto-discover all GET routes from parent router
    # Note: Pages content is now handled by Entities source (universal entity support)
    [
      PhoenixKit.Sitemap.Sources.RouterDiscovery,
      PhoenixKit.Sitemap.Sources.Static,
      PhoenixKit.Sitemap.Sources.Blogging,
      PhoenixKit.Sitemap.Sources.Entities,
      PhoenixKit.Sitemap.Sources.Posts
    ]
  end

  # Get list of enabled languages from Languages module
  # Returns list of maps with :code and :is_default keys
  defp get_languages do
    alias PhoenixKit.Modules.Languages

    try do
      if Languages.enabled?() do
        case Languages.get_enabled_languages() do
          languages when is_list(languages) and languages != [] ->
            languages
            |> Enum.map(fn lang ->
              %{
                code: extract_base_language(lang["code"] || lang[:code] || "en"),
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
      _ ->
        # Languages module not available or error
        [%{code: "en", is_default: true}]
    end
  end

  # Extract base language code from full dialect (e.g., "en-US" -> "en")
  defp extract_base_language(code) when is_binary(code) do
    code |> String.split("-") |> List.first() |> String.downcase()
  end

  defp extract_base_language(_), do: "en"

  # Helper to normalize dates to DateTime for comparison
  defp normalize_to_datetime(%DateTime{} = dt), do: dt

  defp normalize_to_datetime(%NaiveDateTime{} = ndt) do
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  defp normalize_to_datetime(%Date{} = d) do
    DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
  end

  defp normalize_to_datetime(_), do: DateTime.utc_now()
end
