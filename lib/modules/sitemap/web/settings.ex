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

  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKit.Modules.Sitemap.FileStorage
  alias PhoenixKit.Modules.Sitemap.Generator
  alias PhoenixKit.Modules.Sitemap.SchedulerWorker
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      PubSubManager.subscribe("sitemap:updates")
      PubSubManager.subscribe("sitemap:settings")
    end

    locale = params["locale"] || "en"
    project_title = Settings.get_project_title()
    site_url = Settings.get_setting("site_url", "")
    config = Sitemap.get_config()
    sitemap_version = get_sitemap_version(config)
    module_stats = Sitemap.get_module_stats()
    module_files = FileStorage.list_module_files()

    socket =
      socket
      |> assign(:page_title, "Sitemap Settings")
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/settings/sitemap", locale: locale))
      |> assign(:config, config)
      |> assign(:site_url, site_url)
      |> assign(:generating, false)
      |> assign(:regenerating_module, nil)
      |> assign(:preview_mode, nil)
      |> assign(:preview_content, nil)
      |> assign(:show_preview, false)
      |> assign(:sitemap_version, sitemap_version)
      |> assign(:module_stats, module_stats)
      |> assign(:module_files, module_files)
      |> assign(:include_registration, Sitemap.include_registration?())
      |> assign(:publishing_split_by_group, Sitemap.publishing_split_by_group?())
      |> assign(:module_enabled, get_module_enabled_status())

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
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
        message = if new_enabled, do: "Sitemap enabled", else: "Sitemap disabled"
        new_version = DateTime.utc_now() |> DateTime.to_unix()
        broadcast_settings_change(:sitemap_toggled, %{enabled: new_enabled, version: new_version})

        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:sitemap_version, new_version)
         |> put_flash(:info, message)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update sitemap status")}
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
        new_version = DateTime.utc_now() |> DateTime.to_unix()

        broadcast_settings_change(:source_changed, %{
          source: "router_discovery",
          version: new_version
        })

        module_stats = if new_value, do: [], else: Sitemap.get_module_stats()
        module_files = if new_value, do: [], else: FileStorage.list_module_files()

        message =
          if new_value,
            do: "Router Discovery enabled — flat sitemap mode active",
            else: "Router Discovery disabled — per-module sitemap mode"

        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:sitemap_version, new_version)
         |> assign(:module_stats, module_stats)
         |> assign(:module_files, module_files)
         |> put_flash(:info, message)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update source setting")}
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
        new_version = DateTime.utc_now() |> DateTime.to_unix()
        broadcast_settings_change(:source_changed, %{source: source, version: new_version})

        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:sitemap_version, new_version)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update source setting")}
    end
  end

  @impl true
  def handle_event("toggle_registration", _params, socket) do
    new_value = !socket.assigns.include_registration

    case Settings.update_boolean_setting("sitemap_include_registration", new_value) do
      {:ok, _} ->
        Generator.invalidate_cache()
        new_version = DateTime.utc_now() |> DateTime.to_unix()

        {:noreply,
         socket
         |> assign(:include_registration, new_value)
         |> assign(:sitemap_version, new_version)
         |> put_flash(
           :info,
           "Registration page #{if new_value, do: "included", else: "excluded"}"
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update registration setting")}
    end
  end

  @impl true
  def handle_event("toggle_publishing_split", _params, socket) do
    new_value = !socket.assigns.publishing_split_by_group

    case Settings.update_boolean_setting("sitemap_publishing_split_by_group", new_value) do
      {:ok, _} ->
        Generator.invalidate_cache()
        new_version = DateTime.utc_now() |> DateTime.to_unix()

        {:noreply,
         socket
         |> assign(:publishing_split_by_group, new_value)
         |> assign(:sitemap_version, new_version)
         |> put_flash(
           :info,
           "Publishing #{if new_value, do: "split by blog", else: "combined into one file"}"
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update publishing split setting")}
    end
  end

  @impl true
  def handle_event("toggle_html", _params, socket) do
    current = socket.assigns.config.html_enabled

    case Settings.update_boolean_setting("sitemap_html_enabled", !current) do
      {:ok, _} ->
        Generator.invalidate_cache()
        config = Sitemap.get_config()
        new_version = DateTime.utc_now() |> DateTime.to_unix()
        broadcast_settings_change(:html_changed, %{enabled: !current, version: new_version})

        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:sitemap_version, new_version)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update HTML sitemap setting")}
    end
  end

  @impl true
  def handle_event("toggle_schedule", _params, socket) do
    current = socket.assigns.config.schedule_enabled

    case Settings.update_boolean_setting("sitemap_schedule_enabled", !current) do
      {:ok, _} ->
        unless current == false do
          SchedulerWorker.cancel_scheduled()
        end

        config = Sitemap.get_config()
        new_version = DateTime.utc_now() |> DateTime.to_unix()
        broadcast_settings_change(:schedule_changed, %{enabled: !current, version: new_version})

        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:sitemap_version, new_version)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update schedule setting")}
    end
  end

  @impl true
  def handle_event("update_style", %{"style" => style}, socket) do
    case Settings.update_setting("sitemap_html_style", style) do
      {:ok, _} ->
        Generator.invalidate_cache()
        config = Sitemap.get_config()
        new_version = DateTime.utc_now() |> DateTime.to_unix()
        broadcast_settings_change(:style_changed, %{style: style, version: new_version})

        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:sitemap_version, new_version)
         |> put_flash(:info, "Style updated. Sitemap will use new style on next load.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update style")}
    end
  end

  @impl true
  def handle_event("update_interval", %{"interval" => interval_str}, socket) do
    case Integer.parse(interval_str) do
      {interval, _} when interval > 0 ->
        case Settings.update_setting("sitemap_schedule_interval_hours", interval_str) do
          {:ok, _} ->
            config = Sitemap.get_config()
            new_version = DateTime.utc_now() |> DateTime.to_unix()

            broadcast_settings_change(:interval_changed, %{
              interval: interval,
              version: new_version
            })

            {:noreply,
             socket
             |> assign(:config, config)
             |> assign(:sitemap_version, new_version)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update interval")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid interval value")}
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
           |> put_flash(:info, "Sitemap generation queued. Stats will update automatically.")}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to queue generation: #{inspect(reason)}")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Please configure Base URL before generating")}
    end
  end

  @impl true
  def handle_event("regenerate_module", %{"source" => source_name}, socket) do
    base_url = Sitemap.get_base_url()

    if base_url != "" do
      case SchedulerWorker.regenerate_module_now(source_name) do
        {:ok, _job} ->
          {:noreply,
           socket
           |> assign(:regenerating_module, source_name)
           |> put_flash(:info, "Regenerating #{source_name} sitemap...")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to regenerate: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Please configure Base URL first")}
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
        _ -> "Error generating XML preview"
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
        new_version = DateTime.utc_now() |> DateTime.to_unix()

        {:noreply,
         socket
         |> assign(:sitemap_version, new_version)
         |> assign(:generating, true)
         |> assign(:module_stats, [])
         |> assign(:module_files, [])
         |> put_flash(:info, "All sitemaps cleared. Regeneration started...")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to regenerate: #{inspect(reason)}")}
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
     |> assign(:regenerating_module, nil)
     |> assign(:config, config)
     |> assign(:sitemap_version, sitemap_version)
     |> assign(:module_stats, module_stats)
     |> assign(:module_files, module_files)
     |> put_flash(:info, "Sitemap generated successfully (#{count} URLs)")}
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
    new_version = DateTime.utc_now() |> DateTime.to_unix()

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

  def format_timestamp(nil), do: "Never"

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

  def format_timestamp(_), do: "Never"

  # Check which parent modules are actually enabled (not just sitemap toggles)
  defp get_module_enabled_status do
    %{
      entities: safe_module_enabled?(PhoenixKit.Modules.Entities),
      publishing: safe_module_enabled?(PhoenixKit.Modules.Publishing),
      shop: safe_module_enabled?(PhoenixKit.Modules.Shop),
      posts: safe_module_enabled?(PhoenixKit.Modules.Posts)
    }
  end

  defp safe_module_enabled?(module) do
    module.enabled?()
  rescue
    _ -> false
  end

  defp get_sitemap_version(config) do
    case config.last_generated do
      nil ->
        DateTime.utc_now() |> DateTime.to_unix()

      iso_string when is_binary(iso_string) ->
        case DateTime.from_iso8601(iso_string) do
          {:ok, dt, _} -> DateTime.to_unix(dt)
          _ -> DateTime.utc_now() |> DateTime.to_unix()
        end
    end
  end
end
