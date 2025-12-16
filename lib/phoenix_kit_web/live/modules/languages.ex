defmodule PhoenixKitWeb.Live.Modules.Languages do
  @moduledoc """
  Languages module settings LiveView for PhoenixKit admin panel.

  Provides interface for managing available languages and localization settings.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(_params, session, socket) do
    # Attach locale hook for automatic locale handling

    # Get current path for navigation
    current_path = get_current_path(socket, session)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load languages configuration
    ml_config = Languages.get_config()
    display_languages = Languages.get_display_languages()

    # Get ALL languages grouped by continent -> country for display
    grouped_languages = Languages.get_languages_grouped_by_continent()

    # Get enabled language codes and default code
    enabled_codes = get_enabled_codes(display_languages)
    default_code = get_default_code(display_languages)

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Languages")
      |> assign(:project_title, project_title)
      |> assign(:ml_enabled, ml_config.enabled)
      |> assign(:languages, display_languages)
      |> assign(:grouped_languages, grouped_languages)
      |> assign(:enabled_codes, enabled_codes)
      |> assign(:default_code, default_code)
      |> assign(:language_count, length(display_languages))
      |> assign(:enabled_count, length(enabled_codes))
      # Search filter
      |> assign(:search_query, "")
      # Switcher preview settings
      |> assign(:switcher_show_names, true)
      |> assign(:switcher_show_flags, true)
      |> assign(:switcher_goto_home, false)
      |> assign(:switcher_hide_current, false)
      |> assign(:switcher_show_native_names, false)

    {:ok, socket}
  end

  def handle_event("toggle_languages", _params, socket) do
    # Toggle languages
    new_enabled = !socket.assigns.ml_enabled

    result =
      if new_enabled do
        Languages.enable_system()
      else
        Languages.disable_system()
      end

    case result do
      {:ok, _} ->
        # Reload configuration to get fresh data
        socket =
          socket
          |> reload_display_languages(new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Languages enabled with default English",
              else: "Languages disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update languages")
        {:noreply, socket}
    end
  end

  def handle_event("set_default", %{"code" => code}, socket) do
    case Languages.set_default_language(code) do
      {:ok, _config} ->
        language = Enum.find(socket.assigns.languages, &(&1["code"] == code))

        socket =
          socket
          |> reload_display_languages()
          |> put_flash(:info, "#{language["name"]} set as default language")

        {:noreply, socket}

      {:error, reason} when is_binary(reason) ->
        socket = put_flash(socket, :error, reason)
        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to set default language")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_switcher_setting", %{"setting" => setting}, socket) do
    setting_atom = String.to_atom(setting)
    current_value = socket.assigns[setting_atom]
    {:noreply, assign(socket, setting_atom, !current_value)}
  end

  def handle_event("search_countries", %{"value" => query}, socket) do
    {:noreply, assign(socket, :search_query, query)}
  end

  def handle_event("toggle_language_availability", %{"code" => code}, socket) do
    # Check if language is currently enabled
    is_enabled = code in socket.assigns.enabled_codes

    result =
      if is_enabled do
        # Disable the language (remove from config)
        Languages.remove_language(code)
      else
        # Enable the language (add to config)
        Languages.add_language(code)
      end

    case result do
      {:ok, _config} ->
        predefined_lang = Languages.get_predefined_language(code)
        language_name = (predefined_lang && predefined_lang.name) || code
        action = if is_enabled, do: "disabled", else: "enabled"

        socket =
          socket
          |> reload_display_languages()
          |> put_flash(:info, "#{language_name} #{action}")

        {:noreply, socket}

      {:error, reason} when is_binary(reason) ->
        socket = put_flash(socket, :error, reason)
        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update language")
        {:noreply, socket}
    end
  end

  defp get_current_path(_socket, _session) do
    # For LanguagesLive, return the settings path
    Routes.path("/admin/settings/languages")
  end

  # Helper function to reload display languages from the Languages module
  defp reload_display_languages(socket, enabled \\ nil) do
    enabled = enabled || Languages.enabled?()
    display_languages = Languages.get_display_languages()
    grouped_languages = Languages.get_languages_grouped_by_continent()
    enabled_codes = get_enabled_codes(display_languages)
    default_code = get_default_code(display_languages)

    # Sync the admin_languages setting so the admin navbar updates too
    sync_admin_languages(display_languages)

    socket
    |> assign(:ml_enabled, enabled)
    |> assign(:languages, display_languages)
    |> assign(:grouped_languages, grouped_languages)
    |> assign(:enabled_codes, enabled_codes)
    |> assign(:default_code, default_code)
    |> assign(:language_count, length(display_languages))
    |> assign(:enabled_count, length(enabled_codes))
  end

  # Sync the admin_languages setting with the current display languages
  defp sync_admin_languages(display_languages) do
    enabled_codes =
      display_languages
      |> Enum.filter(& &1["is_enabled"])
      |> Enum.map(& &1["code"])

    Settings.update_setting("admin_languages", Jason.encode!(enabled_codes))
  end

  # Helper function to generate the language switcher code based on current settings
  defp generate_switcher_code(show_flags, show_names, goto_home, hide_current, show_native_names) do
    flags_line = if show_flags, do: "\n  show_flags={true}", else: ""
    names_line = if show_names, do: "\n  show_names={true}", else: ""
    home_line = if goto_home, do: "\n  goto_home={true}", else: ""
    hide_line = if hide_current, do: "\n  hide_current={true}", else: ""
    native_names_line = if show_native_names, do: "\n  show_native_names={true}", else: ""

    """
    <.language_switcher_dropdown
      current_locale={@current_locale}#{flags_line}#{names_line}#{native_names_line}#{home_line}#{hide_line}
    />
    """
  end

  # Get list of enabled language codes from display languages
  defp get_enabled_codes(display_languages) do
    display_languages
    |> Enum.filter(& &1["is_enabled"])
    |> Enum.map(& &1["code"])
  end

  # Get the default language code
  defp get_default_code(display_languages) do
    case Enum.find(display_languages, & &1["is_default"]) do
      %{"code" => code} -> code
      _ -> nil
    end
  end

  # Count enabled languages in a list
  defp count_enabled(languages, enabled_codes) do
    Enum.count(languages, fn lang -> lang.code in enabled_codes end)
  end

  # Count enabled languages across all countries in a continent
  defp count_enabled_in_continent(countries, enabled_codes) do
    Enum.reduce(countries, 0, fn {_country, _flag, languages}, acc ->
      acc + count_enabled(languages, enabled_codes)
    end)
  end

  # Filter grouped languages by search query (continent -> country -> languages structure)
  defp filter_grouped_languages(grouped_languages, ""), do: grouped_languages
  defp filter_grouped_languages(grouped_languages, nil), do: grouped_languages

  defp filter_grouped_languages(grouped_languages, query) do
    query_downcase = String.downcase(query)

    grouped_languages
    |> Enum.map(fn {continent, countries} ->
      filtered_countries =
        Enum.filter(countries, fn {country, _flag, languages} ->
          # Match country name or any language in the group
          String.contains?(String.downcase(country), query_downcase) or
            Enum.any?(languages, fn lang ->
              String.contains?(String.downcase(lang.name), query_downcase) or
                String.contains?(String.downcase(lang.native), query_downcase) or
                String.contains?(String.downcase(lang.code), query_downcase)
            end)
        end)

      {continent, filtered_countries}
    end)
    |> Enum.reject(fn {_continent, countries} -> countries == [] end)
  end
end
