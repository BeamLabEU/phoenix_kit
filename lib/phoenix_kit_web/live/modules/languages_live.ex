defmodule PhoenixKitWeb.Live.Modules.LanguagesLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Module.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(_params, session, socket) do
    # Get current path for navigation
    current_path = get_current_path(socket, session)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load languages configuration
    ml_config = Languages.get_config()

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Languages")
      |> assign(:project_title, project_title)
      |> assign(:ml_enabled, ml_config.enabled)
      |> assign(:languages, ml_config.languages)
      |> assign(:language_count, ml_config.language_count)
      |> assign(:enabled_count, ml_config.enabled_count)
      |> assign(:default_language, ml_config.default_language)
      |> assign(
        :available_languages_for_selection,
        Languages.get_available_languages_for_selection()
      )

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
        ml_config = Languages.get_config()

        socket =
          socket
          |> assign(:ml_enabled, new_enabled)
          |> assign(:languages, ml_config.languages)
          |> assign(:language_count, ml_config.language_count)
          |> assign(:enabled_count, ml_config.enabled_count)
          |> assign(:default_language, ml_config.default_language)
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
          # Reload configuration
          ml_config = Languages.get_config()

          socket =
            socket
            |> assign(:languages, ml_config.languages)
            |> assign(:enabled_count, ml_config.enabled_count)
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
        # Reload configuration
        ml_config = Languages.get_config()
        language = Enum.find(ml_config.languages, &(&1["code"] == code))

        socket =
          socket
          |> assign(:languages, ml_config.languages)
          |> assign(:default_language, ml_config.default_language)
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
        # Reload configuration
        ml_config = Languages.get_config()

        # Get language name for flash message
        predefined_lang = Languages.get_predefined_language(language_code)
        language_name = (predefined_lang && predefined_lang.name) || language_code

        socket =
          socket
          |> assign(:languages, ml_config.languages)
          |> assign(:language_count, ml_config.language_count)
          |> assign(:enabled_count, ml_config.enabled_count)
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
          # Reload configuration
          ml_config = Languages.get_config()

          socket =
            socket
            |> assign(:languages, ml_config.languages)
            |> assign(:language_count, ml_config.language_count)
            |> assign(:enabled_count, ml_config.enabled_count)
            |> assign(:default_language, ml_config.default_language)
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
          # Reload configuration to get updated positions
          ml_config = Languages.get_config()

          socket =
            socket
            |> assign(:languages, ml_config.languages)
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
          # Reload configuration to get updated positions
          ml_config = Languages.get_config()

          socket =
            socket
            |> assign(:languages, ml_config.languages)
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

  defp get_current_path(_socket, _session) do
    # For LanguagesLive, return the settings path
    Routes.path("/admin/settings/languages")
  end
end
