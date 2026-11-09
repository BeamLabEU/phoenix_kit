defmodule PhoenixKit.Modules.Sitemap.Web.Settings do
  @moduledoc """
  LiveView for sitemap configuration and management.

  Provides admin interface for:
  - Enabling/disabling sitemap module
  - Per-module sitemap cards with stats and regeneration
  - Auth pages configuration (login excluded, registration toggle)
  - Publishing split by group toggle
  - XSL styling configuration
  - Scheduled generation
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKit.Modules.Sitemap.FileStorage
  alias PhoenixKit.Modules.Sitemap.Generator
  alias PhoenixKit.Modules.Sitemap.SchedulerWorker
  alias PhoenixKit.Modules.Sitemap.Sources.RouterDiscovery
  alias PhoenixKit.Modules.Sitemap.Sources.Source
  alias PhoenixKit.Modules.Sitemap.Sources.Static
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Json
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Settings.UrlTabs

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      PubSubManager.subscribe("sitemap:updates")
      PubSubManager.subscribe("sitemap:settings")
    end

    locale = params["locale"] || Routes.get_default_admin_locale()
    project_title = Settings.get_project_title()
    site_url = Settings.get_setting("site_url", "")
    config = Sitemap.get_config()
    sitemap_version = get_sitemap_version(config)
    module_stats = Sitemap.get_module_stats()
    module_files = FileStorage.list_module_files()

    socket =
      socket
      |> assign(:page_title, gettext("Sitemap"))
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/settings/sitemap", locale: locale))
      |> assign(:config, config)
      |> assign(:site_url, site_url)
      |> assign(:generating, false)
      |> assign(:preview_mode, nil)
      |> assign(:preview_content, nil)
      |> assign(:show_preview, false)
      |> assign(:sitemap_version, sitemap_version)
      |> assign(:module_stats, module_stats)
      |> assign(:module_files, module_files)
      |> assign(:include_registration, Sitemap.include_registration?())
      |> assign(:publishing_split_by_group, Sitemap.publishing_split_by_group?())
      |> assign(:module_enabled, get_module_enabled_status())
      |> assign(:exclude_patterns_text, exclude_patterns_text())
      |> assign(:exclude_patterns_defaults_text, exclude_patterns_defaults_text())
      |> assign(:exclude_patterns_error, nil)
      |> assign(:protected_pipelines_text, protected_pipelines_text())
      |> assign(:protected_pipelines_defaults_text, protected_pipelines_defaults_text())
      |> assign(:protected_pipelines_error, nil)
      |> assign(:custom_urls_text, custom_urls_text())
      |> assign(:custom_urls_error, nil)
      |> assign(:static_routes_text, static_routes_text())
      |> assign(:static_routes_error, nil)
      |> assign(:extension_sources, build_extension_sources(Generator.get_sources()))

    {:ok, socket}
  end

  # The tab lives in the URL (`?tab=configuration`); see `UrlTabs`.
  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, assign(socket, :active_tab, UrlTabs.active(params, tabs()))}
  end

  defp tabs do
    [
      %{id: "sources", label: gettext("Sources"), icon: "hero-circle-stack"},
      %{id: "configuration", label: gettext("Configuration"), icon: "hero-cog-6-tooth"},
      %{id: "actions", label: gettext("Quick Actions"), icon: "hero-bolt"},
      %{id: "advanced", label: gettext("Advanced"), icon: "hero-wrench-screwdriver"}
    ]
  end

  @impl true
  def handle_event("toggle_sitemap", _params, socket) do
    new_enabled = !socket.assigns.config.enabled

    result =
      if new_enabled do
        Sitemap.enable_system()
      else
        Sitemap.disable_system()
      end

    case result do
      {:ok, _} ->
        config = Sitemap.get_config()

        message =
          if new_enabled, do: gettext("Sitemap enabled"), else: gettext("Sitemap disabled")

        new_version = UtilsDate.utc_now() |> DateTime.to_unix()
        broadcast_settings_change(:sitemap_toggled, %{enabled: new_enabled, version: new_version})

        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:sitemap_version, new_version)
         |> put_flash(:info, message)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update sitemap status"))}
    end
  end

  # Router Discovery toggle = mode switch (flat vs index)
  @impl true
  def handle_event("toggle_source", %{"source" => "router_discovery"}, socket) do
    key = "sitemap_router_discovery_enabled"
    current = Settings.get_boolean_setting(key, false)
    new_value = !current

    case Settings.update_boolean_setting(key, new_value) do
      {:ok, _} ->
        Generator.invalidate_cache()

        # Transitioning to flat mode: clean up per-module files
        if new_value, do: FileStorage.delete_all_modules()

        config = Sitemap.get_config()
        new_version = UtilsDate.utc_now() |> DateTime.to_unix()

        broadcast_settings_change(:source_changed, %{
          source: "router_discovery",
          version: new_version
        })

        module_stats = if new_value, do: [], else: Sitemap.get_module_stats()
        module_files = if new_value, do: [], else: FileStorage.list_module_files()

        message =
          if new_value,
            do: gettext("Router Discovery enabled — flat sitemap mode active"),
            else: gettext("Router Discovery disabled — per-module sitemap mode")

        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:sitemap_version, new_version)
         |> assign(:module_stats, module_stats)
         |> assign(:module_files, module_files)
         |> put_flash(:info, message)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update source setting"))}
    end
  end

  @impl true
  def handle_event("toggle_source", %{"source" => source}, socket) do
    key =
      if source == "router_discovery" do
        "sitemap_router_discovery_enabled"
      else
        "sitemap_include_#{source}"
      end

    current = Settings.get_boolean_setting(key, true)

    case Settings.update_boolean_setting(key, !current) do
      {:ok, _} ->
        Generator.invalidate_cache()
        config = Sitemap.get_config()
        new_version = UtilsDate.utc_now() |> DateTime.to_unix()
        broadcast_settings_change(:source_changed, %{source: source, version: new_version})

        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:sitemap_version, new_version)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update source setting"))}
    end
  end

  @impl true
  def handle_event("toggle_registration", _params, socket) do
    new_value = !socket.assigns.include_registration

    case Settings.update_boolean_setting("sitemap_include_registration", new_value) do
      {:ok, _} ->
        Generator.invalidate_cache()
        new_version = UtilsDate.utc_now() |> DateTime.to_unix()

        {:noreply,
         socket
         |> assign(:include_registration, new_value)
         |> assign(:sitemap_version, new_version)
         |> put_flash(
           :info,
           if(new_value,
             do: gettext("Registration page included"),
             else: gettext("Registration page excluded")
           )
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update registration setting"))}
    end
  end

  @impl true
  def handle_event("toggle_publishing_split", _params, socket) do
    new_value = !socket.assigns.publishing_split_by_group

    case Settings.update_boolean_setting("sitemap_publishing_split_by_group", new_value) do
      {:ok, _} ->
        Generator.invalidate_cache()
        new_version = UtilsDate.utc_now() |> DateTime.to_unix()

        {:noreply,
         socket
         |> assign(:publishing_split_by_group, new_value)
         |> assign(:sitemap_version, new_version)
         |> put_flash(
           :info,
           if(new_value,
             do: gettext("Publishing split by blog"),
             else: gettext("Publishing combined into one file")
           )
         )}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, gettext("Failed to update publishing split setting"))}
    end
  end

  @impl true
  def handle_event("toggle_html", _params, socket) do
    current = socket.assigns.config.html_enabled

    case Settings.update_boolean_setting("sitemap_html_enabled", !current) do
      {:ok, _} ->
        Generator.invalidate_cache()
        config = Sitemap.get_config()
        new_version = UtilsDate.utc_now() |> DateTime.to_unix()
        broadcast_settings_change(:html_changed, %{enabled: !current, version: new_version})

        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:sitemap_version, new_version)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update HTML sitemap setting"))}
    end
  end

  @impl true
  def handle_event("toggle_schedule", _params, socket) do
    current = socket.assigns.config.schedule_enabled

    case Settings.update_boolean_setting("sitemap_schedule_enabled", !current) do
      {:ok, _} ->
        if current do
          SchedulerWorker.cancel_scheduled()
        else
          SchedulerWorker.schedule()
        end

        config = Sitemap.get_config()
        new_version = UtilsDate.utc_now() |> DateTime.to_unix()
        broadcast_settings_change(:schedule_changed, %{enabled: !current, version: new_version})

        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:sitemap_version, new_version)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update schedule setting"))}
    end
  end

  @impl true
  def handle_event("update_style", %{"style" => style}, socket) do
    case Settings.update_setting("sitemap_html_style", style) do
      {:ok, _} ->
        Generator.invalidate_cache()
        config = Sitemap.get_config()
        new_version = UtilsDate.utc_now() |> DateTime.to_unix()
        broadcast_settings_change(:style_changed, %{style: style, version: new_version})

        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:sitemap_version, new_version)
         |> put_flash(:info, gettext("Style updated. Sitemap will use new style on next load."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update style"))}
    end
  end

  @impl true
  def handle_event("update_interval", %{"interval" => interval_str}, socket) do
    case Integer.parse(interval_str) do
      {interval, _} when interval > 0 ->
        case Settings.update_setting("sitemap_schedule_interval_hours", interval_str) do
          {:ok, _} ->
            config = Sitemap.get_config()
            new_version = UtilsDate.utc_now() |> DateTime.to_unix()

            broadcast_settings_change(:interval_changed, %{
              interval: interval,
              version: new_version
            })

            {:noreply,
             socket
             |> assign(:config, config)
             |> assign(:sitemap_version, new_version)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update interval"))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Invalid interval value"))}
    end
  end

  @impl true
  def handle_event("regenerate", _params, socket) do
    base_url = Sitemap.get_base_url()

    if base_url != "" do
      case SchedulerWorker.regenerate_now() do
        {:ok, _job} ->
          {:noreply,
           socket
           |> assign(:generating, true)
           |> put_flash(
             :info,
             gettext("Sitemap generation queued. Stats will update automatically.")
           )}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             gettext("Failed to queue generation: %{reason}", reason: inspect(reason))
           )}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("Please configure Base URL before generating"))}
    end
  end

  @impl true
  def handle_event("preview", %{"type" => _type}, socket) do
    base_url = Sitemap.get_base_url()
    xsl_style = get_xsl_style(socket.assigns.config.html_style)

    opts = [
      base_url: base_url,
      xsl_style: xsl_style,
      xsl_enabled: socket.assigns.config.html_enabled
    ]

    content =
      case Generator.generate_all(opts) do
        {:ok, %{index_xml: xml}} -> xml
        _ -> gettext("Error generating XML preview")
      end

    {:noreply,
     socket
     |> assign(:preview_mode, "xml")
     |> assign(:preview_content, content)
     |> assign(:show_preview, true)}
  end

  @impl true
  def handle_event("close_preview", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_preview, false)
     |> assign(:preview_mode, nil)
     |> assign(:preview_content, nil)}
  end

  @impl true
  def handle_event("invalidate_cache", _params, socket) do
    case Generator.invalidate_and_regenerate() do
      {:ok, _job} ->
        new_version = UtilsDate.utc_now() |> DateTime.to_unix()

        {:noreply,
         socket
         |> assign(:sitemap_version, new_version)
         |> assign(:generating, true)
         |> assign(:module_stats, [])
         |> assign(:module_files, [])
         |> put_flash(:info, gettext("All sitemaps cleared. Regeneration started..."))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to regenerate: %{reason}", reason: inspect(reason))
         )}
    end
  end

  @impl true
  def handle_event("save_exclude_patterns", %{"patterns" => text}, socket) do
    patterns = parse_lines(text)

    case RouterDiscovery.invalid_patterns(patterns) do
      [] ->
        case Settings.update_setting(
               "sitemap_router_discovery_exclude_patterns",
               JSON.encode!(patterns)
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:exclude_patterns_text, Enum.join(patterns, "\n"))
             |> assign(:exclude_patterns_error, nil)
             |> bump_and_broadcast("router_discovery_exclude_patterns")
             |> put_flash(:info, gettext("Exclude patterns updated"))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update exclude patterns"))}
        end

      invalid ->
        {:noreply,
         socket
         |> assign(:exclude_patterns_text, text)
         |> assign(
           :exclude_patterns_error,
           gettext("Invalid regex pattern(s), not saved: %{patterns}",
             patterns: Enum.join(invalid, ", ")
           )
         )}
    end
  end

  @impl true
  def handle_event("save_protected_pipelines", %{"pipelines" => text}, socket) do
    names = parse_lines(text)

    case invalid_pipeline_names(names) do
      [] ->
        case Settings.update_setting("sitemap_protected_pipelines", JSON.encode!(names)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:protected_pipelines_text, Enum.join(names, "\n"))
             |> assign(:protected_pipelines_error, nil)
             |> bump_and_broadcast("protected_pipelines")
             |> put_flash(:info, gettext("Protected pipelines updated"))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update protected pipelines"))}
        end

      invalid ->
        {:noreply,
         socket
         |> assign(:protected_pipelines_text, text)
         |> assign(
           :protected_pipelines_error,
           gettext(
             "Invalid pipeline name(s) — use letters, digits and underscores only, not saved: %{names}",
             names: Enum.join(invalid, ", ")
           )
         )}
    end
  end

  @impl true
  def handle_event("save_custom_urls", %{"json" => text}, socket) do
    case decode_object_list(text) do
      {:ok, list} ->
        case Settings.update_setting("sitemap_custom_urls", JSON.encode!(list)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:custom_urls_text, Json.encode_pretty!(list))
             |> assign(:custom_urls_error, nil)
             |> bump_and_broadcast("custom_urls")
             |> put_flash(:info, gettext("Custom URLs updated"))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update custom URLs"))}
        end

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:custom_urls_text, text)
         |> assign(:custom_urls_error, message)}
    end
  end

  @impl true
  def handle_event("save_static_routes", %{"json" => text}, socket) do
    case decode_object_list(text) do
      {:ok, list} ->
        case Settings.update_setting("sitemap_static_routes", JSON.encode!(list)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:static_routes_text, Json.encode_pretty!(list))
             |> assign(:static_routes_error, nil)
             |> bump_and_broadcast("static_routes")
             |> put_flash(:info, gettext("Static routes updated"))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update static routes"))}
        end

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:static_routes_text, text)
         |> assign(:static_routes_error, message)}
    end
  end

  @impl true
  def handle_event("toggle_extension_setting", %{"key" => key}, socket) do
    case find_extension_field(socket, key) do
      %{type: :boolean} = field ->
        # Read the current value through the rescue-protected helper (same as
        # the render path) so a source that declares a boolean field with a
        # non-boolean default can't crash the toggle: `get_boolean_setting/2`
        # guards on `is_boolean(default)` and would otherwise raise here.
        current = read_extension_field(field) == true

        case Settings.update_boolean_setting(key, !current) do
          {:ok, _} ->
            {:noreply, socket |> refresh_extension_sources() |> bump_and_broadcast(key)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update setting"))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Unknown setting"))}
    end
  end

  @impl true
  def handle_event("save_extension_setting", %{"key" => key, "value" => raw_value}, socket) do
    case find_extension_field(socket, key) do
      %{type: :integer} ->
        case Integer.parse(raw_value) do
          {int, _} -> {:noreply, save_extension_value(socket, key, Integer.to_string(int))}
          :error -> {:noreply, put_flash(socket, :error, gettext("Invalid number"))}
        end

      %{type: :string} ->
        {:noreply, save_extension_value(socket, key, raw_value)}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Unknown setting"))}
    end
  end

  # Handle PubSub message when sitemap generation completes
  @impl true
  def handle_info({:sitemap_generated, %{url_count: count}}, socket) do
    config = Sitemap.get_config()
    sitemap_version = get_sitemap_version(config)
    module_stats = Sitemap.get_module_stats()
    module_files = FileStorage.list_module_files()

    {:noreply,
     socket
     |> assign(:generating, false)
     |> assign(:config, config)
     |> assign(:sitemap_version, sitemap_version)
     |> assign(:module_stats, module_stats)
     |> assign(:module_files, module_files)
     |> put_flash(:info, gettext("Sitemap generated successfully (%{count} URLs)", count: count))}
  end

  @impl true
  def handle_info({:sitemap_settings_changed, %{type: :style_changed, version: version}}, socket) do
    config = Sitemap.get_config()

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:sitemap_version, version)}
  end

  @impl true
  def handle_info({:sitemap_settings_changed, %{type: type}}, socket) do
    config = Sitemap.get_config()
    new_version = UtilsDate.utc_now() |> DateTime.to_unix()

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:sitemap_version, new_version)
     |> maybe_flash_for_setting(type)}
  end

  defp maybe_flash_for_setting(socket, :source_changed), do: socket
  defp maybe_flash_for_setting(socket, :schedule_changed), do: socket
  defp maybe_flash_for_setting(socket, :interval_changed), do: socket
  defp maybe_flash_for_setting(socket, :html_changed), do: socket
  defp maybe_flash_for_setting(socket, :sitemap_toggled), do: socket
  defp maybe_flash_for_setting(socket, _), do: socket

  defp broadcast_settings_change(type, data) do
    PubSubManager.broadcast(
      "sitemap:settings",
      {:sitemap_settings_changed, Map.put(data, :type, type)}
    )
  rescue
    _ -> :ok
  end

  # Maps old HTML style names to new XSL style names
  def get_xsl_style(html_style) do
    case html_style do
      "grouped" -> "table"
      "flat" -> "minimal"
      style when style in ["table", "minimal"] -> style
      _ -> "table"
    end
  end

  # Helper: find stats for a specific module filename
  def find_module_stat(module_stats, filename) do
    Enum.find(module_stats, fn stat ->
      stat["filename"] == filename or
        String.starts_with?(stat["filename"] || "", filename)
    end)
  end

  # Helper: count URLs for a source prefix across all module stats
  def count_source_urls(module_stats, source_prefix) do
    module_stats
    |> Enum.filter(fn stat ->
      String.starts_with?(stat["filename"] || "", source_prefix)
    end)
    |> Enum.reduce(0, fn stat, acc -> acc + (stat["url_count"] || 0) end)
  end

  # Helper: list files for a source prefix
  def source_files(module_files, source_prefix) do
    Enum.filter(module_files, &String.starts_with?(&1, source_prefix))
  end

  def format_timestamp(nil), do: gettext("Never")

  def format_timestamp(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} ->
        fake_user = %{user_timezone: nil}
        date_str = UtilsDate.format_date_with_user_timezone(dt, fake_user)
        time_str = UtilsDate.format_time_with_user_timezone(dt, fake_user)
        "#{date_str} #{time_str}"

      _ ->
        iso_string
    end
  end

  def format_timestamp(_), do: gettext("Never")

  # ============================================================================
  # Advanced settings (Router Discovery exclude patterns, protected pipelines,
  # custom URLs, static routes) — raw text <-> stored JSON conversions.
  # ============================================================================

  # Helper: read a JSON-encoded setting, falling back to `default_term` when
  # unset or invalid — mirrors the exact fallback each source module already
  # applies when it reads the same key, so what's shown here matches what's
  # actually in effect.
  defp decoded_setting(key, default_term) do
    case Settings.get_setting(key) do
      nil ->
        default_term

      json when is_binary(json) ->
        case JSON.decode(json) do
          {:ok, term} -> term
          _ -> default_term
        end
    end
  end

  # Only the host's OWN patterns. The built-in defaults are shown separately
  # and always apply, so prefilling the box with them would have the operator
  # saving a verbatim copy of a list core is supposed to keep updating.
  def exclude_patterns_text do
    decoded_setting("sitemap_router_discovery_exclude_patterns", [])
    |> Enum.join("\n")
  end

  def exclude_patterns_defaults_text do
    RouterDiscovery.default_exclude_patterns()
    |> Enum.join(", ")
  end

  def protected_pipelines_text do
    decoded_setting("sitemap_protected_pipelines", [])
    |> Enum.map_join("\n", &to_string/1)
  end

  def protected_pipelines_defaults_text do
    RouterDiscovery.default_protected_pipelines()
    |> Enum.map_join(", ", &to_string/1)
  end

  def custom_urls_text do
    decoded_setting("sitemap_custom_urls", [])
    |> Json.encode_pretty!()
  end

  def static_routes_text do
    decoded_setting("sitemap_static_routes", Static.default_static_routes())
    |> Json.encode_pretty!()
  end

  # Helper: textarea -> trimmed, non-blank lines (one setting value per line)
  defp parse_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @pipeline_name_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/

  # Pipeline names become atoms via String.to_atom/1 at collection time
  # (see RouterDiscovery.safe_to_atom/1) — restrict to identifier-safe
  # characters so a stray typo can't create an arbitrary atom.
  defp invalid_pipeline_names(names) do
    Enum.reject(names, &Regex.match?(@pipeline_name_pattern, &1))
  end

  # Helper: decode a JSON textarea value expected to hold an array of
  # objects (sitemap_custom_urls / sitemap_static_routes shape).
  defp decode_object_list(text) do
    case JSON.decode!(text) do
      list when is_list(list) ->
        if Enum.all?(list, &is_map/1) do
          {:ok, list}
        else
          {:error, gettext("Must be a JSON array of objects")}
        end

      _other ->
        {:error, gettext("Must be a JSON array of objects")}
    end
  rescue
    e in JSON.DecodeError -> {:error, gettext("Invalid JSON: %{message}", message: e.message)}
  end

  # Shared tail for every advanced/extension setting save: bust the generated
  # sitemap cache, bump the version so connected clients refresh, and notify
  # other open tabs — the same three steps every other handler in this module
  # performs inline after a successful Settings update.
  defp bump_and_broadcast(socket, source_key) do
    Generator.invalidate_cache()
    new_version = UtilsDate.utc_now() |> DateTime.to_unix()
    broadcast_settings_change(:source_changed, %{source: source_key, version: new_version})
    assign(socket, :sitemap_version, new_version)
  end

  # ============================================================================
  # Extension point: source-contributed settings
  # (PhoenixKit.Modules.Sitemap.Sources.Source.sitemap_settings_schema/0)
  # ============================================================================

  # Builds the render-ready list of `{source_module, fields}` for every
  # source that declares a settings schema, with each field's current value
  # attached. Public (not just used by `mount/3`) so it can be unit tested
  # directly against a mock source module, without needing a live DB-backed
  # LiveView mount.
  def build_extension_sources(source_modules) do
    source_modules
    |> Enum.map(fn mod -> {mod, safe_get_settings_schema(mod)} end)
    |> Enum.reject(fn {_mod, schema} -> schema == [] end)
    |> Enum.map(fn {mod, schema} ->
      {mod, Enum.map(schema, &Map.put(&1, :value, read_extension_field(&1)))}
    end)
  end

  # A source's schema is arbitrary data from another module — never let a
  # malformed one crash the settings page for every admin (mirrors the same
  # safety net `Source.safe_collect/2` applies to sitemap generation).
  defp safe_get_settings_schema(mod) do
    Source.get_settings_schema(mod)
  rescue
    error ->
      Logger.warning(
        "Sitemap source #{inspect(mod)} returned an invalid settings schema: #{inspect(error)}"
      )

      []
  end

  defp read_extension_field(field) do
    case field.type do
      :boolean -> Settings.get_boolean_setting(field.key, field.default)
      :integer -> Settings.get_integer_setting(field.key, field.default)
      :string -> Settings.get_setting(field.key, field.default)
    end
  rescue
    _ -> field.default
  end

  # Helper: human-readable card title for a source module in the extension
  # section (e.g. `:router_discovery` -> "Router discovery").
  def source_display_name(mod) do
    mod.source_name() |> to_string() |> Phoenix.Naming.humanize()
  rescue
    _ -> mod |> to_string() |> String.trim_leading("Elixir.") |> Phoenix.Naming.humanize()
  end

  defp find_extension_field(socket, key) do
    Enum.find_value(socket.assigns.extension_sources, fn {_mod, fields} ->
      Enum.find(fields, &(&1.key == key))
    end)
  end

  defp refresh_extension_sources(socket) do
    assign(socket, :extension_sources, build_extension_sources(Generator.get_sources()))
  end

  defp save_extension_value(socket, key, value) do
    case Settings.update_setting(key, value) do
      {:ok, _} ->
        socket
        |> refresh_extension_sources()
        |> bump_and_broadcast(key)
        |> put_flash(:info, gettext("Setting updated"))

      {:error, _} ->
        put_flash(socket, :error, gettext("Failed to update setting"))
    end
  end

  # Check which parent modules are actually enabled (not just sitemap toggles)
  defp get_module_enabled_status do
    %{
      entities:
        Code.ensure_loaded?(PhoenixKitEntities) and safe_module_enabled?(PhoenixKitEntities),
      publishing: safe_module_available_and_enabled?(PhoenixKit.Modules.Publishing),
      shop: safe_module_enabled?(PhoenixKitEcommerce),
      posts: Code.ensure_loaded?(PhoenixKitPosts) and safe_module_enabled?(PhoenixKitPosts)
    }
  end

  defp safe_module_enabled?(module) do
    module.enabled?()
  rescue
    _ -> false
  end

  defp safe_module_available_and_enabled?(module) do
    Code.ensure_loaded?(module) and safe_module_enabled?(module)
  end

  defp get_sitemap_version(config) do
    case config.last_generated do
      nil ->
        UtilsDate.utc_now() |> DateTime.to_unix()

      iso_string when is_binary(iso_string) ->
        case DateTime.from_iso8601(iso_string) do
          {:ok, dt, _} -> DateTime.to_unix(dt)
          _ -> UtilsDate.utc_now() |> DateTime.to_unix()
        end
    end
  end
end
