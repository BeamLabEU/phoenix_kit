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
  alias PhoenixKit.ModuleDiscovery
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # ============================================================================
  # Mount
  # ============================================================================

  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe_to_modules()

    project_title = Settings.get_project_title()
    module_configs = load_all_module_configs()

    scope = socket.assigns[:phoenix_kit_current_scope]
    accessible = if scope, do: Scope.accessible_modules(scope), else: MapSet.new()

    external_modules = load_external_modules(module_configs)

    socket =
      socket
      |> assign(:page_title, "Modules")
      |> assign(:project_title, project_title)
      |> assign(:accessible_modules, accessible)
      |> assign(:module_configs, module_configs)
      |> assign(:external_modules, external_modules)

    {:ok, socket}
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
    {:noreply, reload_module_config(socket, module_key)}
  end

  def handle_info({:module_disabled, module_key}, socket) do
    {:noreply, reload_module_config(socket, module_key)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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

  defp authorize_toggle(socket, key) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope &&
         (Scope.system_role?(scope) || MapSet.member?(socket.assigns.accessible_modules, key)) do
      :ok
    else
      {:error, :access_denied}
    end
  end

  # Special cases with inter-module dependencies
  defp dispatch_toggle(socket, "billing"), do: toggle_billing(socket)
  defp dispatch_toggle(socket, "legal"), do: toggle_legal(socket)
  defp dispatch_toggle(socket, "shop"), do: toggle_shop(socket)
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

  defp toggle_billing(socket) do
    configs = socket.assigns.module_configs
    billing_config = configs["billing"] || %{}
    new_enabled = !(billing_config[:enabled] || false)

    billing_mod = ModuleRegistry.get_by_key("billing")
    result = if new_enabled, do: billing_mod.enable_system(), else: billing_mod.disable_system()

    case normalize_result(result) do
      :ok ->
        # Disable shop AFTER billing succeeds to avoid orphaned state on failure
        shop_was_disabled = maybe_disable_shop_first(new_enabled, configs)
        broadcast_billing_events(new_enabled, shop_was_disabled)

        updated_configs =
          reload_configs(configs, ["billing"] ++ if(shop_was_disabled, do: ["shop"], else: []))

        socket =
          socket
          |> assign(:module_configs, updated_configs)
          |> put_flash(
            :info,
            if(new_enabled, do: "Billing module enabled", else: "Billing module disabled")
          )

        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to update billing module")}
    end
  end

  defp maybe_disable_shop_first(true, _configs), do: false

  defp maybe_disable_shop_first(false, configs) do
    shop_config = configs["shop"] || %{}

    if shop_config[:enabled] do
      shop_mod = ModuleRegistry.get_by_key("shop")
      if shop_mod, do: shop_mod.disable_system()
      true
    else
      false
    end
  end

  defp broadcast_billing_events(true, _shop_was_disabled) do
    Events.broadcast_module_enabled("billing")
  end

  defp broadcast_billing_events(false, shop_was_disabled) do
    Events.broadcast_module_disabled("billing")
    if shop_was_disabled, do: Events.broadcast_module_disabled("shop")
  end

  defp reload_configs(configs, keys) do
    Enum.reduce(keys, configs, fn key, acc ->
      mod = ModuleRegistry.get_by_key(key)

      if mod && Code.ensure_loaded?(mod) && function_exported?(mod, :get_config, 0),
        do: Map.put(acc, key, mod.get_config()),
        else: acc
    end)
  end

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

            {:noreply,
             socket
             |> update(:module_configs, &Map.put(&1, "legal", config))
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

  defp toggle_shop(socket) do
    configs = socket.assigns.module_configs
    shop_config = configs["shop"] || %{}
    shop_enabled = shop_config[:enabled] || false
    billing_enabled = (configs["billing"] || %{})[:enabled] || false
    shop_mod = ModuleRegistry.get_by_key("shop")

    if shop_enabled do
      case normalize_result(shop_mod.disable_system()) do
        :ok ->
          Events.broadcast_module_disabled("shop")
          config = shop_mod.get_config()

          {:noreply,
           socket
           |> update(:module_configs, &Map.put(&1, "shop", config))
           |> put_flash(:info, gettext("E-Commerce module disabled"))}

        _ ->
          {:noreply, put_flash(socket, :error, gettext("Failed to disable E-Commerce module"))}
      end
    else
      if billing_enabled do
        case normalize_result(shop_mod.enable_system()) do
          :ok ->
            Events.broadcast_module_enabled("shop")
            config = shop_mod.get_config()

            {:noreply,
             socket
             |> update(:module_configs, &Map.put(&1, "shop", config))
             |> put_flash(:info, gettext("E-Commerce module enabled"))}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Failed to enable E-Commerce module"))}
        end
      else
        {:noreply, put_flash(socket, :error, gettext("Please enable Billing module first"))}
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

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _}), do: :ok
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(error), do: {:error, error}

  # Build list of external/plugin modules (auto-discovered from deps).
  # Each entry has the info needed to render a generic module card.
  defp load_external_modules(module_configs) do
    ModuleDiscovery.discover_external_modules()
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :module_key, 0)
    end)
    |> Enum.map(fn mod ->
      key = mod.module_key()
      config = module_configs[key] || %{}
      perm = if function_exported?(mod, :permission_metadata, 0), do: mod.permission_metadata()

      %{
        module: mod,
        key: key,
        name: mod.module_name(),
        icon: (perm && perm[:icon]) || "hero-puzzle-piece",
        description: (perm && perm[:description]) || "External module",
        enabled: config[:enabled] || false,
        version: if(function_exported?(mod, :version, 0), do: mod.version(), else: "0.0.0")
      }
    end)
    |> Enum.sort_by(& &1.name)
  end
end
