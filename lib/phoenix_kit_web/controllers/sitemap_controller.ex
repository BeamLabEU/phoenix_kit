defmodule PhoenixKitWeb.SitemapController do
  @moduledoc """
  Controller for serving XML sitemaps with XSL styling.

  Provides public endpoints for sitemap access:
  - GET /{prefix}/sitemap.xml - XML sitemap with XSL stylesheet reference
  - GET /{prefix}/sitemap.xml?format=html - Server-rendered HTML (for iframe previews)
  - GET /{prefix}/sitemap.html - Redirects to sitemap.xml (deprecated)
  - GET /{prefix}/sitemap-{n}.xml - Sitemap index parts (for large sites)
  - GET /{prefix}/assets/sitemap-{style}.xsl - XSL stylesheets

  ## Architecture: File-Only Storage

  Sitemaps are stored in `priv/static/sitemap.xml` for:
  - Direct nginx/CDN serving (bypasses Phoenix entirely)
  - ETag from file mtime (always reflects actual content)
  - On-demand generation (first request generates if missing)

  ## How It Works

  The XML sitemap includes an XSL stylesheet reference. When opened in a browser,
  the browser applies the XSL transformation client-side, rendering a beautiful
  HTML page. Search engine bots ignore the XSL and read the raw XML.

  For iframe previews (admin panel), use `?format=html` to get server-rendered HTML,
  since iframes cannot apply XSL transformations.

  ## XSL Styles

  Available styles (configurable in settings):
  - table - Clean table layout (default)
  - cards - Cards grouped by category
  - minimal - Simple list of links
  """

  use PhoenixKitWeb, :controller

  require Logger

  alias PhoenixKit.Sitemap
  alias PhoenixKit.Sitemap.FileStorage
  alias PhoenixKit.Sitemap.Generator

  @cache_max_age 3600
  @valid_xsl_styles ["table", "cards", "minimal"]

  @doc """
  Serves the XML sitemap with XSL stylesheet reference.

  Query parameters:
  - `style` - Override XSL style (table, cards, minimal)
  - `format=html` - Force server-side HTML rendering (for iframe previews)

  Returns 404 if sitemap module is disabled.
  Generates on first request if file doesn't exist.
  """
  def xml(conn, params) do
    if Sitemap.enabled?() do
      config = Sitemap.get_config()

      # Override style from query param if provided
      xsl_style =
        case Map.get(params, "style") do
          style when style in @valid_xsl_styles -> style
          _ -> get_xsl_style(config)
        end

      # Check if HTML format is requested (for iframe previews)
      if Map.get(params, "format") == "html" do
        serve_html(conn, config, xsl_style)
      else
        serve_xml(conn, xsl_style)
      end
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Sitemap not available")
    end
  end

  # Serve XML from file or generate on first request
  defp serve_xml(conn, xsl_style) do
    if FileStorage.exists?() do
      serve_existing_file(conn)
    else
      generate_and_serve(conn, xsl_style)
    end
  end

  # Serve existing file with ETag from mtime
  defp serve_existing_file(conn) do
    etag = generate_file_etag()

    if client_has_fresh_cache?(conn, etag) do
      send_not_modified(conn, etag)
    else
      case FileStorage.load() do
        {:ok, xml_content} ->
          conn
          |> put_resp_content_type("application/xml")
          |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
          |> put_resp_header("etag", etag)
          |> put_resp_header("x-sitemap-url-count", to_string(Sitemap.get_url_count()))
          |> send_resp(200, xml_content)

        :error ->
          # File disappeared between exists? and load - regenerate
          generate_and_serve(conn, "table")
      end
    end
  end

  # Generate sitemap on first request, save to file, serve
  defp generate_and_serve(conn, xsl_style) do
    base_url = Sitemap.get_base_url()

    if base_url == "" do
      Logger.warning("SitemapController: Base URL not configured")

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(503, "Sitemap not configured. Please set base URL in settings.")
    else
      opts = [
        base_url: base_url,
        cache: false,
        xsl_style: xsl_style,
        xsl_enabled: true
      ]

      case Generator.generate_xml(opts) do
        {:ok, xml_content} ->
          # Save to file for subsequent requests
          FileStorage.save(xml_content)

          # Update URL count in stats
          entries = Generator.collect_all_entries(base_url: base_url)
          Sitemap.update_generation_stats(%{url_count: length(entries)})

          etag = generate_content_etag(xml_content)

          conn
          |> put_resp_content_type("application/xml")
          |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
          |> put_resp_header("etag", etag)
          |> put_resp_header("x-sitemap-url-count", to_string(length(entries)))
          |> send_resp(200, xml_content)

        {:ok, xml_content, _parts} ->
          # Sitemap index generated
          FileStorage.save(xml_content)

          entries = Generator.collect_all_entries(base_url: base_url)
          Sitemap.update_generation_stats(%{url_count: length(entries)})

          etag = generate_content_etag(xml_content)

          conn
          |> put_resp_content_type("application/xml")
          |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
          |> put_resp_header("etag", etag)
          |> put_resp_header("x-sitemap-url-count", to_string(length(entries)))
          |> send_resp(200, xml_content)

        {:error, reason} ->
          Logger.error("SitemapController: Generation failed: #{inspect(reason)}")

          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(500, "Failed to generate sitemap")
      end
    end
  end

  # Serve server-rendered HTML (for iframe previews where XSL can't be applied)
  defp serve_html(conn, _config, xsl_style) do
    base_url = Sitemap.get_base_url()

    if base_url == "" do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(503, "Sitemap not configured. Please set base URL in settings.")
    else
      html_style = xsl_to_html_style(xsl_style)

      opts = [
        base_url: base_url,
        cache: false,
        style: html_style
      ]

      case Generator.generate_html(opts) do
        {:ok, html_content} ->
          etag = generate_content_etag(html_content)

          conn
          |> put_resp_content_type("text/html")
          |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
          |> put_resp_header("etag", etag)
          |> put_resp_header("x-sitemap-url-count", to_string(Sitemap.get_url_count()))
          |> send_resp(200, html_content)

        {:error, reason} ->
          Logger.error("SitemapController: HTML generation failed: #{inspect(reason)}")

          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(500, "Failed to generate HTML sitemap")
      end
    end
  end

  # Map XSL styles to HTML styles used by Generator
  defp xsl_to_html_style("cards"), do: "hierarchical"
  defp xsl_to_html_style("table"), do: "grouped"
  defp xsl_to_html_style("minimal"), do: "flat"
  defp xsl_to_html_style(_), do: "hierarchical"

  # Check if client has a fresh cached version via If-None-Match header
  defp client_has_fresh_cache?(conn, etag) do
    case get_req_header(conn, "if-none-match") do
      [client_etag] -> client_etag == etag
      _ -> false
    end
  end

  # Send 304 Not Modified response
  defp send_not_modified(conn, etag) do
    conn
    |> put_resp_header("etag", etag)
    |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
    |> send_resp(304, "")
  end

  # Generate ETag from file mtime and size (most reliable)
  defp generate_file_etag do
    case FileStorage.get_file_stat() do
      {:ok, mtime, size} ->
        hash =
          :crypto.hash(:md5, "#{inspect(mtime)}-#{size}")
          |> Base.encode16(case: :lower)
          |> binary_part(0, 16)

        "\"#{hash}\""

      :error ->
        "\"default\""
    end
  end

  # Generate ETag from content (for freshly generated content)
  defp generate_content_etag(content) do
    hash =
      :crypto.hash(:md5, content)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "\"#{hash}\""
  end

  @doc """
  Redirects to XML sitemap (deprecated).

  HTML sitemap is now served by opening sitemap.xml - browsers apply XSL styling.
  This endpoint is kept for backward compatibility.
  """
  def html(conn, _params) do
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
      serve_index_part(conn, index_str)
    else
      send_plain_error(conn, 404, "Sitemap not available")
    end
  end

  defp serve_index_part(conn, index_str) do
    etag = generate_file_etag()

    # Check if client already has this version cached
    if client_has_fresh_cache?(conn, etag) do
      send_not_modified(conn, etag)
    else
      do_serve_index_part(conn, index_str, etag)
    end
  end

  defp do_serve_index_part(conn, index_str, etag) do
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
            send_plain_error(conn, 404, "Sitemap part not found")
        end

      _ ->
        send_plain_error(conn, 400, "Invalid sitemap index")
    end
  end

  defp send_plain_error(conn, status, message) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end

  # Helper Functions

  defp get_xsl_style(config) do
    html_style = Map.get(config, :html_style, "table")
    xsl_style = Map.get(config, :xsl_style)

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
