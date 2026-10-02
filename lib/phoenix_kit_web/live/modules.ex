defmodule PhoenixKitWeb.Live.Modules do
  @moduledoc """
  Admin modules management LiveView for PhoenixKit.

  Displays available system modules and their configuration status.
  All module references are resolved at runtime via the ModuleRegistry,
  so removing or adding modules requires no changes to this file.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.ModuleDiscovery
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # ============================================================================
  # Mount
  # ============================================================================

  # Internal modules still rendered as hardcoded cards on this page. Storage
  # and Notifications are core capabilities (not real install/uninstall
  # toggles — see their moduledocs) and are configured entirely from their
  # own Settings pages, so they're deliberately excluded from this list.
  @internal_module_keys ["languages", "crawlers", "sitemap", "jobs"]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe_to_modules()

    project_title = Settings.get_project_title()
    module_configs = load_all_module_configs()

    scope = socket.assigns[:phoenix_kit_current_scope]
    accessible = if scope, do: Scope.accessible_modules(scope), else: MapSet.new()

    external_modules = load_external_modules(module_configs)
    dep_warnings = ModuleRegistry.dependency_warnings()
    not_installed = ModuleRegistry.not_installed_packages()
    # Read AFTER the list: `not_installed_packages/0` is what triggers the fetch.
    catalog_status = PhoenixKit.KnownPackages.status()

    socket =
      socket
      |> assign(:page_title, "Modules")
      |> assign(:project_title, project_title)
      |> assign(:accessible_modules, accessible)
      |> assign(:module_configs, module_configs)
      |> assign(:external_modules, external_modules)
      |> assign(:dep_warnings, dep_warnings)
      |> assign(:not_installed_packages, not_installed)
      |> assign(:catalog_status, catalog_status)
      |> assign(:hex_browse_url, PhoenixKit.KnownPackages.browse_url())
      |> assign(:modules_tab, "active")
      |> refresh_tab_counts()

    {:ok, socket}
  end

  # ============================================================================
  # Tab Switching
  # ============================================================================

  def handle_event("switch_modules_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :modules_tab, tab)}
  end

  # ============================================================================
  # Toggle Events
  # ============================================================================

  # All toggle events go through authorize_toggle/2 first.
  def handle_event("toggle_module", %{"key" => key}, socket) do
    case authorize_toggle(socket, key) do
      :ok -> dispatch_toggle(socket, key)
      {:error, :access_denied} -> {:noreply, put_flash(socket, :error, "Access denied")}
    end
  end

  # ============================================================================
  # PubSub Handlers
  # ============================================================================

  def handle_info({:module_enabled, module_key}, socket) do
    socket =
      socket
      |> reload_module_config(module_key)
      |> assign(:dep_warnings, ModuleRegistry.dependency_warnings())
      |> refresh_tab_counts()

    {:noreply, socket}
  end

  def handle_info({:module_disabled, module_key}, socket) do
    socket =
      socket
      |> reload_module_config(module_key)
      |> assign(:dep_warnings, ModuleRegistry.dependency_warnings())
      |> refresh_tab_counts()

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ============================================================================
  # Gettext registration — module names and descriptions are loaded dynamically
  # from each module's module_name/0 and permission_metadata/0 callbacks (or
  # from Hex.pm metadata for not-installed packages), so the strings are not
  # visible to `mix gettext.extract`. We register every known string here via
  # gettext_noop/1 so translators can localize the Modules overview page.
  # ============================================================================
  @compile {:no_warn_undefined, :_register_module_translations}
  @doc false
  def _register_module_translations do
    # Installed module names (module_name/0 results)
    [
      gettext_noop("AI"),
      gettext_noop("Billing"),
      gettext_noop("CRM"),
      # "Catalogue" until catalogue 0.39; "Catalogues" after — the module
      # took its pages' name so the two stop disagreeing.
      gettext_noop("Catalogue"),
      gettext_noop("Catalogues"),
      gettext_noop("Comments"),
      gettext_noop("Customer Support"),
      gettext_noop("Document Creator"),
      gettext_noop("E-Commerce"),
      gettext_noop("Ecommerce"),
      gettext_noop("Emails"),
      gettext_noop("Entities"),
      gettext_noop("Hello World"),
      gettext_noop("Legal"),
      gettext_noop("Locations"),
      gettext_noop("Newsletters"),
      gettext_noop("OG"),
      gettext_noop("Posts"),
      gettext_noop("Projects"),
      gettext_noop("Publishing"),
      gettext_noop("Staff"),
      gettext_noop("Sync"),
      gettext_noop("User Connections"),
      # Hex humanize variants (used by Available Packages section)
      gettext_noop("Ai"),
      gettext_noop("Crm"),
      # Module descriptions (from module_name + permission_metadata.description
      # of installed externals AND Hex metadata for not-installed packages)
      gettext_noop("AI endpoints, prompts, and usage tracking"),
      gettext_noop(
        "AI module for PhoenixKit — endpoints, prompts, completions, and usage tracking"
      ),
      gettext_noop("Billing module for PhoenixKit — payments, subscriptions, invoices"),
      gettext_noop("Blog posts, categories, and content publishing"),
      gettext_noop(
        "Catalogue module for PhoenixKit — manufacturers, suppliers, and product catalogues."
      ),
      gettext_noop("Comment moderation, threading, and reactions across all content types"),
      gettext_noop(
        "Comments module for PhoenixKit — polymorphic threading, likes/dislikes, and moderation"
      ),
      gettext_noop(
        "CRM module for PhoenixKit — organization accounts, role-scoped user views, and per-user column configuration."
      ),
      gettext_noop("Customer support ticketing module for PhoenixKit"),
      gettext_noop("Database-backed CMS pages and multi-language content"),
      gettext_noop(
        "Document Creator module for PhoenixKit — document templates and PDF generation via Google Docs"
      ),
      gettext_noop("E-commerce module for PhoenixKit — products, categories, cart, checkout"),
      gettext_noop("Email tracking, analytics, and AWS SES integration for PhoenixKit"),
      gettext_noop(
        "Entities module for PhoenixKit — dynamic content types with flexible field schemas"
      ),
      gettext_noop(
        "Hello World demo module for PhoenixKit — use as a template for your own plugins"
      ),
      gettext_noop(
        "Legal compliance module for PhoenixKit — GDPR/CCPA legal pages, cookie consent, consent logging"
      ),
      gettext_noop(
        "Locations module for PhoenixKit — manage physical locations with custom types."
      ),
      gettext_noop(
        "Newsletters module for PhoenixKit — email broadcasts and subscription management"
      ),
      gettext_noop("Peer-to-peer data sync module for PhoenixKit"),
      gettext_noop("Peer-to-peer data synchronization and replication"),
      gettext_noop(
        "Posts module for PhoenixKit — blog posts, tags, groups, likes, media, and scheduling"
      ),
      gettext_noop(
        "Projects module for PhoenixKit — projects, reusable tasks, assignments, and dependencies."
      ),
      gettext_noop(
        "Publishing module for PhoenixKit — database-backed CMS with multi-language support"
      ),
      gettext_noop("Staff module for PhoenixKit — departments, teams, and people."),
      gettext_noop(
        "User connections module for PhoenixKit — follows, mutual connections, and blocking"
      ),
      # External module description fallback used when permission_metadata is missing
      gettext_noop("External module")
    ]
  end

  # ============================================================================
  # Helpers (used in template)
  # ============================================================================

  @doc "Safely get a module config value, returning default if module not loaded."
  def mcfg(module_configs, key, field, default \\ nil) do
    case module_configs[key] do
      nil -> default
      config -> Map.get(config, field, default)
    end
  end

  @doc """
  Normalizes a module's enabled flag across the two config key spellings
  modules use: `:enabled` for most, `:module_enabled` for Crawlers and
  Storage (whose `get_config/0` reports `module_enabled: true`; it is always
  on). Use it wherever a module's config is read for "is it on", or a
  module keyed the other way reads as off (every external module that
  required Storage used to show "Requires Storage").
  """
  def module_enabled?(config) do
    cond do
      Map.has_key?(config, :enabled) -> config.enabled || false
      Map.has_key?(config, :module_enabled) -> config.module_enabled || false
      true -> false
    end
  end

  @doc "Whether a module's enabled state belongs on the given Modules-page tab."
  def modules_tab_match?("active", enabled?), do: enabled? == true
  def modules_tab_match?("disabled", enabled?), do: enabled? != true
  def modules_tab_match?(_tab, _enabled?), do: false

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

  def format_bytes(nil), do: "0 B"
  def format_bytes(0), do: "0 B"

  def format_bytes(%Decimal{} = bytes) do
    bytes |> Decimal.to_integer() |> format_bytes()
  end

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1024 do
    "#{bytes} B"
  end

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1_048_576 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1_073_741_824 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  def format_bytes(bytes) when is_integer(bytes) do
    "#{Float.round(bytes / 1_073_741_824, 2)} GB"
  end

  def format_bytes(_), do: "0 B"

  # ============================================================================
  # Private — Authorization
  # ============================================================================

  defp authorize_toggle(socket, _key) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    # Enabling/disabling modules is the `modules` management permission — hold
    # it and you can toggle any module. Gating on the system-role NAME instead
    # let a stripped Admin toggle everything while a grant-all custom role (or
    # `"*"` superadmin) could not enable a currently-DISABLED module (it can't
    # hold a not-yet-enabled module's key). `has_module_access?/2` honors the
    # `"*"` superadmin key, and reaching this page already requires `modules`,
    # so this is a defense-in-depth re-check on the event, role-agnostic.
    if scope && Scope.has_module_access?(scope, "modules") do
      :ok
    else
      {:error, :access_denied}
    end
  end

  # Special cases with inter-module dependencies
  defp dispatch_toggle(socket, "legal"), do: toggle_legal(socket)
  defp dispatch_toggle(socket, "newsletters"), do: toggle_newsletters(socket)
  defp dispatch_toggle(socket, key), do: generic_toggle(socket, key)

  # ============================================================================
  # Private — Generic Toggle
  # ============================================================================

  defp generic_toggle(socket, key) do
    mod = ModuleRegistry.get_by_key(key)

    if is_nil(mod) do
      {:noreply, put_flash(socket, :error, "Module not found")}
    else
      configs = socket.assigns.module_configs
      current_config = configs[key] || %{}
      currently_enabled = current_config[:enabled] || current_config[:module_enabled] || false
      new_enabled = !currently_enabled

      result =
        if new_enabled do
          mod.enable_system()
        else
          mod.disable_system()
        end

      case normalize_result(result) do
        :ok ->
          if new_enabled,
            do: Events.broadcast_module_enabled(key),
            else: Events.broadcast_module_disabled(key)

          config = mod.get_config()
          configs = Map.put(socket.assigns.module_configs, key, config)

          socket =
            socket
            |> assign(:module_configs, configs)
            |> assign(:external_modules, load_external_modules(configs))
            |> refresh_tab_counts()
            |> put_flash(
              :info,
              "#{mod.module_name()} #{if new_enabled, do: "enabled", else: "disabled"}"
            )

          {:noreply, socket}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to update #{mod.module_name()}")}
      end
    end
  end

  # ============================================================================
  # Private — Special Toggle Handlers
  # ============================================================================

  defp toggle_legal(socket) do
    configs = socket.assigns.module_configs
    legal_config = configs["legal"] || %{}
    currently_enabled = legal_config[:enabled] || false
    legal_mod = ModuleRegistry.get_by_key("legal")

    result =
      if currently_enabled,
        do: legal_mod.disable_system(),
        else: legal_mod.enable_system()

    case result do
      {:error, :publishing_required} ->
        {:noreply, put_flash(socket, :error, gettext("Please enable Publishing module first"))}

      other ->
        case normalize_result(other) do
          :ok ->
            if currently_enabled,
              do: Events.broadcast_module_disabled("legal"),
              else: Events.broadcast_module_enabled("legal")

            config = legal_mod.get_config()

            label =
              if currently_enabled,
                do: gettext("Legal module disabled"),
                else: gettext("Legal module enabled")

            configs = Map.put(socket.assigns.module_configs, "legal", config)

            {:noreply,
             socket
             |> assign(:module_configs, configs)
             |> assign(:external_modules, load_external_modules(configs))
             |> refresh_tab_counts()
             |> put_flash(:info, label)}

          {:error, _} ->
            action = if currently_enabled, do: "disable", else: "enable"

            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Failed to %{action} Legal module", action: action)
             )}
        end
    end
  end

  defp toggle_newsletters(socket) do
    configs = socket.assigns.module_configs
    newsletters_config = configs["newsletters"] || %{}
    newsletters_enabled = newsletters_config[:enabled] || false
    emails_enabled = (configs["emails"] || %{})[:enabled] || false

    if newsletters_enabled do
      # Disabling — always allowed
      generic_toggle(socket, "newsletters")
    else
      # Enabling — require emails
      if emails_enabled do
        generic_toggle(socket, "newsletters")
      else
        {:noreply, put_flash(socket, :error, "Please enable Emails module first")}
      end
    end
  end

  # ============================================================================
  # Private — Config Loading
  # ============================================================================

  defp load_all_module_configs do
    ModuleRegistry.all_modules()
    |> Enum.reduce(%{}, fn mod, acc ->
      with true <- Code.ensure_loaded?(mod),
           true <- function_exported?(mod, :module_key, 0),
           true <- function_exported?(mod, :get_config, 0) do
        Map.put(acc, mod.module_key(), mod.get_config())
      else
        _ -> acc
      end
    end)
  end

  defp reload_module_config(socket, key) do
    mod = ModuleRegistry.get_by_key(key)

    if mod && Code.ensure_loaded?(mod) && function_exported?(mod, :get_config, 0) do
      config = mod.get_config()
      configs = Map.put(socket.assigns.module_configs, key, config)

      socket
      |> assign(:module_configs, configs)
      |> assign(:external_modules, load_external_modules(configs))
    else
      socket
    end
  end

  # Recomputes the Active/Disabled/Not Installed tab badge counts from the
  # current `module_configs`/`external_modules`/`not_installed_packages`
  # assigns. Must be called after anything that changes those assigns, or the
  # counts drift from what the tabs actually show.
  defp refresh_tab_counts(socket) do
    %{
      accessible_modules: accessible,
      module_configs: configs,
      external_modules: external,
      not_installed_packages: not_installed
    } = socket.assigns

    internal_accessible = Enum.filter(@internal_module_keys, &(&1 in accessible))
    active_internal = Enum.count(internal_accessible, &module_enabled?(configs[&1] || %{}))

    external_accessible = Enum.filter(external, &(&1.key in accessible))
    active_external = Enum.count(external_accessible, & &1.enabled)

    active = active_internal + active_external
    disabled = length(internal_accessible) + length(external_accessible) - active

    assign(socket, :modules_tab_counts, %{
      active: active,
      disabled: disabled,
      not_installed: length(not_installed)
    })
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _}), do: :ok
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(error), do: {:error, error}

  # Build list of external/plugin modules (auto-discovered from deps).
  # Each entry has the info needed to render a generic module card.
  defp load_external_modules(module_configs) do
    ModuleDiscovery.cached_external_modules()
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :module_key, 0)
    end)
    |> Enum.map(&build_external_module_data(&1, module_configs))
    |> Enum.sort_by(& &1.name)
  end

  defp build_external_module_data(mod, module_configs) do
    key = mod.module_key()
    config = module_configs[key] || %{}
    perm = if function_exported?(mod, :permission_metadata, 0), do: mod.permission_metadata()

    %{
      module: mod,
      key: key,
      name: mod.module_name(),
      icon: (perm && perm[:icon]) || "hero-puzzle-piece",
      description: (perm && perm[:description]) || "External module",
      enabled: module_enabled?(config),
      config: safe_get_config(mod),
      version: if(function_exported?(mod, :version, 0), do: mod.version(), else: "0.0.0"),
      required_modules:
        if(function_exported?(mod, :required_modules, 0), do: mod.required_modules(), else: []),
      admin_links: extract_admin_links(mod),
      settings_path: extract_settings_path(mod)
    }
  end

  defp safe_get_config(mod) do
    if function_exported?(mod, :get_config, 0), do: mod.get_config(), else: %{}
  rescue
    _ -> %{}
  end

  defp extract_settings_path(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :settings_tabs, 0) do
      case mod.settings_tabs() do
        [first | _] -> "/admin/settings/" <> first.path
        _ -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp extract_admin_links(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :admin_tabs, 0) do
      mod.admin_tabs()
      |> Enum.filter(fn tab ->
        tab.live_view != nil and not Tab.hard_hidden?(tab) and tab.parent != nil
      end)
      |> Enum.uniq_by(fn tab -> tab.path end)
      |> Enum.take(3)
      |> Enum.map(fn tab ->
        %{label: Tab.localized_label(tab), path: "/admin/" <> tab.path, icon: tab.icon}
      end)
    else
      []
    end
  end
end
