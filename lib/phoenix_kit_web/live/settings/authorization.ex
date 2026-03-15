defmodule PhoenixKitWeb.Live.Settings.Authorization do
  @moduledoc """
  Authorization settings management LiveView for PhoenixKit.

  Manages login page branding and authentication methods including
  magic links and OAuth provider configuration.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.OAuthConfig

  require Logger

  def mount(_params, _session, socket) do
    current_settings = Settings.list_all_settings()
    defaults = Settings.get_defaults()
    setting_options = Settings.get_setting_options()

    merged_settings = Map.merge(defaults, current_settings)
    changeset = Settings.change_settings(merged_settings)

    socket =
      socket
      |> assign(:page_title, "Authorization Settings")
      |> assign(:settings, merged_settings)
      |> assign(:saved_settings, merged_settings)
      |> assign(:setting_options, setting_options)
      |> assign(:changeset, changeset)
      |> assign(:saving, false)
      |> assign(
        :project_title,
        merged_settings["project_title"] || PhoenixKit.Config.get(:project_title, "PhoenixKit")
      )
      |> assign(:show_media_selector, false)
      |> assign(:media_selection_target, nil)

    {:ok, socket}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("validate_settings", %{"settings" => settings_params}, socket) do
    changeset = Settings.validate_settings(settings_params)

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
        OAuthConfig.configure_providers()

        changeset = Settings.change_settings(updated_settings)

        socket =
          socket
          |> assign(:settings, updated_settings)
          |> assign(:saved_settings, updated_settings)
          |> assign(:changeset, changeset)
          |> assign(:saving, false)
          |> put_flash(:info, "Authorization settings updated successfully")

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

  def handle_event("test_oauth", %{"provider" => provider}, socket) do
    provider_atom = String.to_existing_atom(provider)

    case OAuthConfig.test_connection(provider_atom) do
      {:ok, message} ->
        {:noreply, put_flash(socket, :info, message)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("reload_oauth_config", _params, socket) do
    OAuthConfig.configure_providers()
    {:noreply, put_flash(socket, :info, "OAuth configuration reloaded from database")}
  end

  def handle_event("open_media_selector", %{"target" => target}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, true)
     |> assign(:media_selection_target, String.to_existing_atom(target))}
  end

  def handle_event("clear_branding_image", %{"target" => target}, socket) do
    key =
      case target do
        "logo" -> "auth_logo_file_uuid"
        "background" -> "auth_background_image_file_uuid"
        "background_mobile" -> "auth_background_image_mobile_file_uuid"
      end

    settings = Map.put(socket.assigns.settings, key, "")
    {:noreply, assign(socket, :settings, settings)}
  end

  ## Media selector callbacks

  def handle_info({:media_selected, file_uuids}, socket) do
    file_uuid = List.first(file_uuids) || ""

    key =
      case socket.assigns.media_selection_target do
        :logo -> "auth_logo_file_uuid"
        :background -> "auth_background_image_file_uuid"
        :background_mobile -> "auth_background_image_mobile_file_uuid"
      end

    settings = Map.put(socket.assigns.settings, key, file_uuid)

    {:noreply,
     socket
     |> assign(:settings, settings)
     |> assign(:show_media_selector, false)
     |> assign(:media_selection_target, nil)}
  end

  def handle_info({:media_selector_closed}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, false)
     |> assign(:media_selection_target, nil)}
  end

  # Helper functions

  defp format_error_message(%Ecto.Changeset{} = changeset) do
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

  def signed_preview_url(file_uuid, variant) do
    URLSigner.signed_url(file_uuid, variant)
  end

  def get_oauth_callback_url(settings, provider) do
    site_url = settings["site_url"] || "https://example.com"
    url_prefix = PhoenixKit.Config.get_url_prefix()

    "#{site_url}#{url_prefix}/users/auth/#{provider}/callback"
  end
end
