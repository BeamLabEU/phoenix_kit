defmodule PhoenixKitWeb.Live.SettingsLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate

  def mount(_params, _session, socket) do
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
      |> assign(:project_title, merged_settings["project_title"] || "PhoenixKit")

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
        # Update socket with new settings
        changeset = Settings.change_settings(updated_settings)

        socket =
          socket
          |> assign(:settings, updated_settings)
          # Update saved values
          |> assign(:saved_settings, updated_settings)
          |> assign(:changeset, changeset)
          |> assign(:saving, false)
          |> assign(:project_title, updated_settings["project_title"] || "PhoenixKit")
          |> put_flash(:info, "Settings updated successfully")

        {:noreply, socket}

      {:error, errors} ->
        error_msg = format_error_message(errors)

        socket =
          socket
          |> assign(:saving, false)
          |> put_flash(:error, error_msg)

        {:noreply, socket}
    end
  end

  def handle_event("reset_to_defaults", _params, socket) do
    # Get default settings
    defaults = Settings.get_defaults()

    # Update all settings to defaults in database
    case Settings.update_settings(defaults) do
      {:ok, updated_settings} ->
        # Update socket with default settings
        changeset = Settings.change_settings(updated_settings)

        socket =
          socket
          |> assign(:settings, updated_settings)
          |> assign(:saved_settings, updated_settings)
          |> assign(:changeset, changeset)
          |> assign(:project_title, updated_settings["project_title"] || "PhoenixKit")
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
end
