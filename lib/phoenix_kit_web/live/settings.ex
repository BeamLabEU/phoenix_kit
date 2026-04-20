defmodule PhoenixKitWeb.Live.Settings do
  @moduledoc """
  Admin settings management LiveView for PhoenixKit.

  Provides interface for managing system-wide settings including timezone, date/time formats.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Config.EndpointUrlSync
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Events, as: SettingsEvents
  alias PhoenixKit.Users.OAuthConfig
  alias PhoenixKit.Utils.Date, as: UtilsDate

  require Logger

  def mount(_params, _session, socket) do
    # Subscribe to settings changes for live updates (like entities does)
    if connected?(socket) do
      SettingsEvents.subscribe_to_settings()
    end

    # Load current settings from database
    current_settings = Settings.list_all_settings()
    defaults = Settings.get_defaults()
    setting_options = Settings.get_setting_options()

    # Merge defaults with current settings to ensure all keys exist
    merged_settings = Map.merge(defaults, current_settings)

    # Create form changeset
    changeset = Settings.change_settings(merged_settings)

    socket =
      socket
      |> assign(:page_title, "Settings")
      |> assign(:settings, merged_settings)
      # Track saved values separately
      |> assign(:saved_settings, merged_settings)
      |> assign(:setting_options, setting_options)
      |> assign(:changeset, changeset)
      |> assign(:saving, false)
      |> assign(:show_media_selector, false)
      |> assign(:media_selector_target, nil)
      |> assign(
        :project_title,
        merged_settings["project_title"] || PhoenixKit.Config.get(:project_title, "PhoenixKit")
      )

    {:ok, socket}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("validate_settings", %{"settings" => settings_params}, socket) do
    # Update the changeset with new values for validation
    changeset = Settings.validate_settings(settings_params)

    # Update the current settings to reflect the pending changes (but don't save to DB)
    socket =
      socket
      |> assign(:settings, settings_params)
      |> assign(:changeset, changeset)

    {:noreply, socket}
  end

  def handle_event("save_settings", %{"settings" => settings_params}, socket) do
    socket = assign(socket, :saving, true)

    case Settings.update_settings(settings_params) do
      {:ok, updated_settings} ->
        handle_settings_saved(socket, settings_params, updated_settings)

      {:error, errors} ->
        handle_settings_error(socket, errors)
    end
  end

  def handle_event("reset_to_defaults", _params, socket) do
    # Get default settings
    defaults = Settings.get_defaults()

    # Update all settings to defaults in database
    case Settings.update_settings(defaults) do
      {:ok, updated_settings} ->
        # Sync site_url to Endpoint after reset
        EndpointUrlSync.sync()

        # Update socket with default settings
        changeset = Settings.change_settings(updated_settings)

        socket =
          socket
          |> assign(:settings, updated_settings)
          |> assign(:saved_settings, updated_settings)
          |> assign(:changeset, changeset)
          |> assign(
            :project_title,
            updated_settings["project_title"] ||
              PhoenixKit.Config.get(:project_title, "PhoenixKit")
          )
          |> put_flash(:info, "Settings reset to defaults successfully")

        {:noreply, socket}

      {:error, errors} ->
        error_msg = format_error_message(errors)

        socket =
          socket
          |> put_flash(:error, error_msg)

        {:noreply, socket}
    end
  end

  def handle_event("open_media_selector", %{"target" => target}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, true)
     |> assign(:media_selector_target, target)}
  end

  def handle_event("clear_image", %{"target" => target}, socket) do
    key = media_target_to_key(target)
    settings = Map.put(socket.assigns.settings, key, "")
    {:noreply, assign(socket, :settings, settings)}
  end

  ## Media selector callbacks

  def handle_info({:media_selected, file_uuids}, socket) do
    file_uuid = List.first(file_uuids) || ""
    key = media_target_to_key(socket.assigns.media_selector_target)
    settings = Map.put(socket.assigns.settings, key, file_uuid)

    {:noreply,
     socket
     |> assign(:settings, settings)
     |> assign(:show_media_selector, false)
     |> assign(:media_selector_target, nil)}
  end

  def handle_info({:media_selector_closed}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, false)
     |> assign(:media_selector_target, nil)}
  end

  # Catch-all for other settings changes (future-proof)
  def handle_info({:setting_changed, _key, _value}, socket) do
    {:noreply, socket}
  end

  defp media_target_to_key("logo"), do: "auth_logo_file_uuid"
  defp media_target_to_key("site_icon"), do: "site_icon_file_uuid"
  defp media_target_to_key(_), do: "auth_logo_file_uuid"

  # Handle successful settings save
  defp handle_settings_saved(socket, _settings_params_to_save, updated_settings) do
    # Sync site_url to Endpoint and reload OAuth configuration
    EndpointUrlSync.sync()
    OAuthConfig.configure_providers()

    # Update socket with new settings
    changeset = Settings.change_settings(updated_settings)

    socket =
      socket
      |> assign(:settings, updated_settings)
      |> assign(:saved_settings, updated_settings)
      |> assign(:changeset, changeset)
      |> assign(:saving, false)
      |> assign(
        :project_title,
        updated_settings["project_title"] || PhoenixKit.Config.get(:project_title, "PhoenixKit")
      )
      |> put_flash(:info, "Settings updated successfully")

    {:noreply, socket}
  end

  # Handle settings save error
  defp handle_settings_error(socket, errors) do
    Logger.error("Settings save error: #{inspect(errors)}")

    error_msg = format_error_message(errors)

    socket =
      socket
      |> assign(:saving, false)
      |> put_flash(:error, error_msg)

    {:noreply, socket}
  end

  # Format error messages for display
  defp format_error_message(%Ecto.Changeset{} = changeset) do
    # Extract error messages from changeset
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Map.values()
    |> List.flatten()
    |> Enum.join(", ")
  end

  # Helper functions for template to show dropdown labels
  def get_timezone_label(value, setting_options) do
    Settings.get_timezone_label(value, setting_options)
  end

  def get_option_label(value, options) do
    Settings.get_option_label(value, options)
  end

  # Helper functions for template to show current format examples
  def get_current_date_example(format) do
    UtilsDate.format_date(Date.utc_today(), format)
  end

  def get_current_time_example(format) do
    UtilsDate.format_time(Time.utc_now(), format)
  end

  def signed_preview_url(file_uuid, variant) do
    URLSigner.signed_url(file_uuid, variant)
  end
end
