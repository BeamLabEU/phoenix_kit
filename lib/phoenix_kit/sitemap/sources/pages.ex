defmodule PhoenixKit.Sitemap.Sources.Pages do
  @moduledoc """
  Pages source for sitemap generation.

  Collects published pages from the PhoenixKit Pages filesystem-based content system.
  Recursively scans all directories to find markdown files with published status.

  ## URL Structure (NO hardcoded defaults)

  Pages URL prefix is resolved using RouteResolver with fallback chain:
  1. Router Introspection (automatic) - detects routes containing "page" in plug name
  2. Settings override (`sitemap_pages_prefix`)
  3. If none found → pages are NOT included in sitemap

  Examples:
  - `/pages/:slug` for root-level pages
  - `/pages/:folder/:slug` for nested pages
  - `/content/:slug` if parent app uses different prefix

  The `.md` extension is stripped from URLs.

  ## Exclusion

  Pages can be excluded by setting `metadata.sitemap_exclude = true` in the page's frontmatter.

  ## Sitemap Properties

  - Priority: 0.7
  - Change frequency: monthly
  - Category: "Pages"
  - Last modified: Page's updated_at timestamp from metadata
  """

  @behaviour PhoenixKit.Sitemap.Sources.Source

  alias PhoenixKit.Pages
  alias PhoenixKit.Pages.FileOperations
  alias PhoenixKit.Pages.Metadata
  alias PhoenixKit.Settings
  alias PhoenixKit.Sitemap.RouteResolver
  alias PhoenixKit.Sitemap.UrlEntry

  @impl true
  def source_name, do: :pages

  @impl true
  def enabled? do
    Pages.enabled?()
  rescue
    _ -> false
  end

  @impl true
  def collect(opts \\ []) do
    if enabled?() do
      # Check if pages prefix is configured (no hardcoded fallback)
      prefix = get_pages_prefix()

      if prefix do
        base_url = Keyword.get(opts, :base_url)
        collect_pages_recursive("/", base_url, prefix)
      else
        []
      end
    else
      []
    end
  rescue
    error ->
      require Logger

      Logger.warning("Pages sitemap source failed to collect: #{inspect(error)}")

      []
  end

  defp collect_pages_recursive(relative_path, base_url, prefix) do
    case FileOperations.list_directory(relative_path) do
      {:ok, items} ->
        files = collect_files(items, base_url, prefix)
        folders = collect_folders(items, base_url, prefix)

        files ++ folders

      {:error, _reason} ->
        []
    end
  rescue
    error ->
      require Logger

      Logger.warning("Failed to collect pages from #{relative_path}: #{inspect(error)}")

      []
  end

  defp collect_files(items, base_url, prefix) do
    items
    |> Enum.filter(fn item ->
      item.type == :file and markdown_file?(item) and published?(item)
    end)
    |> Enum.reject(&excluded?/1)
    |> Enum.map(fn item ->
      build_entry(item, base_url, prefix)
    end)
  end

  defp collect_folders(items, base_url, prefix) do
    items
    |> Enum.filter(&(&1.type == :folder))
    |> Enum.flat_map(fn item ->
      collect_pages_recursive(item.path, base_url, prefix)
    end)
  end

  defp markdown_file?(item) do
    String.ends_with?(item.name, ".md")
  end

  defp published?(item) do
    case read_metadata(item.path) do
      {:ok, metadata} ->
        metadata.status == "published"

      _ ->
        false
    end
  end

  defp excluded?(item) do
    case read_metadata(item.path) do
      {:ok, metadata} ->
        metadata[:sitemap_exclude] in [true, "true"]

      _ ->
        false
    end
  end

  defp read_metadata(file_path) do
    case FileOperations.read_file(file_path) do
      {:ok, content} ->
        case Metadata.parse(content) do
          {:ok, metadata, _content} -> {:ok, metadata}
          {:error, _} -> {:error, :no_metadata}
        end

      {:error, _reason} ->
        {:error, :read_failed}
    end
  end

  defp build_entry(item, base_url, prefix) do
    slug = path_to_slug(item.path)
    path = "#{prefix}#{slug}"
    url = build_url(path, base_url)

    {:ok, metadata} = read_metadata(item.path)
    title = get_title(metadata, slug)
    lastmod = get_lastmod(metadata)

    UrlEntry.new(%{
      loc: url,
      lastmod: lastmod,
      changefreq: "monthly",
      priority: 0.7,
      title: title,
      category: "Pages",
      source: :pages
    })
  end

  # Resolve pages prefix with fallback chain (NO hardcoded defaults):
  # 1. Router Introspection -> 2. Settings -> 3. nil (skip)
  defp get_pages_prefix do
    case RouteResolver.find_content_route(:pages) do
      nil ->
        # NO hardcoded fallback - return nil if not configured
        Settings.get_setting("sitemap_pages_prefix")

      pattern ->
        # NO hardcoded fallback - return nil if prefix extraction fails
        RouteResolver.extract_prefix(pattern)
    end
  end

  defp path_to_slug(path) do
    path
    |> String.trim_leading("/")
    |> String.replace_suffix(".md", "")
    |> then(&"/#{&1}")
  end

  defp get_title(metadata, fallback_slug) do
    if is_binary(metadata.title) do
      metadata.title
    else
      format_slug(fallback_slug)
    end
  end

  defp get_lastmod(metadata) do
    metadata.updated_at
  end

  defp format_slug(slug) do
    slug
    |> String.trim_leading("/")
    |> String.replace("/", " > ")
    |> String.replace("-", " ")
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # Build URL for public pages (no PhoenixKit prefix)
  defp build_url(path, nil) do
    # Fallback to site_url from settings
    base = PhoenixKit.Settings.get_setting("site_url", "")
    normalized_base = String.trim_trailing(base, "/")
    "#{normalized_base}#{path}"
  end

  defp build_url(path, base_url) when is_binary(base_url) do
    # Pages are public - no PhoenixKit prefix needed
    normalized_base = String.trim_trailing(base_url, "/")
    "#{normalized_base}#{path}"
  end
end
