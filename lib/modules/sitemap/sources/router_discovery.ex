defmodule PhoenixKit.Modules.Sitemap.Sources.RouterDiscovery do
  @moduledoc """
  Router Discovery source for sitemap generation.

  Automatically scans all GET routes from the parent application's router
  and includes them in the sitemap. Routes can be filtered using exclude
  patterns and include-only patterns.

  ## Settings

  - `sitemap_router_discovery_enabled` - Enable/disable auto-discovery (default: true)
  - `sitemap_router_discovery_exclude_patterns` - JSON array of regex patterns to exclude
  - `sitemap_router_discovery_include_only` - JSON array of regex patterns for whitelist mode
  - `sitemap_protected_pipelines` - JSON array of pipeline names that require authentication

  ## Default Exclusions

  By default, the following patterns are excluded:
  - `^/admin` - Admin routes
  - `^/api` - API endpoints
  - `^/phoenix_kit` - PhoenixKit admin routes
  - `^/dev` - Development routes
  - `:[a-z_]+` - Routes with parameters
  - `\\*` - Wildcard routes

  Additionally, routes using authentication pipelines are automatically excluded:
  - `:phoenix_kit_require_authenticated` - Routes requiring user authentication
  - `:phoenix_kit_admin_only` - Routes requiring admin/owner role
  - `:authenticated` - Common name for authentication pipeline
  - `:require_authenticated` - Alternative authentication pipeline name
  - `:admin` - Common admin pipeline name
  - `:admin_only` - Alternative admin pipeline name

  Custom pipelines can be added via `sitemap_protected_pipelines` setting.

  LiveView routes using authentication `on_mount` hooks are also excluded:
  - `{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}` - Ensures user is authenticated
  - `{PhoenixKitWeb.Users.Auth, :phoenix_kit_redirect_if_authenticated_scope}` - Redirects if already authenticated

  ## Examples

      # Enable auto-discovery (default)
      Settings.update_boolean_setting("sitemap_router_discovery_enabled", true)

      # Custom exclude patterns
      Settings.update_setting("sitemap_router_discovery_exclude_patterns",
        Jason.encode!(["^/admin", "^/api", "^/private"]))

      # Whitelist mode - only include specific paths
      Settings.update_setting("sitemap_router_discovery_include_only",
        Jason.encode!(["^/products", "^/categories"]))

      # Custom protected pipelines (add to defaults)
      Settings.update_setting("sitemap_protected_pipelines",
        Jason.encode!(["my_auth_pipeline", "member_only"]))

  ## Sitemap Properties

  - Priority: 0.5 (default for discovered routes)
  - Change frequency: weekly
  - Category: "Routes"
  """

  @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

  require Logger

  alias PhoenixKit.Modules.Sitemap.RouteResolver
  alias PhoenixKit.Modules.Sitemap.UrlEntry
  alias PhoenixKit.Settings

  @default_exclude_patterns [
    "^/admin",
    "^/api",
    "^/phoenix_kit",
    "^/dev",
    "^/sync",
    "^/test",
    "^/dashboard",
    ":[a-z_]+",
    "\\*",
    # Auth pages - should not be indexed by search engines
    "/users/log-in",
    "/users/log-out",
    "/users/register",
    "/users/reset-password",
    "/users/confirm",
    "/users/magic-link",
    "/users/settings",
    # Internal/functional pages - not for search engine indexing
    "/checkout",
    "/cart",
    "/health",
    "/ready",
    # Infrastructure
    "/sitemap\\.",
    "/sitemaps/",
    "/assets/",
    # Homepage is handled by Static source
    "^/$"
  ]

  # Default pipelines that require authentication - routes using these should not appear in sitemap
  # Can be extended via Settings: sitemap_protected_pipelines
  @default_protected_pipelines [
    :phoenix_kit_require_authenticated,
    :phoenix_kit_admin_only,
    :authenticated,
    :require_authenticated,
    :admin,
    :admin_only
  ]

  # Default on_mount hooks that require authentication (for LiveView routes)
  # Format: {Module, hook_name} - matches against on_mount id tuples
  @default_protected_on_mount_hooks [
    {PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope},
    {PhoenixKitWeb.Users.Auth, :phoenix_kit_redirect_if_authenticated_scope}
  ]

  @impl true
  def source_name, do: :router_discovery

  @impl true
  def sitemap_filename, do: "sitemap-routes"

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
      included?(route.path, include_only) and
      not protected_by_route_info?(route)
  end

  # Single route_info call checks both pipelines and on_mount hooks
  defp protected_by_route_info?(route) do
    case get_route_info(route.path) do
      nil ->
        false

      info ->
        has_protected_pipeline?(info) or has_protected_on_mount?(info)
    end
  end

  # Get route_info once per route (instead of twice)
  defp get_route_info(path) do
    case RouteResolver.get_router() do
      nil -> nil
      router -> Phoenix.Router.route_info(router, "GET", path, "localhost")
    end
  rescue
    _ -> nil
  end

  # Check if route_info has protected pipelines
  defp has_protected_pipeline?(%{pipe_through: pipelines}) when is_list(pipelines) do
    protected_pipelines = get_protected_pipelines()
    Enum.any?(protected_pipelines, &(&1 in pipelines))
  end

  defp has_protected_pipeline?(_), do: false

  # Check if route_info has protected on_mount hooks
  defp has_protected_on_mount?(%{
         phoenix_live_view: {_module, _action, _opts, %{extra: %{on_mount: hooks}}}
       })
       when is_list(hooks) do
    hook_ids = Enum.map(hooks, & &1.id)
    Enum.any?(@default_protected_on_mount_hooks, &(&1 in hook_ids))
  end

  defp has_protected_on_mount?(_), do: false

  defp get_protected_pipelines do
    custom_pipelines = get_custom_protected_pipelines()
    @default_protected_pipelines ++ custom_pipelines
  end

  defp get_custom_protected_pipelines do
    case Settings.get_setting("sitemap_protected_pipelines") do
      nil ->
        []

      json_string when is_binary(json_string) ->
        case Jason.decode(json_string) do
          {:ok, pipelines} when is_list(pipelines) ->
            Enum.map(pipelines, &safe_to_atom/1)

          _ ->
            []
        end

      pipelines when is_list(pipelines) ->
        Enum.map(pipelines, &safe_to_atom/1)

      _ ->
        []
    end
  end

  defp safe_to_atom(value) when is_atom(value), do: value
  defp safe_to_atom(value) when is_binary(value), do: String.to_atom(value)

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
