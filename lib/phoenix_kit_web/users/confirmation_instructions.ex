defmodule PhoenixKitWeb.Users.ConfirmationInstructions do
  @moduledoc """
  LiveView for resending email confirmation instructions.

  Allows users to request a new confirmation email if they didn't receive
  the original or if the link expired. Only sends if the account exists
  and is not already confirmed.

  This page is also where the authentication gates park logged-in users
  whose email is not yet confirmed (when `require_email_confirmation` is
  on), so it moves them along as soon as confirmation happens:

  - On mount, an already-confirmed user is redirected onward immediately —
    covers a confirmation done elsewhere (or directly in the DB) followed
    by a refresh, since the user is reloaded from the DB on every mount.
  - While parked, the LiveView listens on this user's own confirmation topic
    for `{:user_confirmed, user}` (broadcast by both the email-link flow and
    the admin confirm action) and redirects onward live, no refresh needed —
    e.g. when the user clicks the emailed link in another tab. It is a
    per-user topic, not the site-wide admin users feed, so a parked
    non-admin never receives other users' structs.
  - A parked user can also fix a typo'd address instead of only resending to
    it: "Wrong email?" reveals a bare new-address form — no password, unlike
    Profile Settings' confirmed-user change-email flow, because there is no
    live/confirmed account yet for a hijacked session to protect (see
    `Auth.apply_unconfirmed_user_email/2`). The emailed link points
    at `PhoenixKitWeb.Users.ConfirmEmailChange`
    (`/users/confirm/change-email/:token`), NOT the normal
    `/profile/settings/confirm-email/:token` landing page — that one sits
    behind the authenticated-AND-confirmed live_session, which an
    unconfirmed user fixing their email could never pass. Confirming the
    *new* address there changes the account's email AND confirms it in one
    step (`Auth.update_user_email/2` runs `confirm_changeset` either way),
    so there is no separate "now confirm again" round trip.

  "Onward" is `?return_to=` (stashed by the gate that parked them), then
  the session's `user_return_to`, then the `after_login_path` setting.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.BotCheck

  def mount(params, session, socket) do
    socket = assign(socket, :page_title, gettext("Resend confirmation"))

    user = socket.assigns[:phoenix_kit_current_user]
    destination = resolve_destination(params, session, socket)

    # Connect info is readable during mount and nowhere else, so the address
    # the per-IP bucket needs at submit time has to be captured here.
    socket = assign(socket, :ip_address, IpAddress.client_address_from_socket(socket))

    cond do
      user && user.confirmed_at ->
        {:ok, redirect(socket, to: destination)}

      is_nil(user) ->
        {:ok,
         socket
         |> assign(form: to_form(%{"email" => ""}, as: "user"))
         |> assign(awaiting_confirmation?: false)
         |> assign(destination: destination)}

      true ->
        # Subscribe FIRST, then re-read: a confirmation committed between the
        # on_mount user load and the subscribe would otherwise be missed, and
        # the page would sit there forever despite promising to continue
        # automatically. Re-reading after subscribing closes that window —
        # either the re-read sees it, or the broadcast reaches us.
        if connected?(socket), do: Events.subscribe_to_user_confirmation(user.uuid)

        if connected?(socket) and confirmed_since_mount?(user) do
          {:ok, redirect(socket, to: destination)}
        else
          {:ok,
           socket
           |> assign(form: to_form(%{"email" => user.email}, as: "user"))
           |> assign(awaiting_confirmation?: true)
           |> assign(destination: destination)
           |> assign(change_email?: false)
           |> assign(email_form: to_form(Auth.change_user_email(user), as: "email_change"))
           |> assign(email_change_requires_password?: email_change_requires_password?())
           |> assign(email_form_current_password: nil)
           |> assign(confirmation_sent_at: Auth.get_last_confirmation_sent_at(user))}
        end
    end
  end

  defp confirmed_since_mount?(user) do
    case Auth.get_user(user.uuid) do
      %{confirmed_at: confirmed_at} -> not is_nil(confirmed_at)
      _ -> false
    end
  end

  def handle_event("send_instructions", %{"user" => %{"email" => _}} = params, socket) do
    case BotCheck.run(socket, params, socket.assigns[:ip_address]) do
      {:ok, socket} -> send_instructions(params, socket)
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("toggle_change_email", _params, socket) do
    if socket.assigns.awaiting_confirmation? do
      {:noreply, update(socket, :change_email?, &(!&1))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate_email_change", params, socket) do
    if socket.assigns.awaiting_confirmation? do
      {:noreply, do_validate_email_change(params, socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_email", params, socket) do
    if socket.assigns.awaiting_confirmation? do
      {:noreply, do_update_email(params, socket)}
    else
      {:noreply, socket}
    end
  end

  defp send_instructions(%{"user" => %{"email" => submitted_email}}, socket) do
    # A parked visitor is already authenticated — resend to THEIR account,
    # never whatever the (still-editable) form field currently holds. Without
    # this, a logged-in unconfirmed user could edit the pre-filled field to
    # probe whether an arbitrary address exists, and get an honest answer
    # back (see below) instead of the anonymous form's deliberately vague one.
    email =
      if socket.assigns.awaiting_confirmation? do
        socket.assigns.phoenix_kit_current_user.email
      else
        submitted_email
      end

    # Throttle BEFORE the lookup and answer identically either way. This form
    # is public: only an existing unconfirmed account does work (insert a token,
    # send mail), so an unthrottled endpoint is both a targeted mail-flood
    # vector and a timing oracle for which addresses are registered.
    result =
      with :ok <-
             RateLimiter.check_confirmation_resend_rate_limit(
               email,
               socket.assigns[:ip_address]
             ),
           %{} = user <- Auth.get_user_by_email(email) do
        Auth.deliver_user_confirmation_instructions(
          user,
          &Routes.url("/users/confirm/#{&1}"),
          locale: socket.assigns[:current_locale]
        )
      end

    socket = flash_send_result(socket, result, email)

    # A parked (logged-in, unconfirmed) user stays here so the live
    # auto-advance can fire once they click the emailed link; anonymous
    # visitors are sent on to the resolved destination.
    if socket.assigns.awaiting_confirmation? do
      sent_at =
        Auth.get_last_confirmation_sent_at(socket.assigns.phoenix_kit_current_user)

      {:noreply, assign(socket, confirmation_sent_at: sent_at)}
    else
      {:noreply, redirect(socket, to: socket.assigns.destination)}
    end
  end

  defp do_validate_email_change(%{"email_change" => user_params} = params, socket) do
    email_form =
      socket.assigns.phoenix_kit_current_user
      |> Auth.change_user_email(user_params)
      |> Map.put(:action, :validate)
      |> to_form(as: "email_change")

    socket
    |> assign(email_form: email_form)
    |> assign(email_form_current_password: params["current_password"])
  end

  defp do_update_email(%{"email_change" => user_params} = params, socket) do
    user = socket.assigns.phoenix_kit_current_user

    case apply_email_change(socket, user, params["current_password"], user_params) do
      {:ok, applied_user} ->
        Auth.deliver_user_update_email_instructions(
          applied_user,
          user.email,
          &Routes.url("/users/confirm/change-email/#{&1}"),
          locale: socket.assigns[:current_locale]
        )

        info =
          gettext(
            "We've sent a confirmation link to %{email}. Click it to finish updating your email — that also confirms your account.",
            email: applied_user.email
          )

        socket
        |> put_flash(:info, info)
        |> assign(change_email?: false)
        |> assign(email_form: to_form(Auth.change_user_email(user), as: "email_change"))
        |> assign(email_form_current_password: nil)

      {:error, changeset} ->
        socket
        |> assign(email_form: to_form(changeset, as: "email_change", action: :insert))
        |> assign(email_form_current_password: params["current_password"])
    end
  end

  # The password-less path exists for a signup that cannot use its account
  # yet: with `require_email_confirmation` on, an unconfirmed account is
  # parked, so there is no live account for a hijacked session to re-address.
  # With the setting OFF that premise is gone — the account works, only the
  # confirmation is pending — so the change asks for the password exactly as
  # Profile Settings does (`Auth.apply_user_email/3`). Either way the account
  # must still be unconfirmed: the pattern match keeps this page from ever
  # becoming a second email-change path for a confirmed user.
  defp apply_email_change(
         %{assigns: %{email_change_requires_password?: true}},
         %{confirmed_at: nil} = user,
         password,
         user_params
       ),
       do: Auth.apply_user_email(user, password, user_params)

  defp apply_email_change(_socket, user, _password, user_params),
    do: Auth.apply_unconfirmed_user_email(user, user_params)

  defp email_change_requires_password?,
    do: not PhoenixKit.Settings.get_boolean_setting("require_email_confirmation", true)

  def handle_info({:user_confirmed, %{uuid: uuid}}, socket) do
    current = socket.assigns[:phoenix_kit_current_user]

    if current && current.uuid == uuid do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Email confirmed. Welcome!"))
       |> redirect(to: socket.assigns.destination)}
    else
      {:noreply, socket}
    end
  end

  # Defensive: the topic carries only this user's confirmation today.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # The anonymous path always shows the same vague copy no matter the outcome
  # (unregistered address, rate limit, or a real mailer failure) — surfacing
  # any of those as different from "sent" would tell an anonymous visitor
  # whether an address is registered. A parked visitor is already logged in
  # as that account, so there is nothing left to protect by hiding a real
  # failure from them — and hiding it is exactly how "we sent it" survived a
  # silent rate-limit block or mailer error undetected.
  defp flash_send_result(socket, result, email) do
    if socket.assigns.awaiting_confirmation? do
      flash_parked_result(socket, result, email)
    else
      put_flash(
        socket,
        :info,
        gettext(
          "If your email is in our system and it has not been confirmed yet, you will receive an email with instructions shortly."
        )
      )
    end
  end

  defp flash_parked_result(socket, {:ok, _email}, email) do
    put_flash(
      socket,
      :info,
      gettext("We've sent a new confirmation link to %{email}.", email: email)
    )
  end

  defp flash_parked_result(socket, {:error, :rate_limit_exceeded}, _email) do
    put_flash(
      socket,
      :error,
      gettext(
        "You've asked for this a few times already — please wait a few minutes and try again."
      )
    )
  end

  defp flash_parked_result(socket, {:error, :already_confirmed}, _email) do
    put_flash(socket, :info, gettext("Your email is already confirmed."))
  end

  defp flash_parked_result(socket, other, email) do
    Logger.error("Confirmation resend to #{email} failed: #{inspect(other)}")

    put_flash(
      socket,
      :error,
      gettext("We couldn't send that email just now — please try again in a moment.")
    )
  end

  # `:context` threads the socket's router so `"/"` is only used where the
  # host actually declares a root route. Without it the resolver synthesises
  # `"/"` literally, which 404s on any host that has no root route — the
  # configuration this entire branch exists to handle.
  defp resolve_destination(params, session, socket) do
    Routes.post_auth_path([params["return_to"], session["user_return_to"]],
      context: socket,
      scope: socket.assigns[:phoenix_kit_current_scope]
    )
  end
end
