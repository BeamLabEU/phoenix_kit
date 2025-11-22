defmodule PhoenixKitWeb.Live.Modules.Languages do
  @moduledoc """
  Languages module settings LiveView for PhoenixKit admin panel.

  Provides interface for managing available languages and localization settings.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, session, socket) do
    # Handle locale
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Get current path for navigation
    current_path = get_current_path(socket, session)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load languages configuration
    ml_config = Languages.get_config()
    display_languages = Languages.get_display_languages()
    in_configured_mode = Languages.in_configured_mode?()

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:current_locale, locale)
      |> assign(:page_title, "Languages")
      |> assign(:project_title, project_title)
      |> assign(:ml_enabled, ml_config.enabled)
      |> assign(:languages, display_languages)
      |> assign(:in_configured_mode, in_configured_mode)
      |> assign(:language_count, length(display_languages))
      |> assign(:enabled_count, Enum.count(display_languages, & &1["is_enabled"]))
      |> assign(:default_language, Enum.find(display_languages, & &1["is_default"]))
      |> assign(
        :available_languages_for_selection,
        Languages.get_available_languages_for_selection()
      )
      # Switcher preview settings
      |> assign(:switcher_show_names, true)
      |> assign(:switcher_show_flags, true)
      |> assign(:switcher_goto_home, false)
      |> assign(:switcher_hide_current, false)

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

  def handle_event("toggle_language", %{"code" => code}, socket) do
    # Find the language to toggle
    language = Enum.find(socket.assigns.languages, &(&1["code"] == code))

    if language do
      # Toggle the language enabled state
      new_enabled = !language["is_enabled"]

      result =
        if new_enabled do
          Languages.enable_language(code)
        else
          Languages.disable_language(code)
        end

      case result do
        {:ok, _config} ->
          socket =
            socket
            |> reload_display_languages()
            |> put_flash(
              :info,
              "Language #{language["name"]} #{if new_enabled, do: "enabled", else: "disabled"}"
            )

          {:noreply, socket}

        {:error, reason} when is_binary(reason) ->
          socket = put_flash(socket, :error, reason)
          {:noreply, socket}

        {:error, _changeset} ->
          socket = put_flash(socket, :error, "Failed to update language")
          {:noreply, socket}
      end
    else
      socket = put_flash(socket, :error, "Language not found")
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

  def handle_event("add_language", %{"language_code" => language_code}, socket) do
    case Languages.add_language(language_code) do
      {:ok, _config} ->
        # Get language name for flash message
        predefined_lang = Languages.get_predefined_language(language_code)
        language_name = (predefined_lang && predefined_lang.name) || language_code

        socket =
          socket
          |> reload_display_languages()
          |> assign(
            :available_languages_for_selection,
            Languages.get_available_languages_for_selection()
          )
          |> put_flash(:info, "Language #{language_name} added successfully")

        {:noreply, socket}

      {:error, reason} when is_binary(reason) ->
        socket = put_flash(socket, :error, reason)
        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to add language")
        {:noreply, socket}
    end
  end

  def handle_event("remove_language", %{"code" => code}, socket) do
    language = Enum.find(socket.assigns.languages, &(&1["code"] == code))

    if language do
      case Languages.remove_language(code) do
        {:ok, _config} ->
          socket =
            socket
            |> reload_display_languages()
            |> assign(
              :available_languages_for_selection,
              Languages.get_available_languages_for_selection()
            )
            |> put_flash(:info, "Language #{language["name"]} removed successfully")

          {:noreply, socket}

        {:error, reason} when is_binary(reason) ->
          socket = put_flash(socket, :error, reason)
          {:noreply, socket}

        {:error, _changeset} ->
          socket = put_flash(socket, :error, "Failed to remove language")
          {:noreply, socket}
      end
    else
      socket = put_flash(socket, :error, "Language not found")
      {:noreply, socket}
    end
  end

  def handle_event("move_up", %{"code" => code}, socket) do
    language = Enum.find(socket.assigns.languages, &(&1["code"] == code))

    if language do
      case Languages.move_language_up(code) do
        {:ok, _config} ->
          socket =
            socket
            |> reload_display_languages()
            |> put_flash(:info, "#{language["name"]} moved up")

          {:noreply, socket}

        {:error, reason} when is_binary(reason) ->
          socket = put_flash(socket, :error, reason)
          {:noreply, socket}

        {:error, _changeset} ->
          socket = put_flash(socket, :error, "Failed to move language")
          {:noreply, socket}
      end
    else
      socket = put_flash(socket, :error, "Language not found")
      {:noreply, socket}
    end
  end

  def handle_event("move_down", %{"code" => code}, socket) do
    language = Enum.find(socket.assigns.languages, &(&1["code"] == code))

    if language do
      case Languages.move_language_down(code) do
        {:ok, _config} ->
          socket =
            socket
            |> reload_display_languages()
            |> put_flash(:info, "#{language["name"]} moved down")

          {:noreply, socket}

        {:error, reason} when is_binary(reason) ->
          socket = put_flash(socket, :error, reason)
          {:noreply, socket}

        {:error, _changeset} ->
          socket = put_flash(socket, :error, "Failed to move language")
          {:noreply, socket}
      end
    else
      socket = put_flash(socket, :error, "Language not found")
      {:noreply, socket}
    end
  end

  def handle_event("toggle_switcher_setting", %{"setting" => setting}, socket) do
    setting_atom = String.to_atom(setting)
    current_value = socket.assigns[setting_atom]
    {:noreply, assign(socket, setting_atom, !current_value)}
  end

  defp get_current_path(_socket, _session) do
    # For LanguagesLive, return the settings path
    Routes.path("/admin/settings/languages")
  end

  # Helper function to reload display languages from the Languages module
  defp reload_display_languages(socket, enabled \\ nil) do
    enabled = enabled || Languages.enabled?()
    display_languages = Languages.get_display_languages()
    in_configured_mode = Languages.in_configured_mode?()

    socket
    |> assign(:ml_enabled, enabled)
    |> assign(:languages, display_languages)
    |> assign(:in_configured_mode, in_configured_mode)
    |> assign(:language_count, length(display_languages))
    |> assign(:enabled_count, Enum.count(display_languages, & &1["is_enabled"]))
    |> assign(:default_language, Enum.find(display_languages, & &1["is_default"]))
  end

  # Helper function to generate the language switcher code based on current settings
  defp generate_switcher_code(show_flags, show_names, goto_home, hide_current) do
    flags_line = if show_flags, do: "\n  show_flags={true}", else: ""
    names_line = if show_names, do: "\n  show_names={true}", else: ""
    home_line = if goto_home, do: "\n  goto_home={true}", else: ""
    hide_line = if hide_current, do: "\n  hide_current={true}", else: ""

    """
    <.language_switcher_dropdown
      current_locale={@current_locale}#{flags_line}#{names_line}#{home_line}#{hide_line}
    />
    """
  end

  # Helper function to get language flag emoji
  defp get_language_flag(code) when is_binary(code) do
    case Languages.get_predefined_language(code) do
      %{flag: flag} -> flag
      nil -> "🌐"
    end
  end
end
