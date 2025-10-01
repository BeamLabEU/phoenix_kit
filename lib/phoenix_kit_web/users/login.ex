defmodule PhoenixKitWeb.Users.Login do
  @moduledoc """
  LiveView for user authentication.

  Provides login functionality with support for both traditional password-based
  authentication and magic link login. Tracks anonymous visitor sessions and
  respects system authentication settings.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Presence
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(_params, session, socket) do
    # Track anonymous visitor session
    if connected?(socket) do
      session_id = session["live_socket_id"] || generate_session_id()

      Presence.track_anonymous(session_id, %{
        connected_at: DateTime.utc_now(),
        ip_address: get_connect_info(socket, :peer_data) |> extract_ip_address(),
        user_agent: get_connect_info(socket, :user_agent),
        current_page: Routes.path("/users/log-in")
      })
    end

    # Get project title and registration setting from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    allow_registration = Settings.get_boolean_setting("allow_registration", true)
    magic_link_enabled = Settings.get_boolean_setting("magic_link_login_enabled", true)

    email = Phoenix.Flash.get(socket.assigns.flash, :email)
    form = to_form(%{"email" => email}, as: "user")

    socket =
      assign(socket,
        form: form,
        project_title: project_title,
        allow_registration: allow_registration,
        magic_link_enabled: magic_link_enabled
      )

    {:ok, socket, temporary_assigns: [form: form]}
  end

  defp show_dev_notice? do
    case Application.get_env(:phoenix_kit, PhoenixKit.Mailer)[:adapter] do
      Swoosh.Adapters.Local -> true
      _ -> false
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end

  defp extract_ip_address(nil), do: "unknown"
  defp extract_ip_address(%{address: {a, b, c, d}}), do: "#{a}.#{b}.#{c}.#{d}"
  defp extract_ip_address(%{address: address}), do: to_string(address)
  defp extract_ip_address(_), do: "unknown"
end
