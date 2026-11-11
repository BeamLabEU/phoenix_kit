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
  alias PhoenixKit.Users.Passkeys
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth
  alias PhoenixKitWeb.Users.AuthSEO

  def mount(params, session, socket) do
    socket = assign(socket, :page_title, gettext("Log in"))

    case Auth.maybe_redirect_authenticated(socket) do
      {:redirect, socket} ->
        {:ok, socket}

      :cont ->
        # Track anonymous visitor session
        socket =
          assign(socket,
            # `connect_info` is readable in mount only; the passkey rate limit needs it.
            client_ip: if(connected?(socket), do: IpAddress.extract_from_socket(socket)),
            passkey_challenge: nil
          )

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
        qr_login_enabled = Settings.get_boolean_setting("qr_login_enabled", false)
        passkey_enabled = Passkeys.enabled?()

        # Support both old :email flash and new :email_or_username flash for backwards compatibility
        email_or_username =
          Phoenix.Flash.get(socket.assigns.flash, :email_or_username) ||
            Phoenix.Flash.get(socket.assigns.flash, :email)

        form = to_form(%{"email_or_username" => email_or_username}, as: "user")

        # Support return_to query param for post-login redirect (e.g., from guest checkout)
        return_to = sanitize_return_to(params["return_to"])

        seo = AuthSEO.seo_assigns("/users/log-in")

        socket =
          assign(socket,
            form: form,
            project_title: project_title,
            allow_registration: allow_registration,
            magic_link_enabled: magic_link_enabled,
            qr_login_enabled: qr_login_enabled,
            passkey_enabled: passkey_enabled,
            remember_me_available: Auth.remember_me_enabled?(),
            remember_me: Auth.remember_me_default?(),
            return_to: return_to,
            canonical_url: seo.canonical_url,
            hreflang_links: seo.hreflang_links
          )

        {:ok, socket, temporary_assigns: [form: form]}
    end
  end

  # ── Passkeys ──────────────────────────────────────────────────────
  #
  # The challenge lives in this process only (`passkey_challenge`); the browser
  # gets its bytes and answers with a signature over them. Each attempt asks for
  # a fresh one, and an answer clears it whatever the result, so nothing can be
  # replayed. A success hands over to `PasskeyLoginComplete` through a one-time
  # token, the way QR sign-in does: only a controller can write the session.

  def handle_event("passkey_options", _params, socket) do
    if Passkeys.enabled?() do
      {challenge, options} = Passkeys.authentication_options()
      {:reply, %{options: options}, assign(socket, :passkey_challenge, challenge)}
    else
      {:reply, %{}, socket}
    end
  end

  def handle_event("passkey_sign_in", params, socket) do
    challenge = socket.assigns.passkey_challenge
    socket = assign(socket, :passkey_challenge, nil)

    # Rate limit first, before any lookup, as every public sign-in endpoint does.
    with :ok <- passkey_rate_limit(socket.assigns.client_ip),
         %Wax.Challenge{} <- challenge,
         {:ok, user} <- Passkeys.authenticate(challenge, params),
         {:ok, token} <- Passkeys.mint_login_token(user) do
      query =
        URI.encode_query(
          Enum.reject(
            [
              {"remember_me", if(params["remember_me"] == "true", do: "true")},
              {"return_to", socket.assigns.return_to}
            ],
            fn {_k, v} -> is_nil(v) end
          )
        )

      path = Routes.path("/users/passkey/finish/#{token}")
      {:noreply, redirect(socket, to: if(query == "", do: path, else: path <> "?" <> query))}
    else
      {:error, :rate_limit_exceeded} ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many attempts. Wait a minute and try again."))}

      _ ->
        {:noreply, put_flash(socket, :error, passkey_failed_message())}
    end
  end

  def handle_event("passkey_failed", _params, socket) do
    {:noreply, put_flash(socket, :error, passkey_failed_message())}
  end

  defp passkey_rate_limit(ip) when is_binary(ip),
    do: RateLimiter.check_passkey_login_rate_limit(ip)

  defp passkey_rate_limit(_ip), do: RateLimiter.check_passkey_login_rate_limit("unknown")

  defp passkey_failed_message do
    gettext("That passkey did not work. Try again, or sign in another way.")
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end

  # Only allow relative paths to prevent open redirect attacks
  defp sanitize_return_to(path) do
    if Routes.local_path?(path), do: path, else: nil
  end
end
