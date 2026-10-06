defmodule PhoenixKit.Modules.Sitemap do
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
  - `site_url` - Base URL for sitemap entries (string; falls back to the host endpoint's URL, see `get_base_url/0`)
  - `sitemap_html_enabled` - Enable HTML sitemap (boolean)
  - `sitemap_html_style` - HTML display style (hierarchical/flat/grouped)
  - `sitemap_default_changefreq` - Default change frequency (string)
  - `sitemap_default_priority` - Default URL priority (string)
  - `sitemap_last_generated` - Last generation timestamp (ISO8601)
  - `sitemap_url_count` - Number of URLs in sitemap (integer)

  ## Usage Examples

      # Regenerate every sitemap file, inline — this walks every source and
      # language, so do not call it from a request. From a controller or
      # LiveView use the queued path instead:
      PhoenixKit.Modules.Sitemap.Generator.invalidate_and_regenerate()

      # Inline, for a mix task or a worker that wants the result:
      {:ok, %{total_urls: _}} = PhoenixKit.Modules.Sitemap.regenerate(scope)

      # Get configuration
      config = PhoenixKit.Modules.Sitemap.get_config()
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
      url = PhoenixKit.Modules.Sitemap.build_url("/about")
      # => "https://example.com/about"

      # Get cached sitemaps
      xml = PhoenixKit.Modules.Sitemap.get_cached_xml()
      html = PhoenixKit.Modules.Sitemap.get_cached_html()

      # Invalidate cache after regeneration
      PhoenixKit.Modules.Sitemap.invalidate_cache()
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Modules.Sitemap.Generator
  alias PhoenixKit.Modules.Sitemap.SchedulerWorker
  alias PhoenixKit.Utils.Date, as: UtilsDate

  require Logger

  @enabled_key "sitemap_enabled"

  # Setting keys
  @schedule_enabled_key "sitemap_schedule_enabled"
  @schedule_interval_key "sitemap_schedule_interval_hours"
  @include_entities_key "sitemap_include_entities"
  @include_blogs_key "sitemap_include_blogs"
  @include_static_key "sitemap_include_static"
  @include_shop_key "sitemap_include_shop"
  @router_discovery_key "sitemap_router_discovery_enabled"
  @html_enabled_key "sitemap_html_enabled"
  @html_style_key "sitemap_html_style"
  @default_changefreq_key "sitemap_default_changefreq"
  @default_priority_key "sitemap_default_priority"
  @last_generated_key "sitemap_last_generated"
  @url_count_key "sitemap_url_count"

  # Generation stats are machine stamps: written without the settings history.
  @no_history [history: false]

  # Cache keys
  @cache_xml_key "sitemap_xml_cache"
  @cache_html_key "sitemap_html_cache"

  # New setting keys for sitemapindex architecture
  @include_registration_key "sitemap_include_registration"
  @publishing_split_key "sitemap_publishing_split_by_group"
  @module_stats_key "sitemap_module_stats"
  # Default values
  @default_schedule_enabled true
  @default_schedule_interval_hours 24
  @default_include_entities true
  @default_include_blogs true
  @default_include_static true
  @default_include_shop true
  @default_router_discovery true
  @default_html_enabled true
  @default_html_style "hierarchical"
  @default_changefreq "weekly"
  @default_priority "0.5"

  ## System Control Functions

  @impl PhoenixKit.Module
  @doc """
  Returns true when the sitemap module is enabled.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.enabled?()
      false

      iex> PhoenixKit.Modules.Sitemap.enable_system()
      iex> PhoenixKit.Modules.Sitemap.enabled?()
      true
  """
  @spec enabled?() :: boolean()
  def enabled? do
    settings_call(:get_boolean_setting, [@enabled_key, false])
  end

  @impl PhoenixKit.Module
  @doc """
  Enables the sitemap module.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.enable_system()
      {:ok, %PhoenixKit.Settings.Setting{}}
  """
  @spec enable_system() :: {:ok, any()} | {:error, any()}
  def enable_system do
    settings_call(:update_boolean_setting, [@enabled_key, true])
  end

  @impl PhoenixKit.Module
  @doc """
  Disables the sitemap module.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.disable_system()
      {:ok, %PhoenixKit.Settings.Setting{}}
  """
  @spec disable_system() :: {:ok, any()} | {:error, any()}
  def disable_system do
    alias PhoenixKit.Modules.Sitemap.SchedulerWorker

    result = settings_call(:update_boolean_setting, [@enabled_key, false])

    case result do
      {:ok, _} = success ->
        # Cancel any scheduled sitemap generation jobs
        SchedulerWorker.cancel_scheduled()
        success

      error ->
        error
    end
  end

  @doc """
  Returns true when sitemap is in flat mode (single `<urlset>`).

  Flat mode is active when Router Discovery is enabled — all URLs from all
  sources are merged into a single sitemap.xml. When Router Discovery is off,
  index mode is used with per-module sitemap files.
  """
  @spec flat_mode?() :: boolean()
  def flat_mode?, do: router_discovery_enabled?()

  ## Configuration Functions

  @impl PhoenixKit.Module
  @doc """
  Returns the current sitemap configuration as a map.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.get_config()
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
      include_shop: include_shop?(),
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

  The `site_url` setting when it is set; otherwise the URL of the host
  application's running endpoint (the same fallback email links use, but
  stricter — see `endpoint_base_url/0`); `""` when neither gives a public
  absolute `http(s)` URL, which the controller answers with 503 rather than
  publishing a sitemap of relative, placeholder or `localhost` links.

  The endpoint fallback matters because the generated sitemap file lives
  inside the dependency: upgrading PhoenixKit deletes it, the next request
  regenerates it, and a site that never set `site_url` used to lose its
  sitemap to a 503 right after the upgrade. Set `site_url` explicitly anyway
  when the endpoint's configured URL is not the public one (behind a proxy,
  for instance) — `mix phoenix_kit.doctor` reports when the fallback is in use.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.get_base_url()
      "https://example.com"
  """
  @spec get_base_url() :: String.t()
  def get_base_url do
    case settings_call(:get_setting_cached, ["site_url", ""]) do
      url when is_binary(url) and url != "" -> url
      _ -> endpoint_base_url()
    end
  end

  @doc """
  The host endpoint's URL, when it is running and configured with an absolute
  `http(s)` URL that can be the site's public address; `""` otherwise.

  Deliberately strict, because a sitemap is published to crawlers:

    * `PhoenixKit.Config.get_dynamic_base_url/0` ends in a static default
      (`localhost`) when there is no endpoint — right for a dev-mode email
      link, wrong here;
    * a placeholder host (`example.com` — phx.new's production default when
      `PHX_HOST` is unset — and the other RFC 2606 names) is nobody's address;
    * a local host (`localhost` — Phoenix's default when the endpoint sets no
      `url` — `127.0.0.1`, `::1`, a `.test` name) counts only on a development
      server, one whose endpoint runs a code reloader. Anywhere else it means
      the URL was never configured.
  """
  @spec endpoint_base_url() :: String.t()
  def endpoint_base_url do
    with {:ok, url} when is_binary(url) <- PhoenixKit.Config.get_parent_endpoint_url(),
         {:ok, endpoint} <- PhoenixKit.Config.get_parent_endpoint() do
      public_base_url(url, dev_server?(endpoint))
    else
      _ -> ""
    end
  end

  @doc false
  # Pure: `url` without its trailing slash, or "" when it cannot be the
  # site's public address (see `endpoint_base_url/0`).
  @spec public_base_url(String.t(), boolean()) :: String.t()
  def public_base_url(url, dev_server?) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        cond do
          placeholder_host?(host) -> ""
          local_host?(host) and not dev_server? -> ""
          true -> String.trim_trailing(url, "/")
        end

      _ ->
        ""
    end
  end

  @doc false
  # A host that only this machine or a local development setup can reach:
  # loopback names and addresses (IPv4-mapped IPv6 forms included), the
  # unspecified address, and RFC 6761 `.test` names.
  @spec local_host?(String.t()) :: boolean()
  def local_host?(host) do
    host = normalize_host(host)

    host in ["localhost", "test"] or String.ends_with?(host, [".localhost", ".test"]) or
      local_address?(:inet.parse_address(String.to_charlist(host)))
  end

  defp local_address?({:ok, {127, _, _, _}}), do: true
  defp local_address?({:ok, {0, _, _, _}}), do: true
  defp local_address?({:ok, {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  defp local_address?({:ok, {0, 0, 0, 0, 0, 0, 0, 0}}), do: true

  # `::ffff:a.b.c.d` (IPv4-mapped) and `::a.b.c.d` (IPv4-compatible) name the
  # IPv4 address in their last 32 bits.
  defp local_address?({:ok, {0, 0, 0, 0, 0, prefix, hi, lo}}) when prefix in [0, 0xFFFF],
    do: local_address?({:ok, {div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)}})

  defp local_address?(_), do: false

  @placeholder_domains ~w(example.com example.net example.org example invalid)

  defp placeholder_host?(host) do
    host = normalize_host(host)

    Enum.any?(@placeholder_domains, fn domain ->
      host == domain or String.ends_with?(host, "." <> domain)
    end)
  end

  # `localhost.` and `www.example.com.` are the same names written fully
  # qualified.
  defp normalize_host(host), do: host |> String.downcase() |> String.trim_trailing(".")

  defp dev_server?(endpoint) do
    function_exported?(endpoint, :config, 1) and endpoint.config(:code_reloader) == true
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  Builds a full URL from a relative path using the configured base URL.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.build_url("/about")
      "https://example.com/about"

      iex> PhoenixKit.Modules.Sitemap.build_url("contact")
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

      iex> PhoenixKit.Modules.Sitemap.schedule_enabled?()
      true
  """
  @spec schedule_enabled?() :: boolean()
  def schedule_enabled? do
    settings_call(:get_boolean_setting, [@schedule_enabled_key, @default_schedule_enabled])
  end

  @doc """
  Returns the scheduled generation interval in hours.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.get_schedule_interval_hours()
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

      iex> PhoenixKit.Modules.Sitemap.include_entities?()
      true
  """
  @spec include_entities?() :: boolean()
  def include_entities? do
    settings_call(:get_boolean_setting, [@include_entities_key, @default_include_entities])
  end

  @doc """
  Returns true if blog posts should be included in sitemap.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.include_blogs?()
      true
  """
  @spec include_blogs?() :: boolean()
  def include_blogs? do
    settings_call(:get_boolean_setting, [@include_blogs_key, @default_include_blogs])
  end

  @doc """
  Returns true if static pages should be included in sitemap.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.include_static?()
      true
  """
  @spec include_static?() :: boolean()
  def include_static? do
    settings_call(:get_boolean_setting, [@include_static_key, @default_include_static])
  end

  @doc """
  Returns true if shop pages should be included in sitemap.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.include_shop?()
      true
  """
  @spec include_shop?() :: boolean()
  def include_shop? do
    settings_call(:get_boolean_setting, [@include_shop_key, @default_include_shop])
  end

  @doc """
  Returns true if router discovery should be enabled.

  Router discovery automatically scans the parent application's router
  for GET routes and includes them in the sitemap.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.router_discovery_enabled?()
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

      iex> PhoenixKit.Modules.Sitemap.html_enabled?()
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

      iex> PhoenixKit.Modules.Sitemap.get_html_style()
      "hierarchical"
  """
  @spec get_html_style() :: String.t()
  def get_html_style do
    settings_call(:get_setting_cached, [@html_style_key, @default_html_style])
  end

  @doc """
  Returns the default change frequency for sitemap URLs.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.get_default_changefreq()
      "weekly"
  """
  @spec get_default_changefreq() :: String.t()
  def get_default_changefreq do
    settings_call(:get_setting_cached, [@default_changefreq_key, @default_changefreq])
  end

  @doc """
  Returns the default priority for sitemap URLs.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.get_default_priority()
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

      iex> PhoenixKit.Modules.Sitemap.get_last_generated()
      "2025-12-02T10:30:00Z"
  """
  @spec get_last_generated() :: String.t() | nil
  def get_last_generated do
    settings_call(:get_setting_cached, [@last_generated_key, nil])
  end

  @doc """
  Returns the number of URLs in the current sitemap.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.get_url_count()
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

      iex> PhoenixKit.Modules.Sitemap.update_generation_stats(%{url_count: 150})
      {:ok, %{last_generated: "2025-12-02T10:30:00Z", url_count: 150}}

      iex> PhoenixKit.Modules.Sitemap.update_generation_stats(%{
      ...>   url_count: 150,
      ...>   timestamp: ~U[2025-12-02 10:30:00Z]
      ...> })
      {:ok, %{last_generated: "2025-12-02T10:30:00Z", url_count: 150}}
  """
  @spec update_generation_stats(map()) :: {:ok, map()} | {:error, any()}
  def update_generation_stats(stats) when is_map(stats) do
    url_count = Map.get(stats, :url_count, 0)
    timestamp = Map.get(stats, :timestamp, UtilsDate.utc_now())

    # Convert timestamp to ISO8601 string
    timestamp_str =
      case timestamp do
        %DateTime{} -> DateTime.to_iso8601(timestamp)
        string when is_binary(string) -> string
        _ -> DateTime.to_iso8601(UtilsDate.utc_now())
      end

    # Update both settings. Machine stamps, rewritten on every generation:
    # no settings history (see `PhoenixKit.Settings.History`, "Machine stamps").
    with {:ok, _} <-
           settings_call(:update_setting, [@last_generated_key, timestamp_str, @no_history]),
         {:ok, _} <-
           settings_call(:update_setting, [
             @url_count_key,
             Integer.to_string(url_count),
             @no_history
           ]) do
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

      iex> PhoenixKit.Modules.Sitemap.clear_generation_stats()
      :ok
  """
  @spec clear_generation_stats() :: :ok
  def clear_generation_stats do
    settings_call(:update_setting, [@last_generated_key, nil, @no_history])
    settings_call(:update_setting, [@url_count_key, "0", @no_history])
    :ok
  end

  ## Regeneration Functions

  @doc """
  Regenerates every sitemap file and returns the generator's result.

  Runs `Generator.generate_all/1` against the configured base URL. Pass an
  optional scope for audit logging. Use `Generator.invalidate_and_regenerate/0`
  instead when the work should be queued rather than done in the caller.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.regenerate(scope)
      {:ok, %{index_xml: "<?xml ...", modules: [...], total_urls: 150}}
  """
  @spec regenerate(any()) :: {:ok, map()} | {:error, any()}
  def regenerate(scope \\ nil) do
    base_url = get_base_url()

    cond do
      not enabled?() ->
        {:error, :sitemap_disabled}

      # `get_base_url/0` falls back to "", which `Generator.generate_all/1`
      # accepts (it only rejects nil) and turns into host-less `<loc>`s. The
      # scheduler guards this before regenerating; so does this entry point.
      base_url == "" ->
        {:error, :base_url_not_configured}

      true ->
        Logger.info("Sitemap regeneration triggered by #{inspect(scope)}")
        Generator.generate_all(base_url: base_url)
    end
  end

  ## Cache Functions

  @doc """
  Returns the cached XML sitemap content.

  Returns nil if no cached sitemap exists.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.get_cached_xml()
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

      iex> PhoenixKit.Modules.Sitemap.get_cached_html()
      "<html>...</html>"
  """
  @spec get_cached_html() :: String.t() | nil
  def get_cached_html do
    settings_call(:get_setting_cached, [@cache_html_key, nil])
  end

  @doc """
  Stores XML sitemap content in cache.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.cache_xml(xml_content)
      {:ok, %PhoenixKit.Settings.Setting{}}
  """
  @spec cache_xml(String.t()) :: {:ok, any()} | {:error, any()}
  def cache_xml(xml_content) when is_binary(xml_content) do
    settings_call(:update_setting, [@cache_xml_key, xml_content])
  end

  @doc """
  Stores HTML sitemap content in cache.

  ## Examples

      iex> PhoenixKit.Modules.Sitemap.cache_html(html_content)
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

      iex> PhoenixKit.Modules.Sitemap.invalidate_cache()
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

  ## Registration / Publishing Toggle Functions

  @doc """
  Returns true if the registration page should be included in the sitemap.

  Default: false (registration pages are excluded by default).
  """
  @spec include_registration?() :: boolean()
  def include_registration? do
    settings_call(:get_boolean_setting, [@include_registration_key, false])
  end

  @doc """
  Alias for `include_blogs?/0` - reads the same `sitemap_include_blogs` key.
  """
  @spec include_publishing?() :: boolean()
  def include_publishing?, do: include_blogs?()

  @doc """
  Returns true if publishing posts should be split into per-blog sitemap files.

  Default: false (all publishing posts in a single file).
  """
  @spec publishing_split_by_group?() :: boolean()
  def publishing_split_by_group? do
    settings_call(:get_boolean_setting, [@publishing_split_key, false])
  end

  ## Module Stats Functions

  @doc """
  Returns per-module generation stats from Settings.
  """
  @spec get_module_stats() :: [map()]
  def get_module_stats do
    # Use get_json_setting (no cache) — this is only called when loading the settings page,
    # and the cached variant has ETS table naming issues with json settings
    case settings_call(:get_json_setting, [@module_stats_key]) do
      nil ->
        []

      %{"modules" => stats} when is_list(stats) ->
        stats

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc """
  Updates per-module generation stats in Settings.
  """
  @spec update_module_stats([map()]) :: {:ok, any()} | {:error, any()}
  def update_module_stats(module_infos) when is_list(module_infos) do
    stats =
      Enum.map(module_infos, fn info ->
        %{
          "filename" => info.filename,
          "url_count" => info.url_count,
          "last_generated" => UtilsDate.utc_now() |> DateTime.to_iso8601()
        }
      end)

    # Store as JSON map in value_json (jsonb) - wraps list in map since value_json is :map type.
    # Carries a timestamp per module, so every generation changes it: no settings history.
    settings_call(:update_json_setting, [@module_stats_key, %{"modules" => stats}, @no_history])
  end

  # ============================================================================
  # Module Behaviour Callbacks
  # ============================================================================

  @impl PhoenixKit.Module
  def children do
    [{Task, fn -> SchedulerWorker.ensure_scheduled() end}]
  end

  @impl PhoenixKit.Module
  def module_key, do: "sitemap"

  @impl PhoenixKit.Module
  def module_name, do: "Sitemap"

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "sitemap",
      label: "Sitemap",
      icon: "hero-map",
      description: "XML sitemap generation and search engine indexing"
    }
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_sitemap,
        label: "Sitemap",
        icon: "hero-map",
        path: "sitemap",
        priority: 931,
        level: :admin,
        parent: :admin_settings,
        permission: "sitemap",
        gettext_backend: PhoenixKitWeb.Gettext
      )
    ]
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
