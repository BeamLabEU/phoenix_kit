defmodule PhoenixKit.Sitemap.Sources.RouterDiscovery do
  @moduledoc """
  Router Discovery source for sitemap generation.

  Automatically scans all GET routes from the parent application's router
  and includes them in the sitemap. Routes can be filtered using exclude
  patterns and include-only patterns.

  ## Settings

  - `sitemap_router_discovery_enabled` - Enable/disable auto-discovery (default: true)
  - `sitemap_router_discovery_exclude_patterns` - JSON array of regex patterns to exclude
  - `sitemap_router_discovery_include_only` - JSON array of regex patterns for whitelist mode

  ## Default Exclusions

  By default, the following patterns are excluded:
  - `^/admin` - Admin routes
  - `^/api` - API endpoints
  - `^/phoenix_kit` - PhoenixKit admin routes
  - `^/dev` - Development routes
  - `:[a-z_]+` - Routes with parameters
  - `\\*` - Wildcard routes

  ## Examples

      # Enable auto-discovery (default)
      Settings.update_boolean_setting("sitemap_router_discovery_enabled", true)

      # Custom exclude patterns
      Settings.update_setting("sitemap_router_discovery_exclude_patterns",
        Jason.encode!(["^/admin", "^/api", "^/private"]))

      # Whitelist mode - only include specific paths
      Settings.update_setting("sitemap_router_discovery_include_only",
        Jason.encode!(["^/products", "^/categories"]))

  ## Sitemap Properties

  - Priority: 0.5 (default for discovered routes)
  - Change frequency: weekly
  - Category: "Routes"
  """

  @behaviour PhoenixKit.Sitemap.Sources.Source

  alias PhoenixKit.Settings
  alias PhoenixKit.Sitemap.RouteResolver
  alias PhoenixKit.Sitemap.UrlEntry

  @default_exclude_patterns [
    "^/admin",
    "^/api",
    "^/phoenix_kit",
    "^/dev",
    ":[a-z_]+",
    "\\*"
  ]

  @impl true
  def source_name, do: :router_discovery

  @impl true
  def enabled? do
    Settings.get_boolean_setting("sitemap_router_discovery_enabled", true)
  end

  @impl true
  def collect(opts \\ []) do
    if enabled?() do
      do_collect(opts)
    else
      []
    end
  rescue
    error ->
      require Logger
      Logger.warning("RouterDiscovery source failed: #{inspect(error)}")
      []
  end

  defp do_collect(opts) do
    base_url = Keyword.get(opts, :base_url)
    exclude_patterns = get_exclude_patterns()
    include_only = get_include_only_patterns()

    RouteResolver.get_routes()
    |> Enum.filter(&valid_for_sitemap?(&1, exclude_patterns, include_only))
    |> Enum.map(&build_entry(&1, base_url))
    |> Enum.uniq_by(& &1.loc)
  end

  defp valid_for_sitemap?(route, exclude_patterns, include_only) do
    get_route?(route) and
      not excluded?(route.path, exclude_patterns) and
      included?(route.path, include_only)
  end

  defp get_route?(route) do
    route.verb == :get
  end

  defp excluded?(path, patterns) do
    Enum.any?(patterns, fn pattern ->
      case Regex.compile(pattern) do
        {:ok, regex} -> Regex.match?(regex, path)
        _ -> false
      end
    end)
  end

  defp included?(_path, []) do
    # Empty include_only = include all
    true
  end

  defp included?(path, patterns) do
    Enum.any?(patterns, fn pattern ->
      case Regex.compile(pattern) do
        {:ok, regex} -> Regex.match?(regex, path)
        _ -> false
      end
    end)
  end

  defp get_exclude_patterns do
    case Settings.get_setting("sitemap_router_discovery_exclude_patterns") do
      nil ->
        @default_exclude_patterns

      json_string when is_binary(json_string) ->
        case Jason.decode(json_string) do
          {:ok, patterns} when is_list(patterns) -> patterns
          _ -> @default_exclude_patterns
        end

      patterns when is_list(patterns) ->
        patterns

      _ ->
        @default_exclude_patterns
    end
  end

  defp get_include_only_patterns do
    case Settings.get_setting("sitemap_router_discovery_include_only") do
      nil ->
        []

      json_string when is_binary(json_string) ->
        case Jason.decode(json_string) do
          {:ok, patterns} when is_list(patterns) -> patterns
          _ -> []
        end

      patterns when is_list(patterns) ->
        patterns

      _ ->
        []
    end
  end

  defp build_entry(route, base_url) do
    url = build_url(route.path, base_url)
    title = extract_title(route)

    UrlEntry.new(%{
      loc: url,
      lastmod: nil,
      changefreq: "weekly",
      priority: 0.5,
      title: title,
      category: "Routes",
      source: :router_discovery
    })
  end

  defp build_url(path, nil) do
    base = Settings.get_setting("site_url", "")
    normalized_base = String.trim_trailing(base, "/")
    "#{normalized_base}#{path}"
  end

  defp build_url(path, base_url) when is_binary(base_url) do
    normalized_base = String.trim_trailing(base_url, "/")
    "#{normalized_base}#{path}"
  end

  defp extract_title(route) do
    # Try to extract meaningful title from plug module name
    plug_name =
      route.plug
      |> to_string()
      |> String.replace("Elixir.", "")
      |> String.split(".")
      |> List.last()

    # Convert CamelCase to Title Case
    plug_name
    |> String.replace(~r/([A-Z])/, " \\1")
    |> String.trim()
  end
end
