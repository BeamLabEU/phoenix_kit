defmodule PhoenixKitWeb.Live.Modules.Sitemaps.Settings do
  @moduledoc """
  LiveView for sitemap configuration and management.

  Provides admin interface for:
  - Enabling/disabling sitemap module
  - Configuring data sources (entities, blogs, pages, static)
  - Setting HTML sitemap style
  - Manual sitemap regeneration
  - Viewing generation statistics
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Sitemap
  alias PhoenixKit.Sitemap.Generator
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    locale = params["locale"] || "en"
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    site_url = Settings.get_setting("site_url", "")
    config = Sitemap.get_config()

    socket =
      socket
      |> assign(:page_title, "Sitemap Settings")
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/settings/sitemap", locale: locale))
      |> assign(:config, config)
      |> assign(:site_url, site_url)
      |> assign(:generating, false)
      |> assign(:preview_mode, nil)
      |> assign(:preview_content, nil)
      |> assign(:show_preview, false)
      |> assign(:show_html_preview, false)

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

        {:noreply,
         socket
         |> assign(:config, config)
         |> put_flash(:info, message)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update sitemap status")}
    end
  end

  @impl true
  def handle_event("toggle_source", %{"source" => source}, socket) do
    # Router discovery uses different key pattern
    key =
      if source == "router_discovery" do
        "sitemap_router_discovery_enabled"
      else
        "sitemap_include_#{source}"
      end

    current = Settings.get_boolean_setting(key, true)

    case Settings.update_boolean_setting(key, !current) do
      {:ok, _} ->
        config = Sitemap.get_config()
        {:noreply, assign(socket, :config, config)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update source setting")}
    end
  end

  @impl true
  def handle_event("toggle_html", _params, socket) do
    current = socket.assigns.config.html_enabled

    case Settings.update_boolean_setting("sitemap_html_enabled", !current) do
      {:ok, _} ->
        config = Sitemap.get_config()
        {:noreply, assign(socket, :config, config)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update HTML sitemap setting")}
    end
  end

  @impl true
  def handle_event("toggle_schedule", _params, socket) do
    current = socket.assigns.config.schedule_enabled

    case Settings.update_boolean_setting("sitemap_schedule_enabled", !current) do
      {:ok, _} ->
        config = Sitemap.get_config()
        {:noreply, assign(socket, :config, config)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update schedule setting")}
    end
  end

  @impl true
  def handle_event("update_style", %{"style" => style}, socket) do
    case Settings.update_setting("sitemap_html_style", style) do
      {:ok, _} ->
        config = Sitemap.get_config()
        {:noreply, assign(socket, :config, config)}

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
            {:noreply, assign(socket, :config, config)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update interval")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid interval value")}
    end
  end

  @impl true
  def handle_event("regenerate", _params, socket) do
    socket = assign(socket, :generating, true)

    # Get base URL for generation
    base_url = Sitemap.get_base_url()

    if base_url != "" do
      # Collect entries first to get URL count
      entries = Generator.collect_all_entries(base_url: base_url)
      url_count = length(entries)

      # Get XSL style from config (mapped from html_style)
      xsl_style = get_xsl_style(socket.assigns.config.html_style)

      opts = [
        base_url: base_url,
        cache: true,
        xsl_style: xsl_style,
        xsl_enabled: socket.assigns.config.html_enabled
      ]

      case Generator.generate_xml(opts) do
        {:ok, _xml} ->
          # Update stats with actual URL count
          Sitemap.update_generation_stats(%{url_count: url_count})
          config = Sitemap.get_config()

          {:noreply,
           socket
           |> assign(:generating, false)
           |> assign(:config, config)
           |> put_flash(:info, "Sitemap regenerated successfully (#{url_count} URLs)")}

        {:ok, _xml, _parts} ->
          Sitemap.update_generation_stats(%{url_count: url_count})
          config = Sitemap.get_config()

          {:noreply,
           socket
           |> assign(:generating, false)
           |> assign(:config, config)
           |> put_flash(:info, "Sitemap regenerated with index (#{url_count} URLs)")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:generating, false)
           |> put_flash(:error, "Regeneration failed: #{inspect(reason)}")}
      end
    else
      {:noreply,
       socket
       |> assign(:generating, false)
       |> put_flash(:error, "Please configure Base URL before generating")}
    end
  end

  @impl true
  def handle_event("preview", %{"type" => _type}, socket) do
    base_url = Sitemap.get_base_url()
    xsl_style = get_xsl_style(socket.assigns.config.html_style)

    opts = [
      base_url: base_url,
      cache: false,
      xsl_style: xsl_style,
      xsl_enabled: socket.assigns.config.html_enabled
    ]

    content =
      case Generator.generate_xml(opts) do
        {:ok, xml} -> xml
        {:ok, xml, _parts} -> xml
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
  def handle_event("preview_html", _params, socket) do
    {:noreply, assign(socket, :show_html_preview, true)}
  end

  @impl true
  def handle_event("close_html_preview", _params, socket) do
    {:noreply, assign(socket, :show_html_preview, false)}
  end

  @impl true
  def handle_event("invalidate_cache", _params, socket) do
    Generator.invalidate_cache()

    {:noreply,
     socket
     |> put_flash(:info, "Sitemap cache cleared")}
  end

  # Maps old HTML style names to new XSL style names
  # hierarchical -> cards, grouped -> table, flat -> minimal
  def get_xsl_style(html_style) do
    case html_style do
      "hierarchical" -> "cards"
      "grouped" -> "table"
      "flat" -> "minimal"
      style when style in ["table", "cards", "minimal"] -> style
      _ -> "table"
    end
  end

  # Format ISO8601 timestamp string to human-readable format
  def format_timestamp(nil), do: "Never"

  def format_timestamp(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} ->
        # Convert to NaiveDateTime for UtilsDate
        ndt = DateTime.to_naive(dt)
        UtilsDate.format_datetime_full_with_user_format(ndt)

      _ ->
        iso_string
    end
  end

  def format_timestamp(_), do: "Never"
end
