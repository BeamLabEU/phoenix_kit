defmodule PhoenixKitWeb.Live.Modules.Languages do
  @moduledoc """
  Languages settings LiveView for PhoenixKit admin panel.

  Provides interface for managing available languages and localization settings.

  Languages is core and this page is always reachable; its first card is the site's
  multi-language switch (`toggle_languages`). With the switch off nothing below it is
  shown. Saved configuration is kept, and menus offer no language choices.
  """
  use PhoenixKitWeb, :live_view

  @compile {:no_warn_undefined,
            [
              {PhoenixKit.Modules.Publishing, :enabled?, 0},
              {PhoenixKit.Modules.Publishing, :list_groups, 0},
              {PhoenixKit.Modules.Publishing.ListingCache, :regenerate, 1}
            ]}

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(_params, session, socket) do
    # Attach locale hook for automatic locale handling

    # Get current path for navigation
    current_path = get_current_path(socket, session)

    # Get project title from settings
    project_title = Settings.get_project_title()

    # Load languages configuration
    ml_config = Languages.get_config()
    display_languages = Languages.get_languages()

    # Get ALL languages grouped by continent -> country for display
    grouped_languages = Languages.get_languages_grouped_by_continent()

    # Get enabled language codes and default code
    enabled_codes = get_enabled_codes(display_languages)
    default_code = get_default_code(display_languages)

    # Calculate covered countries
    covered_countries = get_covered_countries(enabled_codes, grouped_languages)

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, gettext("Languages"))
      |> assign(:page_section, gettext("Settings"))
      |> assign(:page_section_path, Routes.path("/admin/settings"))
      |> assign(:project_title, project_title)
      |> assign(:ml_enabled, ml_config.enabled)
      |> assign(:languages, display_languages)
      |> assign(:grouped_languages, grouped_languages)
      |> assign(:enabled_codes, enabled_codes)
      |> assign(:default_code, default_code)
      |> assign(:language_count, length(display_languages))
      |> assign(:enabled_count, length(enabled_codes))
      |> assign(:covered_countries, covered_countries)
      |> assign(:covered_count, length(covered_countries))
      # Search filter
      |> assign(:search_query, "")
      # Reorder mode
      |> assign(:show_reorder, false)
      # Switcher preview settings
      |> assign(:switcher_show_names, true)
      |> assign(:switcher_show_flags, true)
      |> assign(:switcher_goto_home, false)
      |> assign(:switcher_hide_current, false)
      |> assign(:switcher_show_native_names, false)
      # Site-wide URL behavior — primary-language locale-segment toggle.
      |> assign(:default_language_no_prefix, Languages.default_language_no_prefix?())

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @configuration_events ~w(toggle_language_availability set_default reorder_languages toggle_default_language_no_prefix)

  def handle_event(event, params, socket) do
    # An already-open page can outlive another admin turning the switch off.
    # Recheck before writing settings hidden by the current switch state.
    if event in @configuration_events and not Languages.enabled?() do
      {:noreply,
       socket
       |> reload_display_languages()
       |> put_flash(:info, gettext("Multiple languages turned off"))}
    else
      handle_language_event(event, params, socket)
    end
  end

  defp handle_language_event("toggle_reorder", _params, socket) do
    {:noreply, assign(socket, :show_reorder, !socket.assigns.show_reorder)}
  end

  defp handle_language_event("toggle_default_language_no_prefix", _params, socket) do
    new_value = !socket.assigns.default_language_no_prefix

    case Languages.set_default_language_no_prefix(new_value) do
      {:ok, _} ->
        {:noreply, assign(socket, :default_language_no_prefix, new_value)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update URL behavior setting"))}
    end
  end

  defp handle_language_event("reorder_languages", %{"ordered_ids" => ordered_codes}, socket) do
    case Languages.reorder_languages(ordered_codes) do
      {:ok, _} ->
        socket = reload_display_languages(socket, true)
        {:noreply, put_flash(socket, :info, "Language order updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to reorder languages")}
    end
  end

  defp handle_language_event("toggle_languages", _params, socket) do
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
        # Regenerate all publishing group caches since language availability changed
        regenerate_all_group_caches()

        # Reload configuration to get fresh data
        socket =
          socket
          |> reload_display_languages(new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: gettext("Multiple languages turned on"),
              else: gettext("Multiple languages turned off")
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to update languages"))
        {:noreply, socket}
    end
  end

  defp handle_language_event("set_default", %{"code" => code}, socket) do
    case Languages.set_default_language(code) do
      {:ok, _config} ->
        language = Languages.get_language(code)

        socket =
          socket
          |> reload_display_languages()
          |> put_flash(:info, "#{language.name} set as default language")

        {:noreply, socket}

      {:error, reason} when is_binary(reason) ->
        socket = put_flash(socket, :error, reason)
        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to set default language")
        {:noreply, socket}
    end
  end

  @toggleable_settings ~w(switcher_show_names switcher_show_flags switcher_goto_home switcher_hide_current switcher_show_native_names)

  defp handle_language_event("toggle_switcher_setting", %{"setting" => setting}, socket)
       when setting in @toggleable_settings do
    setting_atom = String.to_existing_atom(setting)
    current_value = socket.assigns[setting_atom]
    {:noreply, assign(socket, setting_atom, !current_value)}
  end

  defp handle_language_event("toggle_switcher_setting", _params, socket) do
    {:noreply, socket}
  end

  defp handle_language_event("search_countries", %{"value" => query}, socket) do
    {:noreply, assign(socket, :search_query, query)}
  end

  defp handle_language_event("toggle_language_availability", %{"code" => code}, socket) do
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
        # Regenerate all publishing group caches since language availability changed
        regenerate_all_group_caches()

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
    display_languages = Languages.get_languages()
    grouped_languages = Languages.get_languages_grouped_by_continent()
    enabled_codes = get_enabled_codes(display_languages)
    default_code = get_default_code(display_languages)
    covered_countries = get_covered_countries(enabled_codes, grouped_languages)

    socket
    |> assign(:ml_enabled, enabled)
    |> assign(:languages, display_languages)
    |> assign(:grouped_languages, grouped_languages)
    |> assign(:enabled_codes, enabled_codes)
    |> assign(:default_code, default_code)
    |> assign(:language_count, length(display_languages))
    |> assign(:enabled_count, length(enabled_codes))
    |> assign(:covered_countries, covered_countries)
    |> assign(:covered_count, length(covered_countries))
  end

  # Helper function to generate the language switcher code based on current settings
  defp generate_switcher_code(show_flags, show_names, goto_home, hide_current, show_native_names) do
    flags_line = "\n  show_flags={#{show_flags}}"
    names_line = "\n  show_names={#{show_names}}"
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
    |> Enum.filter(& &1.is_enabled)
    |> Enum.map(& &1.code)
  end

  # Get the default language code
  defp get_default_code(display_languages) do
    case Enum.find(display_languages, & &1.is_default) do
      %{code: code} -> code
      _ -> nil
    end
  end

  # Count enabled languages in a list
  defp count_enabled(languages, enabled_codes) do
    Enum.count(languages, fn lang -> lang.code in enabled_codes end)
  end

  # Count countries in a continent that have ALL their languages enabled (covered)
  defp count_covered_countries_in_continent(countries, enabled_codes) do
    Enum.count(countries, fn {_country, _flag, languages} ->
      languages != [] and Enum.all?(languages, fn lang -> lang.code in enabled_codes end)
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

  # Get list of countries that have ALL their languages enabled
  defp get_covered_countries(enabled_codes, grouped_languages) do
    grouped_languages
    |> Enum.flat_map(fn {_continent, countries} ->
      countries
      |> Enum.filter(fn {_country, _flag, languages} ->
        # Country is covered only if ALL its languages are enabled
        languages != [] and Enum.all?(languages, fn lang -> lang.code in enabled_codes end)
      end)
      |> Enum.map(fn {country, flag, _langs} -> {country, flag} end)
    end)
    |> Enum.uniq()
    |> Enum.sort_by(fn {country, _} -> country end)
  end

  # Regenerate listing caches for all publishing groups when language settings change.
  # Publishing may be an external package — only call if available.
  defp regenerate_all_group_caches do
    publishing = PhoenixKit.Modules.Publishing
    cache = PhoenixKit.Modules.Publishing.ListingCache

    if Code.ensure_loaded?(publishing) and function_exported?(publishing, :enabled?, 0) and
         publishing.enabled?() do
      if Code.ensure_loaded?(cache) and function_exported?(cache, :regenerate, 1) do
        publishing.list_groups()
        |> Enum.each(fn group -> cache.regenerate(group["slug"]) end)
      end
    end
  rescue
    _ -> :ok
  end
end
