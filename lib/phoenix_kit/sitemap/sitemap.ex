defmodule PhoenixKit.Sitemap do
  @moduledoc """
  Sitemap generation and management context for PhoenixKit.

  This module provides functions for generating and managing XML and HTML sitemaps
  using Settings for configuration storage. Sitemaps help search engines discover
  and index site content.

  ## Core Functions

  ### System Control

  - `enabled?/0` - Check if sitemap module is enabled
  - `enable_system/0` - Enable sitemap module
  - `disable_system/0` - Disable sitemap module

  ### Configuration

  - `get_config/0` - Get current sitemap configuration
  - `get_base_url/0` - Get base URL for sitemap generation
  - `build_url/1` - Build full URL from relative path
  - `schedule_enabled?/0` - Check if automatic generation is enabled
  - `get_schedule_interval_hours/0` - Get generation interval in hours

  ### Content Settings

  - `include_entities?/0` - Check if entities should be included (all entity types)
  - `include_blogs?/0` - Check if blog posts should be included
  - `include_static?/0` - Check if static pages should be included

  ### HTML Sitemap

  - `html_enabled?/0` - Check if HTML sitemap is enabled
  - `get_html_style/0` - Get HTML sitemap display style
  - `get_default_changefreq/0` - Get default change frequency
  - `get_default_priority/0` - Get default URL priority

  ### Generation

  - `regenerate/1` - Trigger sitemap regeneration
  - `update_generation_stats/1` - Update generation statistics
  - `get_cached_xml/0` - Get cached XML sitemap
  - `get_cached_html/0` - Get cached HTML sitemap
  - `invalidate_cache/0` - Clear sitemap cache

  ## Settings Keys

  All configuration is stored in the Settings system:

  - `sitemap_enabled` - Enable/disable sitemap module (boolean)
  - `sitemap_schedule_enabled` - Enable automatic generation (boolean)
  - `sitemap_schedule_interval_hours` - Generation interval (integer)
  - `sitemap_include_entities` - Include entities in sitemap (boolean, all entity types)
  - `sitemap_include_blogs` - Include blog posts (boolean)
  - `sitemap_include_static` - Include static pages (boolean)
  - `sitemap_base_url` - Base URL for sitemap (string, fallback to site_url)
  - `sitemap_html_enabled` - Enable HTML sitemap (boolean)
  - `sitemap_html_style` - HTML display style (hierarchical/flat/grouped)
  - `sitemap_default_changefreq` - Default change frequency (string)
  - `sitemap_default_priority` - Default URL priority (string)
  - `sitemap_last_generated` - Last generation timestamp (ISO8601)
  - `sitemap_url_count` - Number of URLs in sitemap (integer)

  ## Usage Examples

      # Check if sitemap module is enabled
      if PhoenixKit.Sitemap.enabled?() do
        # Generate sitemap
        PhoenixKit.Sitemap.regenerate(scope)
      end

      # Get configuration
      config = PhoenixKit.Sitemap.get_config()
      # => %{
      #   enabled: true,
      #   schedule_enabled: true,
      #   schedule_interval_hours: 24,
      #   include_entities: true,
      #   include_blogs: true,
      #   include_static: true,
      #   base_url: "https://example.com",
      #   html_enabled: true,
      #   html_style: "hierarchical",
      #   default_changefreq: "weekly",
      #   default_priority: "0.5",
      #   last_generated: "2025-12-02T10:30:00Z",
      #   url_count: 150
      # }

      # Build full URLs
      url = PhoenixKit.Sitemap.build_url("/about")
      # => "https://example.com/about"

      # Get cached sitemaps
      xml = PhoenixKit.Sitemap.get_cached_xml()
      html = PhoenixKit.Sitemap.get_cached_html()

      # Invalidate cache after regeneration
      PhoenixKit.Sitemap.invalidate_cache()
  """

  require Logger

  @enabled_key "sitemap_enabled"

  # Setting keys
  @schedule_enabled_key "sitemap_schedule_enabled"
  @schedule_interval_key "sitemap_schedule_interval_hours"
  @include_entities_key "sitemap_include_entities"
  @include_blogs_key "sitemap_include_blogs"
  @include_static_key "sitemap_include_static"
  @router_discovery_key "sitemap_router_discovery_enabled"
  @html_enabled_key "sitemap_html_enabled"
  @html_style_key "sitemap_html_style"
  @default_changefreq_key "sitemap_default_changefreq"
  @default_priority_key "sitemap_default_priority"
  @last_generated_key "sitemap_last_generated"
  @url_count_key "sitemap_url_count"

  # Cache keys
  @cache_xml_key "sitemap_xml_cache"
  @cache_html_key "sitemap_html_cache"

  # Default values
  @default_schedule_enabled true
  @default_schedule_interval_hours 24
  @default_include_entities true
  @default_include_blogs true
  @default_include_static true
  @default_router_discovery true
  @default_html_enabled true
  @default_html_style "hierarchical"
  @default_changefreq "weekly"
  @default_priority "0.5"

  ## System Control Functions

  @doc """
  Returns true when the sitemap module is enabled.

  ## Examples

      iex> PhoenixKit.Sitemap.enabled?()
      false

      iex> PhoenixKit.Sitemap.enable_system()
      iex> PhoenixKit.Sitemap.enabled?()
      true
  """
  @spec enabled?() :: boolean()
  def enabled? do
    settings_call(:get_boolean_setting, [@enabled_key, false])
  end

  @doc """
  Enables the sitemap module.

  ## Examples

      iex> PhoenixKit.Sitemap.enable_system()
      {:ok, %PhoenixKit.Settings.Setting{}}
  """
  @spec enable_system() :: {:ok, any()} | {:error, any()}
  def enable_system do
    settings_call(:update_boolean_setting, [@enabled_key, true])
  end

  @doc """
  Disables the sitemap module.

  ## Examples

      iex> PhoenixKit.Sitemap.disable_system()
      {:ok, %PhoenixKit.Settings.Setting{}}
  """
  @spec disable_system() :: {:ok, any()} | {:error, any()}
  def disable_system do
    settings_call(:update_boolean_setting, [@enabled_key, false])
  end

  ## Configuration Functions

  @doc """
  Returns the current sitemap configuration as a map.

  ## Examples

      iex> PhoenixKit.Sitemap.get_config()
      %{
        enabled: true,
        schedule_enabled: true,
        schedule_interval_hours: 24,
        include_entities: true,
        include_blogs: true,
        include_pages: true,
        include_static: true,
        base_url: "https://example.com",
        html_enabled: true,
        html_style: "hierarchical",
        default_changefreq: "weekly",
        default_priority: "0.5",
        last_generated: "2025-12-02T10:30:00Z",
        url_count: 150
      }
  """
  @spec get_config() :: map()
  def get_config do
    %{
      enabled: enabled?(),
      schedule_enabled: schedule_enabled?(),
      schedule_interval_hours: get_schedule_interval_hours(),
      router_discovery_enabled: router_discovery_enabled?(),
      include_entities: include_entities?(),
      include_blogs: include_blogs?(),
      include_static: include_static?(),
      base_url: get_base_url(),
      html_enabled: html_enabled?(),
      html_style: get_html_style(),
      default_changefreq: get_default_changefreq(),
      default_priority: get_default_priority(),
      last_generated: get_last_generated(),
      url_count: get_url_count()
    }
  end

  @doc """
  Returns the base URL for sitemap generation.

  Uses site_url from Settings. Returns empty string if not configured.

  ## Examples

      iex> PhoenixKit.Sitemap.get_base_url()
      "https://example.com"
  """
  @spec get_base_url() :: String.t()
  def get_base_url do
    settings_call(:get_setting_cached, ["site_url", ""])
  end

  @doc """
  Builds a full URL from a relative path using the configured base URL.

  ## Examples

      iex> PhoenixKit.Sitemap.build_url("/about")
      "https://example.com/about"

      iex> PhoenixKit.Sitemap.build_url("contact")
      "https://example.com/contact"
  """
  @spec build_url(String.t()) :: String.t()
  def build_url(path) when is_binary(path) do
    base_url = get_base_url()

    # Ensure base URL doesn't end with slash
    base_url = String.trim_trailing(base_url, "/")

    # Ensure path starts with slash
    path =
      if String.starts_with?(path, "/") do
        path
      else
        "/" <> path
      end

    base_url <> path
  end

  @doc """
  Returns true if automatic sitemap generation is enabled.

  ## Examples

      iex> PhoenixKit.Sitemap.schedule_enabled?()
      true
  """
  @spec schedule_enabled?() :: boolean()
  def schedule_enabled? do
    settings_call(:get_boolean_setting, [@schedule_enabled_key, @default_schedule_enabled])
  end

  @doc """
  Returns the scheduled generation interval in hours.

  ## Examples

      iex> PhoenixKit.Sitemap.get_schedule_interval_hours()
      24
  """
  @spec get_schedule_interval_hours() :: integer()
  def get_schedule_interval_hours do
    settings_call(:get_integer_setting, [
      @schedule_interval_key,
      @default_schedule_interval_hours
    ])
  end

  ## Content Inclusion Functions

  @doc """
  Returns true if entities should be included in sitemap.

  ## Examples

      iex> PhoenixKit.Sitemap.include_entities?()
      true
  """
  @spec include_entities?() :: boolean()
  def include_entities? do
    settings_call(:get_boolean_setting, [@include_entities_key, @default_include_entities])
  end

  @doc """
  Returns true if blog posts should be included in sitemap.

  ## Examples

      iex> PhoenixKit.Sitemap.include_blogs?()
      true
  """
  @spec include_blogs?() :: boolean()
  def include_blogs? do
    settings_call(:get_boolean_setting, [@include_blogs_key, @default_include_blogs])
  end

  @doc """
  Returns true if static pages should be included in sitemap.

  ## Examples

      iex> PhoenixKit.Sitemap.include_static?()
      true
  """
  @spec include_static?() :: boolean()
  def include_static? do
    settings_call(:get_boolean_setting, [@include_static_key, @default_include_static])
  end

  @doc """
  Returns true if router discovery should be enabled.

  Router discovery automatically scans the parent application's router
  for GET routes and includes them in the sitemap.

  ## Examples

      iex> PhoenixKit.Sitemap.router_discovery_enabled?()
      true
  """
  @spec router_discovery_enabled?() :: boolean()
  def router_discovery_enabled? do
    settings_call(:get_boolean_setting, [@router_discovery_key, @default_router_discovery])
  end

  ## HTML Sitemap Functions

  @doc """
  Returns true if HTML sitemap generation is enabled.

  ## Examples

      iex> PhoenixKit.Sitemap.html_enabled?()
      true
  """
  @spec html_enabled?() :: boolean()
  def html_enabled? do
    settings_call(:get_boolean_setting, [@html_enabled_key, @default_html_enabled])
  end

  @doc """
  Returns the HTML sitemap display style.

  Valid values: "hierarchical", "flat", "grouped"

  ## Examples

      iex> PhoenixKit.Sitemap.get_html_style()
      "hierarchical"
  """
  @spec get_html_style() :: String.t()
  def get_html_style do
    settings_call(:get_setting_cached, [@html_style_key, @default_html_style])
  end

  @doc """
  Returns the default change frequency for sitemap URLs.

  ## Examples

      iex> PhoenixKit.Sitemap.get_default_changefreq()
      "weekly"
  """
  @spec get_default_changefreq() :: String.t()
  def get_default_changefreq do
    settings_call(:get_setting_cached, [@default_changefreq_key, @default_changefreq])
  end

  @doc """
  Returns the default priority for sitemap URLs.

  ## Examples

      iex> PhoenixKit.Sitemap.get_default_priority()
      "0.5"
  """
  @spec get_default_priority() :: String.t()
  def get_default_priority do
    settings_call(:get_setting_cached, [@default_priority_key, @default_priority])
  end

  ## Generation Statistics Functions

  @doc """
  Returns the timestamp when sitemap was last generated.

  Returns ISO8601 timestamp string or nil if never generated.

  ## Examples

      iex> PhoenixKit.Sitemap.get_last_generated()
      "2025-12-02T10:30:00Z"
  """
  @spec get_last_generated() :: String.t() | nil
  def get_last_generated do
    settings_call(:get_setting_cached, [@last_generated_key, nil])
  end

  @doc """
  Returns the number of URLs in the current sitemap.

  ## Examples

      iex> PhoenixKit.Sitemap.get_url_count()
      150
  """
  @spec get_url_count() :: integer()
  def get_url_count do
    settings_call(:get_integer_setting, [@url_count_key, 0])
  end

  @doc """
  Updates generation statistics after sitemap creation.

  Accepts a map with :url_count and optionally :timestamp.

  ## Examples

      iex> PhoenixKit.Sitemap.update_generation_stats(%{url_count: 150})
      {:ok, %{last_generated: "2025-12-02T10:30:00Z", url_count: 150}}

      iex> PhoenixKit.Sitemap.update_generation_stats(%{
      ...>   url_count: 150,
      ...>   timestamp: ~U[2025-12-02 10:30:00Z]
      ...> })
      {:ok, %{last_generated: "2025-12-02T10:30:00Z", url_count: 150}}
  """
  @spec update_generation_stats(map()) :: {:ok, map()} | {:error, any()}
  def update_generation_stats(stats) when is_map(stats) do
    url_count = Map.get(stats, :url_count, 0)
    timestamp = Map.get(stats, :timestamp, DateTime.utc_now())

    # Convert timestamp to ISO8601 string
    timestamp_str =
      case timestamp do
        %DateTime{} -> DateTime.to_iso8601(timestamp)
        string when is_binary(string) -> string
        _ -> DateTime.to_iso8601(DateTime.utc_now())
      end

    # Update both settings
    with {:ok, _} <- settings_call(:update_setting, [@last_generated_key, timestamp_str]),
         {:ok, _} <-
           settings_call(:update_setting, [@url_count_key, Integer.to_string(url_count)]) do
      {:ok, %{last_generated: timestamp_str, url_count: url_count}}
    else
      error -> error
    end
  end

  @doc """
  Clears generation statistics.

  Called when cache is invalidated to indicate the sitemap file no longer exists.
  Next request will regenerate the sitemap.

  ## Examples

      iex> PhoenixKit.Sitemap.clear_generation_stats()
      :ok
  """
  @spec clear_generation_stats() :: :ok
  def clear_generation_stats do
    settings_call(:update_setting, [@last_generated_key, nil])
    settings_call(:update_setting, [@url_count_key, "0"])
    :ok
  end

  ## Regeneration Functions

  @doc """
  Triggers sitemap regeneration.

  This function will be called by the Generator module to perform the actual
  sitemap generation. Pass optional scope for audit logging.

  ## Examples

      iex> PhoenixKit.Sitemap.regenerate(scope)
      {:ok, %{xml: xml_content, html: html_content, url_count: 150}}
  """
  @spec regenerate(any()) :: {:ok, map()} | {:error, any()}
  def regenerate(scope \\ nil) do
    if enabled?() do
      # This will be implemented by PhoenixKit.Sitemap.Generator
      # For now, return a placeholder
      Logger.info("Sitemap regeneration triggered by #{inspect(scope)}")
      {:ok, %{status: :pending, message: "Generator not yet implemented"}}
    else
      {:error, :sitemap_disabled}
    end
  end

  ## Cache Functions

  @doc """
  Returns the cached XML sitemap content.

  Returns nil if no cached sitemap exists.

  ## Examples

      iex> PhoenixKit.Sitemap.get_cached_xml()
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\\n<urlset>...</urlset>"
  """
  @spec get_cached_xml() :: String.t() | nil
  def get_cached_xml do
    settings_call(:get_setting_cached, [@cache_xml_key, nil])
  end

  @doc """
  Returns the cached HTML sitemap content.

  Returns nil if no cached sitemap exists.

  ## Examples

      iex> PhoenixKit.Sitemap.get_cached_html()
      "<html>...</html>"
  """
  @spec get_cached_html() :: String.t() | nil
  def get_cached_html do
    settings_call(:get_setting_cached, [@cache_html_key, nil])
  end

  @doc """
  Stores XML sitemap content in cache.

  ## Examples

      iex> PhoenixKit.Sitemap.cache_xml(xml_content)
      {:ok, %PhoenixKit.Settings.Setting{}}
  """
  @spec cache_xml(String.t()) :: {:ok, any()} | {:error, any()}
  def cache_xml(xml_content) when is_binary(xml_content) do
    settings_call(:update_setting, [@cache_xml_key, xml_content])
  end

  @doc """
  Stores HTML sitemap content in cache.

  ## Examples

      iex> PhoenixKit.Sitemap.cache_html(html_content)
      {:ok, %PhoenixKit.Settings.Setting{}}
  """
  @spec cache_html(String.t()) :: {:ok, any()} | {:error, any()}
  def cache_html(html_content) when is_binary(html_content) do
    settings_call(:update_setting, [@cache_html_key, html_content])
  end

  @doc """
  Invalidates sitemap cache.

  This should be called after regenerating sitemaps to ensure
  fresh content is served.

  ## Examples

      iex> PhoenixKit.Sitemap.invalidate_cache()
      :ok
  """
  @spec invalidate_cache() :: :ok
  def invalidate_cache do
    cache_keys = [@cache_xml_key, @cache_html_key]

    # Invalidate all cache keys
    Enum.each(cache_keys, fn key ->
      PhoenixKit.Cache.invalidate(:settings, key)
    end)

    :ok
  rescue
    error ->
      Logger.warning("Failed to invalidate sitemap cache: #{inspect(error)}")
      :ok
  end

  ## Private Helper Functions

  # Get the configured Settings module (allows testing with mock)
  defp settings_module do
    PhoenixKit.Config.get(:sitemap_settings_module, PhoenixKit.Settings)
  end

  # Call a function on the Settings module with arguments
  defp settings_call(fun, args) do
    apply(settings_module(), fun, args)
  end
end
