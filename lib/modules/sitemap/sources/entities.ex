defmodule PhoenixKit.Modules.Sitemap.Sources.Entities do
  @moduledoc """
  Entities source for sitemap generation.

  Collects published entity records from the PhoenixKit Entities system.
  Each entity can define its own URL pattern in settings, and individual
  records can be excluded via metadata.

  ## Universal Entity Support

  This source automatically collects ALL published entities regardless of their name.
  By default, auto-pattern generation is enabled (`sitemap_entities_auto_pattern: true`),
  which means every entity with published records will be included in the sitemap.

  ## URL Pattern Resolution

  URL patterns are resolved using fallback chain:
  1. Entity-specific override: `entity.settings["sitemap_url_pattern"]`
  2. Router Introspection: automatic detection from parent app router
  3. Per-entity Settings: `sitemap_entity_{name}_pattern`
  4. Global Settings: `sitemap_entities_pattern`
  5. Auto-generated fallback: `/:entity_name/:slug` (if `sitemap_entities_auto_pattern` is true)

  Pattern variables:
  - `:slug` - Record slug
  - `:id` - Record ID
  - `:entity_name` - Entity name (for global pattern)

  ## Examples

      # Entity settings override (highest priority):
      # entity.settings = %{"sitemap_url_pattern" => "/blog/:slug"}
      # Generates: /blog/my-article

      # Router auto-detection (if parent app has route):
      # live "/pages/:slug", PagesLive, :show
      # Entity "page" generates: /pages/my-article

      # Settings override:
      # sitemap_entity_page_pattern = "/content/:slug"
      # Entity "page" generates: /content/my-article

      # Auto-generated fallback (enabled by default):
      # Entity "hydraulic_cylinder" generates: /hydraulic_cylinder/my-product
      # Entity "contact_request" generates: /contact_request/request-123

  ## Index Pages

  By default, index/list pages are included for each entity (e.g., `/page`, `/products`).
  This can be controlled via the `sitemap_entities_include_index` setting (default: true).

  Index path resolution:
  1. Entity settings: `entity.settings["sitemap_index_path"]`
  2. Router Introspection: automatic detection (e.g., `/page` or `/pages`)
  3. Per-entity Settings: `sitemap_entity_{name}_index_path`
  4. Auto-generated fallback: `/:entity_name` (if `sitemap_entities_auto_pattern` is true)

  ## Configuration

  - `sitemap_entities_auto_pattern` - Enable auto URL pattern generation (default: false)
  - `sitemap_entities_include_index` - Include entity index pages (default: true)
  - `sitemap_entity_{name}_pattern` - Per-entity URL pattern override
  - `sitemap_entity_{name}_index_path` - Per-entity index page path override
  - `sitemap_entities_pattern` - Global pattern template (e.g., "/:entity_name/:slug")

  ## Exclusion

  Records can be excluded by setting `record.metadata["sitemap_exclude"] = true`.

  ## Sitemap Properties

  **Records:**
  - Priority: 0.8 (high priority for entity content)
  - Change frequency: weekly
  - Category: Entity display name
  - Last modified: Record's date_updated timestamp

  **Index pages:**
  - Priority: 0.7
  - Change frequency: daily
  - Category: Entity display name
  - Last modified: Entity's updated_at timestamp
  """

  @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

  require Logger

  alias PhoenixKit.Modules.Entities
  alias PhoenixKit.Modules.Entities.EntityData
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Sitemap.RouteResolver
  alias PhoenixKit.Modules.Sitemap.UrlEntry
  alias PhoenixKit.Settings

  @impl true
  def source_name, do: :entities

  @impl true
  def enabled? do
    Entities.enabled?()
  rescue
    _ -> false
  end

  @impl true
  def collect(opts \\ []) do
    is_default = Keyword.get(opts, :is_default_language, true)

    # Entities only generate URLs for the default language
    # Non-default language URLs would lead to 404 errors
    if enabled?() and is_default do
      do_collect(opts)
    else
      []
    end
  rescue
    error ->
      Logger.warning("Entities sitemap source failed to collect: #{inspect(error)}")
      []
  end

  defp do_collect(opts) do
    base_url = Keyword.get(opts, :base_url)
    language = Keyword.get(opts, :language)
    is_default = Keyword.get(opts, :is_default_language, true)
    include_index = Settings.get_boolean_setting("sitemap_entities_include_index", true)

    # Optimization: Get all routes ONCE and build lookup map
    routes_cache = build_routes_cache()

    # Early exit if no public entity routes exist
    if map_size(routes_cache.entity_patterns) == 0 and
         not Settings.get_boolean_setting("sitemap_entities_auto_pattern", false) do
      Logger.debug("Sitemap: No public entity routes found, skipping entities source")
      []
    else
      Entities.list_active_entities()
      |> Enum.filter(&entity_has_public_route?(&1, routes_cache))
      |> Enum.flat_map(
        &collect_entity_entries(&1, base_url, include_index, language, is_default, routes_cache)
      )
    end
  end

  # Build a cache of all routes for efficient lookups
  defp build_routes_cache do
    routes = RouteResolver.get_routes()

    # Pre-filter GET routes with :slug or :id params (content routes)
    content_routes =
      Enum.filter(routes, fn route ->
        route.verb == :get and
          (String.contains?(route.path, ":slug") or String.contains?(route.path, ":id"))
      end)

    # Pre-filter GET routes without params (index routes)
    index_routes =
      Enum.filter(routes, fn route ->
        route.verb == :get and
          not String.contains?(route.path, ":") and
          not String.contains?(route.path, "*")
      end)

    # Build entity name -> pattern map for quick lookups
    entity_patterns = build_entity_pattern_map(content_routes)
    entity_index_paths = build_entity_index_map(index_routes)

    %{
      all_routes: routes,
      content_routes: content_routes,
      index_routes: index_routes,
      entity_patterns: entity_patterns,
      entity_index_paths: entity_index_paths
    }
  end

  # Build map of entity_name -> url_pattern from routes
  # Also detects catchall routes like /:entity_name/:slug
  defp build_entity_pattern_map(content_routes) do
    # Check for catchall route first
    catchall_route = find_catchall_content_route(content_routes)

    content_routes
    |> Enum.reduce(%{catchall: catchall_route}, fn route, acc ->
      path_lower = String.downcase(route.path)

      # Extract entity name from path like /products/:slug or /product/:id
      case extract_entity_from_path(path_lower) do
        nil -> acc
        entity_name -> Map.put_new(acc, entity_name, route.path)
      end
    end)
  end

  # Build map of entity_name -> index_path from routes
  # Also detects catchall routes like /:entity_name
  defp build_entity_index_map(index_routes) do
    # Check for catchall index route first
    catchall_route = find_catchall_index_route(index_routes)

    index_routes
    |> Enum.reduce(%{catchall: catchall_route}, fn route, acc ->
      path_lower = String.downcase(route.path)

      # Extract entity name from path like /products or /product
      case extract_entity_from_index_path(path_lower) do
        nil -> acc
        entity_name -> Map.put_new(acc, entity_name, route.path)
      end
    end)
  end

  # Find catchall content route like /:entity_name/:slug
  defp find_catchall_content_route(routes) do
    Enum.find(routes, fn route ->
      # Match patterns like /:entity_name/:slug, /:name/:slug, /:type/:id
      Regex.match?(~r{^/:[a-z_]+/:[a-z_]+$}, route.path)
    end)
  end

  # Find catchall index route like /:entity_name
  defp find_catchall_index_route(routes) do
    Enum.find(routes, fn route ->
      # Match patterns like /:entity_name, /:name (single param at root)
      Regex.match?(~r{^/:[a-z_]+$}, route.path)
    end)
  end

  # Extract entity name from content path like /products/:slug -> "product"
  defp extract_entity_from_path(path) do
    case Regex.run(~r{^/([a-z_]+)s?/:[a-z_]+$}, path) do
      [_, name] -> String.trim_trailing(name, "s")
      _ -> nil
    end
  end

  # Extract entity name from index path like /products -> "product"
  defp extract_entity_from_index_path(path) do
    case Regex.run(~r{^/([a-z_]+)s?$}, path) do
      [_, name] -> String.trim_trailing(name, "s")
      _ -> nil
    end
  end

  # Check if entity has a public route (either in router or auto-pattern enabled)
  defp entity_has_public_route?(entity, routes_cache) do
    entity_lower = String.downcase(entity.name)

    # Check if entity has explicit route in router
    has_explicit_route =
      Map.has_key?(routes_cache.entity_patterns, entity_lower) or
        Map.has_key?(routes_cache.entity_patterns, entity.name)

    # Check if catchall route exists (like /:entity_name/:slug)
    has_catchall_route = routes_cache.entity_patterns[:catchall] != nil

    # Check if entity has settings override
    has_settings_pattern =
      case entity.settings do
        %{"sitemap_url_pattern" => pattern} when is_binary(pattern) and pattern != "" -> true
        _ -> Settings.get_setting("sitemap_entity_#{entity.name}_pattern") != nil
      end

    # Check if auto-pattern is enabled (fallback for all entities)
    auto_pattern_enabled = Settings.get_boolean_setting("sitemap_entities_auto_pattern", false)

    has_explicit_route or has_catchall_route or has_settings_pattern or auto_pattern_enabled
  end

  defp collect_entity_entries(entity, base_url, include_index, language, is_default, routes_cache) do
    records = collect_entity_records(entity, base_url, language, is_default, routes_cache)

    if include_index do
      prepend_index_entry(records, entity, base_url, language, is_default, routes_cache)
    else
      records
    end
  end

  defp prepend_index_entry(records, entity, base_url, language, is_default, routes_cache) do
    case collect_entity_index(entity, base_url, language, is_default, routes_cache) do
      nil -> records
      index_entry -> [index_entry | records]
    end
  end

  defp collect_entity_records(entity, base_url, language, is_default, routes_cache) do
    # Skip entities whose routes require authentication (using cached routes)
    if entity_requires_auth_cached?(entity, routes_cache) do
      Logger.debug("Sitemap: Entity '#{entity.name}' skipped - routes require authentication")

      []
    else
      # Use cached pattern lookup instead of RouteResolver calls
      url_pattern = get_url_pattern_cached(entity, routes_cache)

      # If no URL pattern found (no route, no settings) - use entity name as fallback
      effective_pattern = url_pattern || get_fallback_pattern(entity)

      if effective_pattern do
        records = EntityData.published_records(entity.id)

        if url_pattern do
          Logger.debug(
            "Sitemap: Entity '#{entity.name}' using URL pattern: #{url_pattern} (#{length(records)} published records)"
          )
        else
          Logger.info(
            "Sitemap: Entity '#{entity.name}' using fallback pattern: #{effective_pattern} (#{length(records)} published records)"
          )
        end

        records
        |> Enum.reject(&excluded?/1)
        |> Enum.map(fn record ->
          build_entry(record, entity, effective_pattern, base_url, language, is_default)
        end)
      else
        Logger.warning(
          "Sitemap: Entity '#{entity.name}' skipped - no URL pattern configured and fallback disabled"
        )

        []
      end
    end
  rescue
    error ->
      Logger.warning("Failed to collect records for entity #{entity.name}: #{inspect(error)}")

      []
  end

  # Fallback pattern using entity name - disabled by default
  # Enable via Settings: sitemap_entities_auto_pattern = true
  # WARNING: Only enable if you're sure routes exist for all entities
  defp get_fallback_pattern(entity) do
    if Settings.get_boolean_setting("sitemap_entities_auto_pattern", false) do
      "/#{entity.name}/:slug"
    else
      nil
    end
  end

  # Collect index page entry for entity (e.g., /page, /products) - cached version
  defp collect_entity_index(entity, base_url, language, is_default, routes_cache) do
    index_path = get_index_path_cached(entity, routes_cache)

    if index_path do
      # Canonical path without language prefix (for hreflang grouping)
      canonical_path = index_path
      path = build_path_with_language(index_path, language, is_default)
      url = build_url(path, base_url)

      UrlEntry.new(%{
        loc: url,
        lastmod: entity.date_updated || entity.date_created,
        changefreq: "daily",
        priority: 0.7,
        title: "#{entity.display_name || String.capitalize(entity.name)} - Index",
        category: entity.display_name || entity.name,
        source: :entities,
        canonical_path: canonical_path
      })
    else
      nil
    end
  rescue
    error ->
      Logger.warning("Failed to collect index for entity #{entity.name}: #{inspect(error)}")
      nil
  end

  # Get index path using cached routes (no RouteResolver calls)
  # Priority: entity settings -> cached lookup -> catchall -> per-entity settings -> fallback
  defp get_index_path_cached(entity, routes_cache) do
    get_index_from_entity_settings(entity) ||
      get_index_from_cache(entity, routes_cache) ||
      get_index_from_catchall(entity, routes_cache) ||
      get_index_from_settings(entity) ||
      get_fallback_index_path(entity)
  end

  defp get_index_from_entity_settings(entity) do
    case entity.settings do
      %{"sitemap_index_path" => path} when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp get_index_from_cache(entity, routes_cache) do
    entity_lower = String.downcase(entity.name)

    Map.get(routes_cache.entity_index_paths, entity_lower) ||
      Map.get(routes_cache.entity_index_paths, entity.name)
  end

  defp get_index_from_catchall(entity, routes_cache) do
    case routes_cache.entity_index_paths[:catchall] do
      %{path: _} -> "/#{entity.name}"
      _ -> nil
    end
  end

  defp get_index_from_settings(entity) do
    Settings.get_setting("sitemap_entity_#{entity.name}_index_path")
  end

  # Fallback index path using entity name - disabled by default
  defp get_fallback_index_path(entity) do
    if Settings.get_boolean_setting("sitemap_entities_auto_pattern", false) do
      "/#{entity.name}"
    else
      nil
    end
  end

  # Get URL pattern using cached routes (no RouteResolver calls)
  # Fallback chain: entity.settings -> cached routes -> per-entity settings -> global pattern
  defp get_url_pattern_cached(entity, routes_cache) do
    get_pattern_from_entity_settings(entity) ||
      get_pattern_from_cache(entity, routes_cache) ||
      get_pattern_from_settings(entity)
  end

  defp get_pattern_from_entity_settings(entity) do
    case entity.settings do
      %{"sitemap_url_pattern" => pattern} when is_binary(pattern) and pattern != "" -> pattern
      _ -> nil
    end
  end

  defp get_pattern_from_cache(entity, routes_cache) do
    entity_lower = String.downcase(entity.name)

    # First try explicit route for this entity
    explicit_pattern =
      Map.get(routes_cache.entity_patterns, entity_lower) ||
        Map.get(routes_cache.entity_patterns, entity.name)

    if explicit_pattern do
      explicit_pattern
    else
      # Fall back to catchall route, replacing param with entity name
      case routes_cache.entity_patterns[:catchall] do
        nil -> nil
        %{path: path} -> String.replace(path, ~r{^/:[a-z_]+/}, "/#{entity.name}/")
      end
    end
  end

  defp get_pattern_from_settings(entity) do
    per_entity_key = "sitemap_entity_#{entity.name}_pattern"

    case Settings.get_setting(per_entity_key) do
      nil -> get_global_pattern(entity)
      pattern -> pattern
    end
  end

  defp get_global_pattern(entity) do
    case Settings.get_setting("sitemap_entities_pattern") do
      nil -> nil
      global_pattern -> String.replace(global_pattern, ":entity_name", entity.name)
    end
  end

  # Check if entity requires auth using cached routes
  defp entity_requires_auth_cached?(entity, routes_cache) do
    entity_lower = String.downcase(entity.name)

    # Find the route for this entity in cached routes
    route =
      Enum.find(routes_cache.content_routes, fn route ->
        path_lower = String.downcase(route.path)

        String.contains?(path_lower, "/#{entity_lower}/") or
          String.contains?(path_lower, "/#{entity_lower}s/") or
          String.starts_with?(path_lower, "/#{entity_lower}/") or
          String.starts_with?(path_lower, "/#{entity_lower}s/")
      end)

    cond do
      # Found explicit route for this entity
      route != nil ->
        RouteResolver.route_requires_auth?(route)

      # Check catchall route
      routes_cache.entity_patterns[:catchall] != nil ->
        RouteResolver.route_requires_auth?(routes_cache.entity_patterns[:catchall])

      # No route found
      true ->
        false
    end
  end

  defp excluded?(record) do
    case record.metadata do
      %{"sitemap_exclude" => true} -> true
      %{"sitemap_exclude" => "true"} -> true
      _ -> false
    end
  end

  defp build_entry(record, entity, url_pattern, base_url, language, is_default) do
    # Canonical path without language prefix (for hreflang grouping)
    canonical_path = build_path(url_pattern, record)
    path = build_path_with_language(canonical_path, language, is_default)
    url = build_url(path, base_url)

    UrlEntry.new(%{
      loc: url,
      lastmod: record.date_updated,
      changefreq: "weekly",
      priority: 0.8,
      title: record.title,
      category: entity.display_name || entity.name,
      source: :entities,
      canonical_path: canonical_path
    })
  end

  defp build_path(pattern, record) do
    pattern
    |> String.replace(":slug", record.slug || to_string(record.id))
    |> String.replace(":id", to_string(record.id))
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
  # Mirrors PublishingHTML.single_language_mode?/0 logic
  defp single_language_mode? do
    not Languages.enabled?() or length(Languages.get_enabled_languages()) <= 1
  rescue
    _ -> true
  end

  # Build URL for public entity pages (no PhoenixKit prefix)
  defp build_url(path, nil) do
    # Fallback to site_url from settings
    base = PhoenixKit.Settings.get_setting("site_url", "")
    normalized_base = String.trim_trailing(base, "/")
    "#{normalized_base}#{path}"
  end

  defp build_url(path, base_url) when is_binary(base_url) do
    # Entity pages are public - no PhoenixKit prefix needed
    normalized_base = String.trim_trailing(base_url, "/")
    "#{normalized_base}#{path}"
  end
end
