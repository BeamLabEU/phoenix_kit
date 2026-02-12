defmodule PhoenixKit.Modules.Sitemap.Web.Controller do
  @moduledoc """
  Controller for serving XML sitemaps with XSL styling.

  ## Endpoints

  - GET /{prefix}/sitemap.xml - sitemapindex (always)
  - GET /{prefix}/sitemap.xml?format=html - Server-rendered HTML (for iframe previews)
  - GET /{prefix}/sitemap.html - Redirects to sitemap.xml (deprecated)
  - GET /{prefix}/sitemaps/:filename - Per-module sitemap files
  - GET /{prefix}/assets/sitemap/:style - XSL stylesheets for urlset files
  - GET /{prefix}/assets/sitemap-index/:style - XSL stylesheets for sitemapindex

  ## Architecture

  `/sitemap.xml` always returns a `<sitemapindex>` referencing per-module
  sitemap files at `/sitemaps/sitemap-{source}.xml`. Each module file
  contains a `<urlset>` with URLs from that source.
  """

  use PhoenixKitWeb, :controller

  require Logger

  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKit.Modules.Sitemap.FileStorage
  alias PhoenixKit.Modules.Sitemap.Generator

  @cache_max_age 3600
  @valid_xsl_styles ["table", "minimal"]
  # Only allow safe characters in filenames
  @filename_pattern ~r/^[a-z0-9-]+$/

  @doc """
  Serves the sitemapindex XML.

  Always returns a `<sitemapindex>`. Generate on first request if missing.
  Query parameters:
  - `style` - Override XSL style (table, minimal)
  - `format=html` - Force server-side HTML rendering (for iframe previews)
  """
  def xml(conn, params) do
    if Sitemap.enabled?() do
      config = Sitemap.get_config()

      xsl_style =
        case Map.get(params, "style") do
          style when style in @valid_xsl_styles -> style
          _ -> get_xsl_style(config)
        end

      if Map.get(params, "format") == "html" do
        serve_html(conn, config, xsl_style)
      else
        serve_index_xml(conn, xsl_style)
      end
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Sitemap not available")
    end
  end

  @doc """
  Serves per-module sitemap files from /sitemaps/:filename.

  Filename is validated to contain only `[a-z0-9-]` characters.
  The `.xml` extension is appended automatically.
  """
  def module_sitemap(conn, %{"filename" => raw_filename}) do
    cond do
      !Sitemap.enabled?() ->
        send_plain_error(conn, 404, "Sitemap not available")

      Sitemap.flat_mode?() ->
        send_plain_error(
          conn,
          404,
          "Per-module sitemaps not available in flat mode. Use /sitemap.xml"
        )

      true ->
        # Strip .xml extension if provided in URL
        filename = String.trim_trailing(raw_filename, ".xml")

        if Regex.match?(@filename_pattern, filename) do
          serve_module_file(conn, filename)
        else
          send_plain_error(conn, 400, "Invalid filename")
        end
    end
  end

  @doc """
  Redirects to XML sitemap (deprecated).
  """
  def html(conn, _params) do
    prefix = PhoenixKit.Config.get_url_prefix()
    redirect(conn, to: "#{prefix}/sitemap.xml")
  end

  @doc """
  Serves XSL stylesheet files for urlset display.

  Available styles: table, minimal
  """
  def xsl_stylesheet(conn, %{"style" => style}) when style in @valid_xsl_styles do
    serve_xsl_file(conn, "sitemap-#{style}.xsl")
  end

  def xsl_stylesheet(conn, _params) do
    serve_xsl_file(conn, "sitemap-table.xsl")
  end

  @doc """
  Serves XSL stylesheet files for sitemapindex display.
  """
  def xsl_index_stylesheet(conn, %{"style" => style}) when style in @valid_xsl_styles do
    serve_xsl_file(conn, "sitemap-index-#{style}.xsl")
  end

  def xsl_index_stylesheet(conn, _params) do
    serve_xsl_file(conn, "sitemap-index-table.xsl")
  end

  @doc """
  Legacy: Serves sitemap index part files.

  Kept for backward compatibility. New architecture uses /sitemaps/:filename.
  """
  def index_part(conn, %{"index" => index_str}) do
    if Sitemap.enabled?() do
      serve_legacy_index_part(conn, index_str)
    else
      send_plain_error(conn, 404, "Sitemap not available")
    end
  end

  # ── Private: Index serving ─────────────────────────────────────────

  defp serve_index_xml(conn, xsl_style) do
    if FileStorage.index_exists?() do
      serve_file_with_etag(conn, FileStorage.file_path(), FileStorage.get_file_stat())
    else
      generate_and_serve_index(conn, xsl_style)
    end
  end

  defp generate_and_serve_index(conn, xsl_style) do
    base_url = Sitemap.get_base_url()

    if base_url == "" do
      Logger.warning("SitemapController: Base URL not configured")

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(503, "Sitemap not configured. Please set base URL in settings.")
    else
      opts = [base_url: base_url, xsl_style: xsl_style, xsl_enabled: true]

      case Generator.generate_all(opts) do
        {:ok, %{index_xml: xml, total_urls: url_count, modules: modules}} ->
          Sitemap.update_generation_stats(%{url_count: url_count})
          Sitemap.update_module_stats(modules)
          etag = generate_content_etag(xml)

          conn
          |> put_resp_content_type("application/xml")
          |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
          |> put_resp_header("etag", etag)
          |> put_resp_header("x-sitemap-url-count", to_string(url_count))
          |> send_resp(200, xml)

        {:error, reason} ->
          Logger.error("SitemapController: Generation failed: #{inspect(reason)}")

          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(500, "Failed to generate sitemap")
      end
    end
  end

  # ── Private: Module file serving ───────────────────────────────────

  defp serve_module_file(conn, filename) do
    if FileStorage.module_exists?(filename) do
      path = FileStorage.module_file_path(filename)
      stat = FileStorage.get_module_stat(filename)
      serve_file_with_etag(conn, path, stat)
    else
      # Try generating on demand
      generate_module_on_demand(conn, filename)
    end
  end

  defp generate_module_on_demand(conn, _filename) do
    base_url = Sitemap.get_base_url()

    if base_url == "" do
      send_plain_error(conn, 503, "Sitemap not configured")
    else
      # Trigger full generation, then try serving again
      opts = [base_url: base_url, xsl_style: "table", xsl_enabled: true]

      case Generator.generate_all(opts) do
        {:ok, %{total_urls: url_count, modules: modules}} ->
          Sitemap.update_generation_stats(%{url_count: url_count})
          Sitemap.update_module_stats(modules)
          send_plain_error(conn, 404, "Module sitemap not found")

        {:error, _} ->
          send_plain_error(conn, 500, "Failed to generate sitemap")
      end
    end
  end

  # ── Private: Shared file serving with ETag ─────────────────────────

  defp serve_file_with_etag(conn, path, stat_result) do
    etag = generate_etag_from_stat(stat_result)

    if client_has_fresh_cache?(conn, etag) do
      send_not_modified(conn, etag)
    else
      case File.read(path) do
        {:ok, content} ->
          conn
          |> put_resp_content_type("application/xml")
          |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
          |> put_resp_header("etag", etag)
          |> send_resp(200, content)

        {:error, _} ->
          send_plain_error(conn, 404, "File not found")
      end
    end
  end

  # ── Private: HTML serving ──────────────────────────────────────────

  defp serve_html(conn, _config, xsl_style) do
    base_url = Sitemap.get_base_url()

    if base_url == "" do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(503, "Sitemap not configured. Please set base URL in settings.")
    else
      html_style = xsl_to_html_style(xsl_style)
      opts = [base_url: base_url, cache: false, style: html_style]

      case Generator.generate_html(opts) do
        {:ok, html_content} ->
          etag = generate_content_etag(html_content)

          conn
          |> put_resp_content_type("text/html")
          |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
          |> put_resp_header("etag", etag)
          |> send_resp(200, html_content)

        {:error, reason} ->
          Logger.error("SitemapController: HTML generation failed: #{inspect(reason)}")

          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(500, "Failed to generate HTML sitemap")
      end
    end
  end

  # ── Private: XSL serving ───────────────────────────────────────────

  defp serve_xsl_file(conn, xsl_filename) do
    xsl_path = Application.app_dir(:phoenix_kit, "priv/static/assets/#{xsl_filename}")

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
  end

  # ── Private: Legacy index part ─────────────────────────────────────

  defp serve_legacy_index_part(conn, index_str) do
    # Try to serve as a module filename first (new architecture)
    filename = String.trim_trailing(index_str, ".xml")

    if Regex.match?(@filename_pattern, filename) and FileStorage.module_exists?(filename) do
      serve_module_file(conn, filename)
    else
      # Fall back to legacy numbered parts
      case Integer.parse(index_str) do
        {index, ""} when index > 0 ->
          case Generator.get_sitemap_part(index) do
            {:ok, xml_content} ->
              conn
              |> put_resp_content_type("application/xml")
              |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
              |> send_resp(200, xml_content)

            {:error, :not_found} ->
              send_plain_error(conn, 404, "Sitemap part not found")
          end

        _ ->
          send_plain_error(conn, 400, "Invalid sitemap index")
      end
    end
  end

  # ── Private: Helpers ───────────────────────────────────────────────

  defp xsl_to_html_style("table"), do: "grouped"
  defp xsl_to_html_style("minimal"), do: "flat"
  defp xsl_to_html_style(_), do: "hierarchical"

  defp client_has_fresh_cache?(conn, etag) do
    case get_req_header(conn, "if-none-match") do
      [client_etag] -> client_etag == etag
      _ -> false
    end
  end

  defp send_not_modified(conn, etag) do
    conn
    |> put_resp_header("etag", etag)
    |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
    |> send_resp(304, "")
  end

  defp generate_etag_from_stat({:ok, mtime, size}) do
    hash =
      :crypto.hash(:md5, "#{inspect(mtime)}-#{size}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "\"#{hash}\""
  end

  defp generate_etag_from_stat(_), do: "\"default\""

  defp generate_content_etag(content) do
    hash =
      :crypto.hash(:md5, content)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "\"#{hash}\""
  end

  defp send_plain_error(conn, status, message) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end

  defp get_xsl_style(config) do
    html_style = Map.get(config, :html_style, "table")
    xsl_style = Map.get(config, :xsl_style)

    cond do
      xsl_style && xsl_style in @valid_xsl_styles -> xsl_style
      html_style == "grouped" -> "table"
      html_style == "flat" -> "minimal"
      html_style in @valid_xsl_styles -> html_style
      true -> "table"
    end
  end
end
