defmodule PhoenixKit.Sitemap.Sources.Entities do
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

  - `sitemap_entities_auto_pattern` - Enable auto URL pattern generation (default: true)
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

  @behaviour PhoenixKit.Sitemap.Sources.Source

  require Logger

  alias PhoenixKit.Entities
  alias PhoenixKit.Entities.EntityData
  alias PhoenixKit.Settings
  alias PhoenixKit.Sitemap.RouteResolver
  alias PhoenixKit.Sitemap.UrlEntry

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

    Entities.list_active_entities()
    |> Enum.flat_map(&collect_entity_entries(&1, base_url, include_index, language, is_default))
  end

  defp collect_entity_entries(entity, base_url, include_index, language, is_default) do
    records = collect_entity_records(entity, base_url, language, is_default)

    if include_index do
      prepend_index_entry(records, entity, base_url, language, is_default)
    else
      records
    end
  end

  defp prepend_index_entry(records, entity, base_url, language, is_default) do
    case collect_entity_index(entity, base_url, language, is_default) do
      nil -> records
      index_entry -> [index_entry | records]
    end
  end

  defp collect_entity_records(entity, base_url, language, is_default) do
    url_pattern = get_url_pattern(entity)

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
  rescue
    error ->
      Logger.warning("Failed to collect records for entity #{entity.name}: #{inspect(error)}")

      []
  end

  # Fallback pattern using entity name - can be disabled via settings
  defp get_fallback_pattern(entity) do
    if Settings.get_boolean_setting("sitemap_entities_auto_pattern", true) do
      "/#{entity.name}/:slug"
    else
      nil
    end
  end

  # Collect index page entry for entity (e.g., /page, /products)
  defp collect_entity_index(entity, base_url, language, is_default) do
    index_path = get_index_path(entity)

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

  # Get index path for entity with fallback chain
  # Uses auto-pattern if sitemap_entities_auto_pattern is true (default)
  defp get_index_path(entity) do
    # 1. Check entity settings for explicit index path
    case entity.settings do
      %{"sitemap_index_path" => path} when is_binary(path) and path != "" ->
        path

      _ ->
        # 2. Try Router Introspection for index route
        case RouteResolver.find_index_route(:entity, entity.name) do
          nil ->
            # 3. Check per-entity Settings
            per_entity_key = "sitemap_entity_#{entity.name}_index_path"

            case Settings.get_setting(per_entity_key) do
              nil ->
                # 4. Auto-generate fallback if enabled
                get_fallback_index_path(entity)

              path ->
                path
            end

          path ->
            path
        end
    end
  end

  # Fallback index path using entity name - can be disabled via settings
  defp get_fallback_index_path(entity) do
    if Settings.get_boolean_setting("sitemap_entities_auto_pattern", true) do
      "/#{entity.name}"
    else
      nil
    end
  end

  # Resolve URL pattern with fallback chain (NO hardcoded defaults):
  # 1. entity.settings -> 2. Router Introspection -> 3. Settings -> 4. nil (skip)
  defp get_url_pattern(entity) do
    case entity.settings do
      %{"sitemap_url_pattern" => pattern} when is_binary(pattern) ->
        pattern

      _ ->
        resolve_pattern_from_router_or_settings(entity)
    end
  end

  defp resolve_pattern_from_router_or_settings(entity) do
    # Try Router Introspection first
    case RouteResolver.find_content_route(:entity, entity.name) do
      nil ->
        # Try per-entity Settings
        per_entity_key = "sitemap_entity_#{entity.name}_pattern"

        case Settings.get_setting(per_entity_key) do
          nil ->
            # Try global entities pattern
            case Settings.get_setting("sitemap_entities_pattern") do
              nil ->
                # NO hardcoded fallback - return nil if not configured
                nil

              global_pattern ->
                # Replace :entity_name placeholder
                String.replace(global_pattern, ":entity_name", entity.name)
            end

          pattern ->
            pattern
        end

      pattern ->
        pattern
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

  # Add language prefix to path if not default language
  defp build_path_with_language(path, language, is_default) do
    if language && !is_default do
      "/#{extract_base(language)}#{path}"
    else
      path
    end
  end

  # Extract base language code (e.g., "en" from "en-US")
  defp extract_base(code) when is_binary(code) do
    code |> String.split("-") |> List.first() |> String.downcase()
  end

  defp extract_base(_), do: "en"

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
