defmodule PhoenixKitWeb.SitemapController do
  @moduledoc """
  Controller for serving XML sitemaps with XSL styling.

  Provides public endpoints for sitemap access:
  - GET /{prefix}/sitemap.xml - XML sitemap with XSL stylesheet reference
  - GET /{prefix}/sitemap.html - Redirects to sitemap.xml (deprecated)
  - GET /{prefix}/sitemap-{n}.xml - Sitemap index parts (for large sites)
  - GET /{prefix}/assets/sitemap-{style}.xsl - XSL stylesheets

  All endpoints are cached for performance with configurable cache headers.

  ## XSL Stylesheets

  The XML sitemap includes an XSL stylesheet reference that enables beautiful
  browser display without generating separate HTML files. Available styles:
  - table - Clean table layout
  - cards - Cards grouped by category
  - minimal - Simple list of links
  """

  use PhoenixKitWeb, :controller

  alias PhoenixKit.Sitemap
  alias PhoenixKit.Sitemap.Generator
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @cache_max_age 3600
  @valid_xsl_styles ["table", "cards", "minimal"]

  @doc """
  Serves the XML sitemap.

  - Search engine bots receive clean XML (no XSL reference)
  - Browsers receive styled HTML page (server-side transformation)

  Detection is based on Accept header and User-Agent.

  Returns 404 if sitemap module is disabled.
  Returns 500 if sitemap generation fails.
  """
  def xml(conn, params) do
    if Sitemap.enabled?() do
      config = Sitemap.get_config()

      # Force HTML format if ?format=html parameter is present (for iframe preview)
      force_html = Map.get(params, "format") == "html"

      # Override style from query param if provided (for preview)
      config =
        case Map.get(params, "style") do
          style when style in @valid_xsl_styles ->
            Map.put(config, :html_style, style)

          _ ->
            config
        end

      # Check if request is from a browser (wants HTML) vs bot (wants XML)
      if (force_html or browser_request?(conn)) and Map.get(config, :html_enabled, true) do
        serve_styled_html(conn, config)
      else
        serve_raw_xml(conn, config)
      end
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Sitemap not available")
    end
  end

  # Serve raw XML for bots and programmatic access
  defp serve_raw_xml(conn, config) do
    opts = [
      base_url: config.base_url,
      cache: true,
      xsl_enabled: false
    ]

    # Generate ETag from last_generated timestamp for proper HTTP caching
    etag = generate_etag(config)

    case Generator.generate_xml(opts) do
      {:ok, xml_content} ->
        conn
        |> put_resp_content_type("application/xml")
        |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
        |> put_resp_header("etag", etag)
        |> put_resp_header("x-sitemap-url-count", to_string(Sitemap.get_url_count()))
        |> send_resp(200, xml_content)

      {:ok, xml_content, _parts} ->
        conn
        |> put_resp_content_type("application/xml")
        |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
        |> put_resp_header("etag", etag)
        |> put_resp_header("x-sitemap-url-count", to_string(Sitemap.get_url_count()))
        |> send_resp(200, xml_content)

      {:error, reason} ->
        require Logger
        Logger.error("Sitemap XML generation failed: #{inspect(reason)}")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(500, "Failed to generate sitemap")
    end
  end

  # Serve styled HTML for browsers
  defp serve_styled_html(conn, config) do
    xsl_style = get_xsl_style(config)
    entries = Generator.collect_all_entries(base_url: config.base_url)
    html_content = render_sitemap_html(entries, xsl_style, config)

    # Generate ETag from last_generated timestamp for proper HTTP caching
    etag = generate_etag(config)

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
    |> put_resp_header("etag", etag)
    |> put_resp_header("x-sitemap-url-count", to_string(length(entries)))
    |> send_resp(200, html_content)
  end

  # Check if request is from a browser (not a bot)
  defp browser_request?(conn) do
    accept = get_req_header(conn, "accept") |> List.first() || ""
    user_agent = get_req_header(conn, "user-agent") |> List.first() || ""
    user_agent_lower = String.downcase(user_agent)

    # Bot patterns - these should get raw XML
    bot_patterns = ~w(googlebot bingbot yandex baidu spider crawler bot slurp)
    is_bot = Enum.any?(bot_patterns, &String.contains?(user_agent_lower, &1))

    # Browser wants HTML if Accept includes text/html and not a bot
    wants_html = String.contains?(accept, "text/html")

    wants_html and not is_bot
  end

  @doc """
  Redirects to XML sitemap (deprecated).

  HTML sitemap is now served by opening sitemap.xml with XSL styling.
  This endpoint is kept for backward compatibility.
  """
  def html(conn, _params) do
    # Redirect to XML sitemap which now has XSL styling
    prefix = PhoenixKit.Config.get_url_prefix()
    redirect(conn, to: "#{prefix}/sitemap.xml")
  end

  @doc """
  Serves XSL stylesheet files for sitemap display.

  Available styles: table, cards, minimal
  """
  def xsl_stylesheet(conn, %{"style" => style}) do
    if style in @valid_xsl_styles do
      xsl_path = Application.app_dir(:phoenix_kit, "priv/static/assets/sitemap-#{style}.xsl")

      if File.exists?(xsl_path) do
        content = File.read!(xsl_path)

        conn
        |> put_resp_content_type("application/xslt+xml")
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(200, content)
      else
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Stylesheet not found")
      end
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Invalid stylesheet style")
    end
  end

  @doc """
  Serves sitemap index part files for large sitemaps.

  URL format: /sitemap-{index}.xml where index is 1-based.
  Returns 404 if the index doesn't exist.
  """
  def index_part(conn, %{"index" => index_str}) do
    if Sitemap.enabled?() do
      config = Sitemap.get_config()
      etag = generate_etag(config)

      case Integer.parse(index_str) do
        {index, ""} when index > 0 ->
          case Generator.get_sitemap_part(index) do
            {:ok, xml_content} ->
              conn
              |> put_resp_content_type("application/xml")
              |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
              |> put_resp_header("etag", etag)
              |> send_resp(200, xml_content)

            {:error, :not_found} ->
              conn
              |> put_resp_content_type("text/plain")
              |> send_resp(404, "Sitemap part not found")
          end

        _ ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(400, "Invalid sitemap index")
      end
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Sitemap not available")
    end
  end

  # Render sitemap as styled HTML (server-side, no XSLT needed)
  defp render_sitemap_html(entries, style, config) do
    url_count = length(entries)
    last_generated = Map.get(config, :last_generated, "Just now")

    case style do
      "cards" -> render_cards_html(entries, url_count, last_generated)
      "minimal" -> render_minimal_html(entries, url_count)
      _ -> render_table_html(entries, url_count, last_generated)
    end
  end

  defp render_table_html(entries, url_count, _last_generated) do
    rows =
      entries
      |> Enum.sort_by(& &1.loc)
      |> Enum.map_join("\n", fn entry ->
        priority_class =
          cond do
            (entry.priority || 0.5) >= 0.8 -> "high"
            (entry.priority || 0.5) >= 0.5 -> "med"
            true -> "low"
          end

        """
        <tr>
          <td><a href="#{escape(entry.loc)}">#{escape(entry.loc)}</a></td>
          <td>#{escape(UtilsDate.format_datetime_full_with_user_format(entry.lastmod))}</td>
          <td>#{escape(to_string(entry.changefreq || ""))}</td>
          <td class="#{priority_class}">#{entry.priority || ""}</td>
        </tr>
        """
      end)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>XML Sitemap</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 2rem; background: #f8fafc; color: #1e293b; }
        h1 { font-size: 1.5rem; margin-bottom: 1rem; }
        .info { color: #64748b; margin-bottom: 1.5rem; }
        table { width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        th { background: #f1f5f9; padding: 12px; text-align: left; font-size: 12px; text-transform: uppercase; color: #64748b; }
        td { padding: 12px; border-bottom: 1px solid #e2e8f0; }
        tr:last-child td { border-bottom: none; }
        tr:hover td { background: #f8fafc; }
        a { color: #3b82f6; text-decoration: none; word-break: break-all; }
        a:hover { text-decoration: underline; }
        .high { color: #22c55e; font-weight: 600; }
        .med { color: #f59e0b; }
        .low { color: #94a3b8; }
        footer { margin-top: 2rem; text-align: center; color: #94a3b8; font-size: 12px; }
        @media (prefers-color-scheme: dark) {
          body { background: #0f172a; color: #f1f5f9; }
          table { background: #1e293b; }
          th { background: #334155; color: #94a3b8; }
          td { border-color: #334155; }
          tr:hover td { background: #334155; }
        }
      </style>
    </head>
    <body>
      <h1>XML Sitemap</h1>
      <p class="info">This sitemap contains <strong>#{url_count}</strong> URLs</p>
      <table>
        <thead>
          <tr><th>URL</th><th>Last Modified</th><th>Frequency</th><th>Priority</th></tr>
        </thead>
        <tbody>
          #{rows}
        </tbody>
      </table>
      <footer>Generated by PhoenixKit</footer>
    </body>
    </html>
    """
  end

  defp render_cards_html(entries, url_count, _last_generated) do
    # Group entries by category or source
    grouped =
      entries
      |> Enum.group_by(fn entry -> entry.category || to_string(entry.source) || "Other" end)
      |> Enum.sort_by(fn {name, _} -> name end)

    cards =
      Enum.map_join(grouped, "\n", fn {name, group_entries} ->
        items =
          group_entries
          |> Enum.sort_by(& &1.loc)
          |> Enum.map_join("\n", fn entry ->
            meta =
              if entry.lastmod,
                do:
                  "<div class=\"meta\">#{escape(UtilsDate.format_datetime_full_with_user_format(entry.lastmod))}</div>",
                else: ""

            "<li class=\"url-item\"><a href=\"#{escape(entry.loc)}\">#{escape(entry.loc)}</a>#{meta}</li>"
          end)

        """
        <div class="card">
          <div class="card-header">
            <span class="card-title">#{escape(name)}</span>
            <span class="card-count">#{length(group_entries)}</span>
          </div>
          <ul class="url-list">#{items}</ul>
        </div>
        """
      end)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Site Map</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 2rem; background: #f8fafc; color: #1e293b; }
        h1 { font-size: 2rem; text-align: center; margin-bottom: 0.5rem; }
        .subtitle { text-align: center; color: #64748b; margin-bottom: 2rem; }
        .stats { display: flex; justify-content: center; gap: 2rem; margin-bottom: 2rem; }
        .stat { background: white; padding: 1rem 1.5rem; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); text-align: center; }
        .stat-value { font-size: 1.5rem; font-weight: 700; color: #3b82f6; }
        .stat-label { font-size: 12px; color: #64748b; text-transform: uppercase; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1.5rem; }
        .card { background: white; border-radius: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); overflow: hidden; }
        .card-header { padding: 1rem 1.25rem; border-bottom: 1px solid #e2e8f0; display: flex; justify-content: space-between; align-items: center; }
        .card-title { font-weight: 600; }
        .card-count { background: #f1f5f9; padding: 4px 12px; border-radius: 999px; font-size: 12px; color: #64748b; }
        .url-list { list-style: none; padding: 0; margin: 0; max-height: 400px; overflow-y: auto; }
        .url-item { padding: 12px 1.25rem; border-bottom: 1px solid #e2e8f0; }
        .url-item:last-child { border-bottom: none; }
        .url-item:hover { background: #f8fafc; }
        a { color: #3b82f6; text-decoration: none; font-size: 14px; word-break: break-all; }
        a:hover { text-decoration: underline; }
        .meta { font-size: 12px; color: #94a3b8; margin-top: 4px; }
        footer { margin-top: 2rem; text-align: center; color: #94a3b8; font-size: 12px; }
        @media (prefers-color-scheme: dark) {
          body { background: #0f172a; color: #f1f5f9; }
          .stat, .card { background: #1e293b; }
          .card-header, .url-item { border-color: #334155; }
          .url-item:hover { background: #334155; }
          .card-count { background: #334155; color: #94a3b8; }
        }
      </style>
    </head>
    <body>
      <h1>Site Map</h1>
      <p class="subtitle">Browse all pages on this website</p>
      <div class="stats">
        <div class="stat">
          <div class="stat-value">#{url_count}</div>
          <div class="stat-label">Total URLs</div>
        </div>
      </div>
      <div class="cards">#{cards}</div>
      <footer>Generated by PhoenixKit</footer>
    </body>
    </html>
    """
  end

  defp render_minimal_html(entries, url_count) do
    items =
      entries
      |> Enum.sort_by(& &1.loc)
      |> Enum.map_join("\n", fn entry ->
        "<li><a href=\"#{escape(entry.loc)}\">#{escape(entry.loc)}</a></li>"
      end)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Sitemap</title>
      <style>
        body { font-family: system-ui, sans-serif; max-width: 800px; margin: 0 auto; padding: 2rem 1rem; background: #fff; color: #111; line-height: 1.5; }
        h1 { font-size: 1.25rem; font-weight: 600; margin-bottom: 0.5rem; }
        .count { color: #666; font-size: 14px; margin-bottom: 1.5rem; }
        ul { list-style: none; padding: 0; margin: 0; }
        li { padding: 8px 0; border-bottom: 1px solid #eee; }
        li:last-child { border-bottom: none; }
        a { color: #0066cc; text-decoration: none; word-break: break-all; }
        a:hover { text-decoration: underline; }
        footer { margin-top: 2rem; padding-top: 1rem; border-top: 1px solid #eee; font-size: 12px; color: #888; }
        @media (prefers-color-scheme: dark) {
          body { background: #111; color: #eee; }
          li { border-color: #333; }
          a { color: #66b3ff; }
          footer { border-color: #333; }
        }
      </style>
    </head>
    <body>
      <h1>Sitemap</h1>
      <p class="count">#{url_count} URLs</p>
      <ul>#{items}</ul>
      <footer>PhoenixKit Sitemap</footer>
    </body>
    </html>
    """
  end

  defp escape(nil), do: ""

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape(other), do: escape(to_string(other))

  # Generate ETag based on last_generated timestamp and url_count
  # Used for proper HTTP caching - browsers can check if content changed
  defp generate_etag(config) do
    last_generated = Map.get(config, :last_generated) || "none"
    url_count = Map.get(config, :url_count) || 0

    hash =
      :crypto.hash(:md5, "#{last_generated}-#{url_count}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "\"#{hash}\""
  end

  # Maps old HTML style names to new XSL style names
  # hierarchical -> cards, grouped -> table, flat -> minimal
  defp get_xsl_style(config) do
    html_style = Map.get(config, :html_style, "table")
    xsl_style = Map.get(config, :xsl_style)

    # Prefer xsl_style if set, otherwise map from html_style
    cond do
      xsl_style && xsl_style in @valid_xsl_styles ->
        xsl_style

      html_style == "hierarchical" ->
        "cards"

      html_style == "grouped" ->
        "table"

      html_style == "flat" ->
        "minimal"

      html_style in @valid_xsl_styles ->
        html_style

      true ->
        "table"
    end
  end
end
