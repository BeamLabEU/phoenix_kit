defmodule PhoenixKitWeb.Live.Settings do
  @moduledoc """
  Admin settings management LiveView for PhoenixKit.

  Provides interface for managing system-wide settings including timezone, date/time formats.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Events, as: SettingsEvents
  alias PhoenixKit.Users.OAuthConfig
  alias PhoenixKit.Utils.Date, as: UtilsDate

  require Logger

  @default_locale Config.default_locale()

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

    # Load module statuses
    languages_enabled = Languages.enabled?()

    # Load content language
    content_language = Settings.get_content_language()
    content_language_details = Settings.get_content_language_details()

    # Get available languages if module is enabled
    available_languages =
      if languages_enabled do
        Languages.get_enabled_languages()
      else
        []
      end

    # Load admin languages from settings cache
    # Default is [@default_locale] - a fresh install only has the default locale enabled
    admin_languages_json =
      Settings.get_setting_cached("admin_languages", nil) ||
        Jason.encode!([@default_locale])

    admin_languages =
      case Jason.decode(admin_languages_json) do
        {:ok, codes} when is_list(codes) -> codes
        _ -> [@default_locale]
      end

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
      |> assign(:languages_enabled, languages_enabled)
      |> assign(:content_language, content_language)
      |> assign(:content_language_details, content_language_details)
      |> assign(:available_content_languages, available_languages)
      |> assign(:admin_languages, admin_languages)

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
    settings_params_to_save = prepare_settings_params(settings_params)

    case Settings.update_settings(settings_params_to_save) do
      {:ok, updated_settings} ->
        handle_settings_saved(socket, settings_params_to_save, updated_settings)

      {:error, errors} ->
        handle_settings_error(socket, errors)
    end
  end

  def handle_event("test_oauth", %{"provider" => provider}, socket) do
    provider_atom = String.to_existing_atom(provider)

    case OAuthConfig.test_connection(provider_atom) do
      {:ok, message} ->
        socket = put_flash(socket, :info, message)
        {:noreply, socket}

      {:error, message} ->
        socket = put_flash(socket, :error, message)
        {:noreply, socket}
    end
  end

  def handle_event("reload_oauth_config", _params, socket) do
    # Reload OAuth configuration from database
    OAuthConfig.configure_providers()

    socket = put_flash(socket, :info, "OAuth configuration reloaded from database")
    {:noreply, socket}
  end

  def handle_event("reset_to_defaults", _params, socket) do
    # Get default settings
    defaults = Settings.get_defaults()

    # Update all settings to defaults in database
    case Settings.update_settings(defaults) do
      {:ok, updated_settings} ->
        # Also reset admin_languages to just the default locale
        Settings.update_json_setting("admin_languages", [@default_locale])

        # Update socket with default settings
        changeset = Settings.change_settings(updated_settings)

        socket =
          socket
          |> assign(:settings, updated_settings)
          |> assign(:saved_settings, updated_settings)
          |> assign(:changeset, changeset)
          |> assign(:project_title, updated_settings["project_title"] || "PhoenixKit")
          |> assign(:admin_languages, [@default_locale])
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

  def handle_event("update_content_language", %{"language" => language_code}, socket) do
    case Settings.set_content_language(language_code) do
      {:ok, _setting} ->
        # Reload content language details
        content_language_details = Settings.get_content_language_details()

        socket =
          socket
          |> assign(:content_language, language_code)
          |> assign(:content_language_details, content_language_details)
          |> put_flash(:info, "Content language updated to #{content_language_details.name}")

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, reason)
        {:noreply, socket}
    end
  end

  def handle_event(
        "add_admin_language_to_form",
        %{"admin_language_code_input" => language_code},
        socket
      )
      when language_code != "" do
    current_languages = socket.assigns.admin_languages || [@default_locale]

    # Toggle: add if not present, remove if already present
    if language_code in current_languages do
      # Remove language
      updated_languages = Enum.filter(current_languages, &(&1 != language_code))

      # Get language details for feedback
      language = Languages.get_predefined_language(language_code)
      language_name = if language, do: language.name, else: String.upcase(language_code)

      socket =
        socket
        |> assign(:admin_languages, updated_languages)
        |> put_flash(:info, "#{language_name} removed. Remember to save settings.")

      {:noreply, socket}
    else
      # Add language
      updated_languages = current_languages ++ [language_code]

      # Get language details for feedback
      language = Languages.get_predefined_language(language_code)
      language_name = if language, do: language.name, else: String.upcase(language_code)

      socket =
        socket
        |> assign(:admin_languages, updated_languages)
        |> put_flash(:info, "#{language_name} added. Remember to save settings.")

      {:noreply, socket}
    end
  end

  def handle_event("add_admin_language_to_form", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("remove_admin_language_from_form", %{"code" => code}, socket) do
    current_languages = socket.assigns.admin_languages || [@default_locale]

    # Prevent removing the last language
    if length(current_languages) <= 1 do
      socket =
        put_flash(
          socket,
          :warning,
          "Cannot remove the last language. At least one language must be configured."
        )

      {:noreply, socket}
    else
      updated_languages = Enum.filter(current_languages, &(&1 != code))

      # Get language details for feedback
      language = Languages.get_predefined_language(code)
      language_name = if language, do: language.name, else: String.upcase(code)

      socket =
        socket
        |> assign(:admin_languages, updated_languages)
        |> put_flash(:info, "#{language_name} removed. Remember to save settings.")

      {:noreply, socket}
    end
  end

  ## Live updates - handle broadcasts from other admins

  def handle_info({:content_language_changed, new_language}, socket) do
    # Another admin changed the content language - update our view
    content_language_details = Settings.get_content_language_details()

    socket =
      socket
      |> assign(:content_language, new_language)
      |> assign(:content_language_details, content_language_details)

    {:noreply, socket}
  end

  def handle_info({:admin_languages_changed, admin_languages}, socket) do
    # Another admin changed the admin languages - update our view
    socket = assign(socket, :admin_languages, admin_languages)
    {:noreply, socket}
  end

  # Catch-all for other settings changes (future-proof)
  def handle_info({:setting_changed, _key, _value}, socket) do
    {:noreply, socket}
  end

  # Handle successful settings save
  defp handle_settings_saved(socket, settings_params_to_save, updated_settings) do
    # Reload OAuth configuration to apply new credentials immediately
    OAuthConfig.configure_providers()

    # Broadcast admin languages change if it was updated
    if Map.has_key?(settings_params_to_save, "admin_languages") do
      admin_languages = parse_admin_languages_json(updated_settings["admin_languages"])
      SettingsEvents.broadcast_admin_languages_changed(admin_languages)
    end

    # Update socket with new settings
    changeset = Settings.change_settings(updated_settings)

    saved_admin_languages =
      extract_saved_admin_languages(settings_params_to_save, socket.assigns.admin_languages)

    socket =
      socket
      |> assign(:settings, updated_settings)
      |> assign(:saved_settings, updated_settings)
      |> assign(:changeset, changeset)
      |> assign(:saving, false)
      |> assign(:project_title, updated_settings["project_title"] || "PhoenixKit")
      |> assign(:admin_languages, saved_admin_languages)
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

  # Parse admin_languages JSON string to list
  # Default is [@default_locale] - a fresh install only has the default locale enabled
  defp parse_admin_languages_json(json) when is_binary(json) do
    if String.trim(json) != "" do
      case Jason.decode(json) do
        {:ok, codes} when is_list(codes) -> codes
        _ -> [@default_locale]
      end
    else
      [@default_locale]
    end
  end

  defp parse_admin_languages_json(_), do: [@default_locale]

  # Prepare settings params by handling admin_languages field
  # Ensures admin_languages is never empty - defaults to [@default_locale]
  defp prepare_settings_params(%{"admin_languages" => json} = params) when is_binary(json) do
    trimmed = String.trim(json)

    cond do
      # Empty string - use default
      trimmed == "" ->
        Map.put(params, "admin_languages", Jason.encode!([@default_locale]))

      # Empty JSON array - use default
      trimmed == "[]" ->
        Map.put(params, "admin_languages", Jason.encode!([@default_locale]))

      # Valid JSON - keep it
      true ->
        params
    end
  end

  defp prepare_settings_params(params), do: Map.delete(params, "admin_languages")

  # Extract admin_languages from saved params or use fallback
  defp extract_saved_admin_languages(settings_params, fallback) do
    if Map.has_key?(settings_params, "admin_languages") do
      parse_admin_languages_json(settings_params["admin_languages"])
    else
      fallback
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

  # Helper function to generate OAuth callback URL
  def get_oauth_callback_url(settings, provider) do
    site_url = settings["site_url"] || "https://example.com"
    url_prefix = PhoenixKit.Config.get_url_prefix()

    "#{site_url}#{url_prefix}/users/auth/#{provider}/callback"
  end
end
