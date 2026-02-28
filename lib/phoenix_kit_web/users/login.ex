defmodule PhoenixKitWeb.Users.Login do
  @moduledoc """
  LiveView for user authentication.

  Provides login functionality with support for both traditional password-based
  authentication and magic link login. Tracks anonymous visitor sessions and
  respects system authentication settings.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Presence
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth
  alias PhoenixKit.Utils.Date, as: UtilsDate

  def mount(params, session, socket) do
    case Auth.maybe_redirect_authenticated(socket) do
      {:redirect, socket} ->
        {:ok, socket}

      :cont ->
        # Track anonymous visitor session
        if connected?(socket) do
          session_id = session["live_socket_id"] || generate_session_id()

          Presence.track_anonymous(session_id, %{
            connected_at: UtilsDate.utc_now(),
            ip_address: IpAddress.extract_from_socket(socket),
            user_agent: get_connect_info(socket, :user_agent),
            current_page: Routes.path("/users/log-in")
          })
        end

        # Get project title from settings (with Config fallback)
        project_title = PhoenixKit.Settings.get_project_title()
        allow_registration = Settings.get_boolean_setting("allow_registration", true)
        magic_link_enabled = Settings.get_boolean_setting("magic_link_login_enabled", true)

        # Check if language switcher should be shown
        show_language_switcher =
          Languages.enabled?() and length(Languages.get_enabled_languages()) > 1

        # Support both old :email flash and new :email_or_username flash for backwards compatibility
        email_or_username =
          Phoenix.Flash.get(socket.assigns.flash, :email_or_username) ||
            Phoenix.Flash.get(socket.assigns.flash, :email)

        form = to_form(%{"email_or_username" => email_or_username}, as: "user")

        # Support return_to query param for post-login redirect (e.g., from guest checkout)
        return_to = sanitize_return_to(params["return_to"])

        socket =
          assign(socket,
            form: form,
            project_title: project_title,
            allow_registration: allow_registration,
            magic_link_enabled: magic_link_enabled,
            show_language_switcher: show_language_switcher,
            return_to: return_to
          )

        {:ok, socket, temporary_assigns: [form: form]}
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end

  # Only allow relative paths to prevent open redirect attacks
  defp sanitize_return_to(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      path
    else
      nil
    end
  end

  defp sanitize_return_to(_), do: nil
end
