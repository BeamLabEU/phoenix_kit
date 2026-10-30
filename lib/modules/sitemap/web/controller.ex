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
  alias PhoenixKit.Modules.Sitemap.DomainMode
  alias PhoenixKit.Modules.Sitemap.FileStorage
  alias PhoenixKit.Modules.Sitemap.Generator

  @cache_max_age 3600
  # A miss that arrives this soon after a full generation means the file
  # genuinely doesn't exist — don't regenerate the whole set again for it.
  @on_demand_cooldown_seconds 300
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

      cond do
        Map.get(params, "format") == "html" ->
          serve_html(conn, config, xsl_style)

        host = domain_host(conn) ->
          serve_domain_file(conn, host, "sitemap", xsl_style)

        true ->
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
    # Strip .xml extension if provided in URL
    filename = String.trim_trailing(raw_filename, ".xml")

    cond do
      !Sitemap.enabled?() ->
        send_plain_error(conn, 404, "Sitemap not available")

      not Regex.match?(@filename_pattern, filename) ->
        send_plain_error(conn, 400, "Invalid filename")

      host = domain_host(conn) ->
        # A mapped host only ever resolves inside its own domain dir (split
        # chunks like sitemap-2); never the legacy module files. Checked
        # BEFORE the flat-mode 404 — domain sets are always flat-with-split,
        # independent of the legacy mode, so a >50k domain's chunk files
        # must stay reachable even when the site runs in flat mode.
        serve_domain_file(conn, host, filename, nil)

      Sitemap.flat_mode?() ->
        send_plain_error(
          conn,
          404,
          "Per-module sitemaps not available in flat mode. Use /sitemap.xml"
        )

      true ->
        serve_module_file(conn, filename)
    end
  end

  # The request host when domain mode is active and the host is mapped.
  defp domain_host(conn) do
    case Enum.find(DomainMode.domains(), &(&1.host == String.downcase(conn.host || ""))) do
      %{host: host} -> host
      _ -> nil
    end
  end

  # Serves one host's domain sitemap file: file if present, else regenerate
  # everything on demand (same policy as the legacy index path).
  defp serve_domain_file(conn, host, filename, xsl_style) do
    with {:ok, path} <- FileStorage.domain_file_path(host, filename),
         true <- File.exists?(path) do
      serve_file_with_etag(conn, path, domain_file_stat(path))
    else
      _ ->
        style = xsl_style || get_xsl_style(Sitemap.get_config())

        case generate_on_demand(base_url: Sitemap.get_base_url(), xsl_style: style) do
          {:ok, _} ->
            with {:ok, path} <- FileStorage.domain_file_path(host, filename),
                 true <- File.exists?(path) do
              serve_file_with_etag(conn, path, domain_file_stat(path))
            else
              _ -> send_plain_error(conn, 404, "Sitemap not found")
            end

          {:error, :recently_generated} ->
            send_plain_error(conn, 404, "Sitemap not found")

          {:error, :busy} ->
            send_plain_error(conn, 503, "Sitemap is being generated, retry shortly")

          {:error, _} ->
            send_plain_error(conn, 500, "Sitemap generation failed")
        end
    end
  end

  # generate_etag_from_stat/1 expects the {:ok, mtime, size} shape
  # (FileStorage.get_file_stat/0's contract) — a raw File.stat result would
  # silently degrade every domain file to the shared "default" ETag.
  defp domain_file_stat(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime, size: size}} -> {:ok, mtime, size}
      _ -> :error
    end
  end

  @doc """
  Redirects to XML sitemap (deprecated).
  """
  def html(conn, _params) do
    # Routes.path/2 drops a root prefix ("/"); gluing it on by hand gave
    # "//sitemap.xml", which redirect/2 refuses.
    redirect(conn, to: Routes.path("/sitemap.xml", locale: :none))
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

      case single_flight(fn -> Generator.generate_all(opts) end) do
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

        {:error, :busy} ->
          conn
          |> put_resp_content_type("text/plain")
          |> put_resp_header("retry-after", "5")
          |> send_resp(503, "Sitemap is being generated, retry shortly")

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

  defp generate_module_on_demand(conn, filename) do
    base_url = Sitemap.get_base_url()

    if base_url == "" do
      send_plain_error(conn, 503, "Sitemap not configured")
    else
      opts = [base_url: base_url, xsl_style: "table", xsl_enabled: true]

      case generate_on_demand(opts) do
        {:ok, %{total_urls: url_count, modules: modules}} ->
          Sitemap.update_generation_stats(%{url_count: url_count})
          Sitemap.update_module_stats(modules)

          if FileStorage.module_exists?(filename) do
            path = FileStorage.module_file_path(filename)
            stat = FileStorage.get_module_stat(filename)
            serve_file_with_etag(conn, path, stat)
          else
            send_plain_error(conn, 404, "Module sitemap not found")
          end

        {:error, :recently_generated} ->
          send_plain_error(conn, 404, "Module sitemap not found")

        {:error, :busy} ->
          send_plain_error(conn, 503, "Sitemap is being generated, retry shortly")

        {:error, _} ->
          send_plain_error(conn, 500, "Failed to generate sitemap")
      end
    end
  end

  # ── Private: On-demand generation guard ────────────────────────────

  # A miss on an unauthenticated route used to trigger a FULL regeneration —
  # every source, every language — and then 404. Any anonymous client could
  # therefore fan out N concurrent full generations with N bogus filenames.
  # Two guards: a cooldown (a miss right after a full run means the file
  # simply doesn't exist) and a single-flight lock so concurrent misses
  # coalesce onto one run.
  defp generate_on_demand(opts) do
    if recently_generated?() do
      {:error, :recently_generated}
    else
      single_flight(fn -> Generator.generate_all(opts) end)
    end
  end

  defp recently_generated? do
    with ts when is_binary(ts) <- Sitemap.get_last_generated(),
         {:ok, generated_at, _} <- DateTime.from_iso8601(ts) do
      DateTime.diff(DateTime.utc_now(), generated_at, :second) < @on_demand_cooldown_seconds
    else
      _ -> false
    end
  end

  # `:global.trans/4` with zero retries returns `:aborted` instantly when
  # another request already holds the lock.
  defp single_flight(fun) do
    case :global.trans({__MODULE__, :generate}, fun, [node()], 0) do
      :aborted -> {:error, :busy}
      result -> result
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
