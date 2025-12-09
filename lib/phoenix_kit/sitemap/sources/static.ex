defmodule PhoenixKit.Sitemap.Sources.Static do
  @moduledoc """
  Static routes source for sitemap generation.

  Collects configurable static routes for the sitemap. Routes are configured
  through Settings and resolved via RouteResolver - NO hardcoded fallbacks.

  ## Settings

  - `sitemap_static_routes` - JSON array of route configurations
  - `sitemap_custom_urls` - JSON array of custom URL entries

  ## Route Configuration Format

  Each route in `sitemap_static_routes` can have:

      %{
        "plug" => "PhoenixKitWeb.Users.Registration",  # Module to resolve via RouteResolver
        "path" => "/custom/path",                       # OR explicit path (overrides plug)
        "priority" => 0.7,                              # Sitemap priority (0.0-1.0)
        "changefreq" => "monthly",                      # Change frequency
        "title" => "Register",                          # Display title
        "category" => "Authentication",                 # Category for grouping
        "prefixed" => true                              # Use PhoenixKit URL prefix
      }

  ## Custom URL Format

  Each entry in `sitemap_custom_urls`:

      %{
        "path" => "/about-us",
        "priority" => 0.8,
        "changefreq" => "monthly",
        "title" => "About Us",
        "category" => "Company"
      }

  ## Default Configuration

  By default, includes:
  - Homepage (/) - Priority: 0.9, daily
  - Registration page - Priority: 0.7, monthly (if route exists)
  - Login page - Priority: 0.7, monthly (if route exists)

  ## No Hardcoded Fallbacks

  If RouteResolver cannot find a route and no explicit path is configured,
  the route is skipped. This ensures sitemap only contains valid URLs.
  """

  @behaviour PhoenixKit.Sitemap.Sources.Source

  alias PhoenixKit.Settings
  alias PhoenixKit.Sitemap.RouteResolver
  alias PhoenixKit.Sitemap.UrlEntry
  alias PhoenixKit.Utils.Routes

  @default_static_routes [
    %{
      "path" => "/",
      "priority" => 0.9,
      "changefreq" => "daily",
      "title" => "Home",
      "category" => "Main",
      "prefixed" => false
    },
    %{
      "plug" => "PhoenixKitWeb.Users.Registration",
      "priority" => 0.7,
      "changefreq" => "monthly",
      "title" => "Register",
      "category" => "Authentication",
      "prefixed" => true
    },
    %{
      "plug" => "PhoenixKitWeb.Users.Login",
      "priority" => 0.7,
      "changefreq" => "monthly",
      "title" => "Login",
      "category" => "Authentication",
      "prefixed" => true
    }
  ]

  @impl true
  def source_name, do: :static

  @impl true
  def enabled?, do: true

  @impl true
  def collect(opts \\ []) do
    base_url = Keyword.get(opts, :base_url)

    static_entries = collect_static_routes(base_url)
    custom_entries = collect_custom_urls(base_url)

    (static_entries ++ custom_entries)
    |> Enum.reject(&is_nil/1)
  rescue
    error ->
      require Logger
      Logger.warning("Static routes sitemap source failed to collect: #{inspect(error)}")
      []
  end

  defp collect_static_routes(base_url) do
    get_static_routes_config()
    |> Enum.map(&build_static_entry(&1, base_url))
  end

  defp collect_custom_urls(base_url) do
    get_custom_urls_config()
    |> Enum.map(&build_custom_entry(&1, base_url))
  end

  defp get_static_routes_config do
    case Settings.get_setting("sitemap_static_routes") do
      nil ->
        @default_static_routes

      json_string when is_binary(json_string) ->
        case Jason.decode(json_string) do
          {:ok, routes} when is_list(routes) -> routes
          _ -> @default_static_routes
        end

      routes when is_list(routes) ->
        routes

      _ ->
        @default_static_routes
    end
  end

  defp get_custom_urls_config do
    case Settings.get_setting("sitemap_custom_urls") do
      nil ->
        []

      json_string when is_binary(json_string) ->
        case Jason.decode(json_string) do
          {:ok, urls} when is_list(urls) -> urls
          _ -> []
        end

      urls when is_list(urls) ->
        urls

      _ ->
        []
    end
  end

  defp build_static_entry(config, base_url) do
    path = resolve_path(config)

    if path do
      prefixed = Map.get(config, "prefixed", false)
      url = build_url(path, base_url, prefixed)

      UrlEntry.new(%{
        loc: url,
        lastmod: nil,
        changefreq: Map.get(config, "changefreq", "weekly"),
        priority: Map.get(config, "priority", 0.5),
        title: Map.get(config, "title", path),
        category: Map.get(config, "category", "Static"),
        source: :static
      })
    else
      # Route not found and no explicit path - skip
      nil
    end
  end

  defp build_custom_entry(config, base_url) do
    path = Map.get(config, "path")

    if path do
      url = build_url(path, base_url, false)

      UrlEntry.new(%{
        loc: url,
        lastmod: nil,
        changefreq: Map.get(config, "changefreq", "weekly"),
        priority: Map.get(config, "priority", 0.5),
        title: Map.get(config, "title", path),
        category: Map.get(config, "category", "Custom"),
        source: :static
      })
    else
      nil
    end
  end

  # Resolve path from config: explicit path OR via RouteResolver
  defp resolve_path(%{"path" => path}) when is_binary(path) and path != "" do
    path
  end

  defp resolve_path(%{"plug" => plug_string}) when is_binary(plug_string) do
    # Try to resolve module via RouteResolver
    module = String.to_existing_atom("Elixir." <> plug_string)
    RouteResolver.find_route(module)
  rescue
    # Module doesn't exist - return nil (no hardcoded fallback!)
    _ -> nil
  end

  defp resolve_path(_), do: nil

  # Build URL with or without PhoenixKit prefix
  defp build_url(path, base_url, true = _prefixed) do
    build_prefixed_url(path, base_url)
  end

  defp build_url(path, base_url, false = _prefixed) do
    build_public_url(path, base_url)
  end

  # Build URL for public pages (no PhoenixKit prefix)
  defp build_public_url(path, nil) do
    base = Settings.get_setting("site_url", "")
    normalized_base = String.trim_trailing(base, "/")
    "#{normalized_base}#{path}"
  end

  defp build_public_url(path, base_url) when is_binary(base_url) do
    normalized_base = String.trim_trailing(base_url, "/")
    "#{normalized_base}#{path}"
  end

  # Build URL for PhoenixKit pages (with prefix)
  defp build_prefixed_url(path, nil) do
    Routes.url(path)
  end

  defp build_prefixed_url(path, base_url) when is_binary(base_url) do
    normalized_base = String.trim_trailing(base_url, "/")
    full_path = Routes.path(path)
    "#{normalized_base}#{full_path}"
  end
end
