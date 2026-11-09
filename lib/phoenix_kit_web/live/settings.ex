defmodule PhoenixKitWeb.Live.Settings do
  @moduledoc """
  Admin settings management LiveView for PhoenixKit.

  Provides interface for managing system-wide settings including timezone, date/time formats.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Config.EndpointUrlSync
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Events, as: SettingsEvents
  alias PhoenixKit.Users.OAuthConfig
  alias PhoenixKit.Utils.CountryData
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.TimeZone
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Live.Settings.UrlTabs

  require Logger

  def mount(_params, _session, socket) do
    # Subscribe to settings changes for live updates (like entities does)
    if connected?(socket) do
      SettingsEvents.subscribe_to_settings()
    end

    # Load current settings from database. S007: this page never renders the
    # OAuth login secrets or AWS keys (that's the Authorization page's job),
    # so it has no reason to hold their real values in socket state at all —
    # list_public_settings/0 (an explicit allow list, not a redaction of
    # list_all_settings/0) leaves them out entirely.
    current_settings = Settings.list_public_settings()
    defaults = Settings.get_defaults()

    # The saved site timezone has to be one of the offered options, or the
    # <select> renders with its FIRST option selected and the next save of this
    # form silently rewrites the site's timezone. Every installation that
    # predates named timezones stores an offset like "0", which is no longer a
    # row on its own, so it is added as one.
    saved_time_zone =
      Map.get(current_settings, "time_zone") || Settings.get_setting("time_zone", "0")

    setting_options =
      Map.put(
        Settings.get_setting_options(),
        "time_zone",
        TimeZone.options(selected: saved_time_zone)
      )

    # Merge defaults with current settings to ensure all keys exist, then
    # take only the public keys again — defaults still lists the restricted
    # ones (with their harmless placeholder values), and the merge must not
    # reintroduce them.
    merged_settings =
      Map.merge(defaults, current_settings)
      |> Map.take(Settings.public_setting_keys())

    # Create form changeset
    changeset = Settings.change_settings(merged_settings)

    socket =
      socket
      |> assign(:page_title, gettext("General"))
      |> assign(:page_subtitle, gettext("Configure system preferences and options"))
      |> assign(:page_section, gettext("Settings"))
      |> assign(:page_section_path, Routes.path("/admin/settings"))
      |> assign(:settings, merged_settings)
      # Track saved values separately
      |> assign(:saved_settings, merged_settings)
      |> assign(:setting_options, setting_options)
      |> assign(:country_options, CountryData.countries_for_select())
      |> assign(:changeset, changeset)
      |> assign(:saving, false)
      |> assign(:show_media_selector, false)
      |> assign(:media_selector_target, nil)
      # Resolved when the selector opens — the host hook may create a folder.
      |> assign(:branding_scope_folder, nil)
      |> assign(:primary_language_name, primary_language_name())
      |> assign(
        :project_title,
        merged_settings["project_title"] || PhoenixKit.Config.get(:project_title, "PhoenixKit")
      )

    {:ok, socket}
  end

  defp primary_language_name do
    code = Languages.primary_language_code()

    case Languages.get_predefined_language(code) do
      %{name: name} when is_binary(name) -> name
      _ -> code
    end
  end

  # The tab lives in the URL (`?tab=sessions`); see `UrlTabs`.
  def handle_params(params, _url, socket) do
    {:noreply, assign(socket, :active_tab, UrlTabs.active(params, tabs()))}
  end

  defp tabs do
    [
      %{id: "identity", label: gettext("Site Identity"), icon: "hero-identification"},
      %{id: "address", label: gettext("Site Address"), icon: "hero-globe-alt"},
      %{id: "features", label: gettext("Features"), icon: "hero-adjustments-horizontal"},
      %{id: "editor", label: gettext("Content Editor"), icon: "hero-pencil-square"},
      %{id: "datetime", label: gettext("Date & Time"), icon: "hero-clock"}
    ]
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

    case Settings.update_settings(settings_params, history_opts(socket)) do
      {:ok, updated_settings} ->
        handle_settings_saved(socket, settings_params, updated_settings)

      {:error, errors} ->
        handle_settings_error(socket, errors)
    end
  end

  def handle_event("reset_to_defaults", _params, socket) do
    # S007: this page never manages the OAuth login secrets or AWS keys, so
    # reset must not touch them either — Settings.get_defaults/0 includes
    # them (aws_access_key_id/aws_secret_access_key can even default to the
    # host's real configured credentials via PhoenixKit.Config.AWS), and
    # update_settings/1 writes every key it's handed. Without this filter,
    # clicking "Reset" here would silently overwrite live OAuth/AWS
    # credentials the confirm dialog never mentions.
    defaults = Settings.get_defaults() |> Map.take(Settings.public_setting_keys())

    # Update public settings to defaults in database
    case Settings.update_settings(defaults, history_opts(socket)) do
      {:ok, updated_settings} ->
        # Sync site_url to Endpoint after reset
        EndpointUrlSync.sync()

        # Update socket with default settings. Keys the save left alone
        # (`settings.security` ones, for a holder without it) keep their values.
        updated_settings = Map.merge(socket.assigns.saved_settings, updated_settings)
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
          |> put_flash(:info, gettext("Settings reset to defaults successfully"))

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
     |> assign(
       :branding_scope_folder,
       PhoenixKit.UploadsParentFolder.resolve(:branding, Actor.uuid(socket), nil)
     )
     |> assign(:show_media_selector, true)
     |> assign(:media_selector_target, target)}
  end

  def handle_event("clear_image", %{"target" => target}, socket) do
    key = media_target_to_key(target)
    settings = Map.put(socket.assigns.settings, key, "")
    {:noreply, assign(socket, :settings, settings)}
  end

  # Who is saving, for the settings history (`PhoenixKit.Settings.History`).
  # `scope:` makes the save one on this person's behalf: without
  # `settings.security` the registration / default-role keys the form carries
  # as hidden fields are left alone, whatever the client sends.
  defp history_opts(socket) do
    [
      actor_uuid: Actor.uuid(socket),
      source: "settings",
      scope: socket.assigns[:phoenix_kit_current_scope]
    ]
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

  # Every committed settings write is broadcast, including this page's own
  # saves; the page reloads from its own save handler, so the events are
  # accepted and ignored here rather than left to crash the process.
  def handle_info({:setting_changed, _key, _value}, socket) do
    {:noreply, socket}
  end

  def handle_info({:setting_deleted, _key}, socket) do
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

    # Update socket with new settings. Keys the save left alone
    # (`settings.security` ones, for a holder without it) keep their values.
    updated_settings = Map.merge(socket.assigns.saved_settings, updated_settings)
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
      |> put_flash(:info, gettext("Settings updated successfully"))

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

  # Host shown in the browser-tab preview's address bar. Best-effort — the
  # mockup is decorative, so any failure just falls back to a placeholder.
  def site_host do
    case URI.parse(Routes.url("/")).host do
      host when is_binary(host) and host != "" -> host
      _ -> "example.com"
    end
  rescue
    _ -> "example.com"
  end
end
