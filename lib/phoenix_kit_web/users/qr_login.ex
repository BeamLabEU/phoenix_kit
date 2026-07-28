defmodule PhoenixKitWeb.Users.QrLogin do
  @moduledoc """
  Desktop "scan to sign in" page.

  A signed-out browser lands here, is shown a QR code encoding the phone
  confirm URL, and waits. When the user's phone approves the sign-in,
  `Keyfob.Live` receives the one-time login token over PubSub and this
  LiveView redirects to the completion controller, which establishes the
  session.

  Redirects already-authenticated users away, and redirects everyone away
  when the `qr_login_enabled` setting is off.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.QrLogin, as: QrLoginContext
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth

  # How long a QR code is valid before the panel offers a fresh one. Kept in
  # sync with the request TTL passed to keyfob so the visible expiry matches
  # the server-side one.
  @request_ttl_ms :timer.minutes(2)

  def mount(params, _session, socket) do
    case Auth.maybe_redirect_authenticated(socket) do
      {:redirect, socket} ->
        {:ok, socket}

      :cont ->
        # `return_to` is a post-login destination the browser carries through
        # the whole handoff (mint → approve → finish); sanitized against open
        # redirects up front. remember_me starts at the site default and is
        # toggled on this page.
        socket = assign(socket, :return_to, sanitize_return_to(params["return_to"]))

        cond do
          not QrLoginContext.enabled?() ->
            {:ok,
             socket
             |> put_flash(:error, gettext("QR code sign-in is not available."))
             |> redirect(to: Routes.path("/users/log-in"))}

          connected?(socket) ->
            case rate_limit_mint(socket) do
              :ok ->
                socket =
                  Keyfob.Live.init_panel(socket,
                    confirm_url: &confirm_url/1,
                    meta: QrLoginContext.device_meta(socket),
                    pubsub: QrLoginContext.pubsub(),
                    ttl_ms: @request_ttl_ms
                  )

                {:ok, socket |> assign_common() |> schedule_expiry()}

              {:error, :rate_limit_exceeded} ->
                {:ok,
                 socket
                 |> put_flash(:error, gettext("Too many attempts. Please try again shortly."))
                 |> redirect(to: Routes.path("/users/log-in"))}
            end

          true ->
            # Dead render: the request is minted on connect (so it isn't
            # created twice), so there's nothing to show yet.
            {:ok, socket |> assign(:keyfob, nil) |> assign_common()}
        end
    end
  end

  # Forward keyfob's PubSub message; on approval, hand off to completion.
  def handle_info({:keyfob, _token, _payload} = msg, socket),
    do: Keyfob.Live.handle_message(msg, socket, on_approved: &complete/2)

  # The code's TTL lapsed. Only flip to :expired if we're still waiting on
  # *this* code — a refresh (new token) or an approval already moved on.
  def handle_info({:keyfob_expire, token}, socket) do
    case socket.assigns[:keyfob] do
      %{state: :waiting, token: ^token} -> {:noreply, Keyfob.Live.expire(socket)}
      _ -> {:noreply, socket}
    end
  end

  # Refresh button on an expired code — mint a new one and re-arm the timer.
  def handle_event("keyfob_refresh", _params, socket),
    do: {:noreply, socket |> Keyfob.Live.refresh() |> schedule_expiry()}

  # "Keep me logged in" checkbox. A daisyUI checkbox in a phx-change form
  # sends "on" when ticked and omits the key when unticked.
  def handle_event("set_remember", params, socket),
    do: {:noreply, assign(socket, :remember_me, params["remember_me"] == "on")}

  # On approval, hand off to the completion controller carrying the browser's
  # remember_me / return_to choice (the login token is minted on the phone,
  # but these belong to the browser being signed in).
  defp complete(socket, login_token) do
    query =
      [
        {"remember_me", if(socket.assigns[:remember_me], do: "true")},
        {"return_to", socket.assigns[:return_to]}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    base = Routes.path("/users/qr-login/finish/#{login_token}")
    to = if query == [], do: base, else: base <> "?" <> URI.encode_query(query)
    {:noreply, redirect(socket, to: to)}
  end

  defp sanitize_return_to(path) do
    if Routes.local_path?(path), do: path, else: nil
  end

  # Every connect to this public, pre-auth page mints a live keyfob request
  # (an ETS entry) — guard the mint itself, not just the page render.
  # extract_from_socket/1 always returns a string ("unknown" when peer_data
  # is unavailable), so unknown-IP connects simply share one rate-limit
  # bucket rather than bypassing the check.
  defp rate_limit_mint(socket) do
    socket
    |> IpAddress.extract_from_socket()
    |> RateLimiter.check_qr_login_rate_limit()
  end

  defp schedule_expiry(socket) do
    case socket.assigns[:keyfob] do
      %{token: token} ->
        Process.send_after(self(), {:keyfob_expire, token}, @request_ttl_ms)
        socket

      _ ->
        socket
    end
  end

  # The URL encoded in the QR — must be absolute so a phone camera can open
  # it. Points at the authenticated phone-confirm LiveView.
  defp confirm_url(token), do: Routes.url("/users/qr-login/scan/#{token}")

  defp assign_common(socket) do
    socket
    |> assign(:project_title, PhoenixKit.Settings.get_project_title())
    |> assign_new(:remember_me_available, fn -> Auth.remember_me_enabled?() end)
    |> assign_new(:remember_me, fn -> Auth.remember_me_default?() end)
  end

  defp panel_labels do
    %{
      waiting:
        gettext(
          "Scan this code with your phone's camera, then approve the sign-in on your phone."
        ),
      approved: gettext("Approved — signing you in…"),
      denied: gettext("The sign-in request was denied."),
      expired: gettext("This code expired."),
      refresh: gettext("Show a new code")
    }
  end
end
