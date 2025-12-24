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

  alias PhoenixKit.Modules.Languages
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
      "prefixed" => false,
      # Don't add language prefix to homepage - it usually doesn't have localized route
      "skip_language_prefix" => true
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
    is_default = Keyword.get(opts, :is_default_language, true)

    # Static pages only generate URLs for the default language
    # Non-default language URLs would lead to 404 errors
    if is_default do
      base_url = Keyword.get(opts, :base_url)
      language = Keyword.get(opts, :language)

      static_entries = collect_static_routes(base_url, language, is_default)
      custom_entries = collect_custom_urls(base_url, language, is_default)

      (static_entries ++ custom_entries)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  rescue
    error ->
      require Logger
      Logger.warning("Static routes sitemap source failed to collect: #{inspect(error)}")
      []
  end

  defp collect_static_routes(base_url, language, is_default) do
    get_static_routes_config()
    |> Enum.map(&build_static_entry(&1, base_url, language, is_default))
  end

  defp collect_custom_urls(base_url, language, is_default) do
    get_custom_urls_config()
    |> Enum.map(&build_custom_entry(&1, base_url, language, is_default))
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

  defp build_static_entry(config, base_url, language, is_default) do
    path = resolve_path(config)

    if path do
      prefixed = Map.get(config, "prefixed", false)
      skip_language = Map.get(config, "skip_language_prefix", false)

      # Canonical path without language prefix (for hreflang grouping)
      canonical_path = if prefixed, do: Routes.path(path), else: path

      # Build localized path (skip language prefix if configured)
      localized_path =
        if skip_language do
          canonical_path
        else
          build_path_with_language(canonical_path, language, is_default)
        end

      url = build_url_from_localized_path(localized_path, base_url, prefixed)

      UrlEntry.new(%{
        loc: url,
        lastmod: nil,
        changefreq: Map.get(config, "changefreq", "weekly"),
        priority: Map.get(config, "priority", 0.5),
        title: Map.get(config, "title", path),
        category: Map.get(config, "category", "Static"),
        source: :static,
        canonical_path: canonical_path
      })
    else
      # Route not found and no explicit path - skip
      nil
    end
  end

  defp build_custom_entry(config, base_url, language, is_default) do
    path = Map.get(config, "path")

    if path do
      # Canonical path without language prefix (for hreflang grouping)
      canonical_path = path
      localized_path = build_path_with_language(path, language, is_default)
      url = build_url_from_localized_path(localized_path, base_url, false)

      UrlEntry.new(%{
        loc: url,
        lastmod: nil,
        changefreq: Map.get(config, "changefreq", "weekly"),
        priority: Map.get(config, "priority", 0.5),
        title: Map.get(config, "title", path),
        category: Map.get(config, "category", "Custom"),
        source: :static,
        canonical_path: canonical_path
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

  # Build URL from already localized path
  defp build_url_from_localized_path(path, nil, _prefixed) do
    base = Settings.get_setting("site_url", "")
    normalized_base = String.trim_trailing(base, "/")
    "#{normalized_base}#{path}"
  end

  defp build_url_from_localized_path(path, base_url, _prefixed) when is_binary(base_url) do
    normalized_base = String.trim_trailing(base_url, "/")
    "#{normalized_base}#{path}"
  end

  # Add language prefix to path when in multi-language mode
  # Single language: no prefix for anyone
  # Multiple languages: ALL languages get prefix (including default)
  defp build_path_with_language(path, language, _is_default) do
    if language && !single_language_mode?() do
      "/#{Languages.DialectMapper.extract_base(language)}#{path}"
    else
      path
    end
  end

  # Check if we're in single language mode (no locale prefix needed)
  # Returns true when languages module is off OR only one language is enabled
  # Mirrors BlogHTML.single_language_mode?/0 logic
  defp single_language_mode? do
    not Languages.enabled?() or length(Languages.get_enabled_languages()) <= 1
  rescue
    _ -> true
  end
end
