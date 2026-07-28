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
  - While parked, the LiveView listens for the `{:user_confirmed, user}`
    event (broadcast by both the email-link flow and the admin confirm
    action) and redirects onward live, no refresh needed — e.g. when the
    user clicks the emailed link in another tab.

  "Onward" is `?return_to=` (stashed by the gate that parked them), then
  the session's `user_return_to`, then the `after_login_path` setting.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  def mount(params, session, socket) do
    user = socket.assigns[:phoenix_kit_current_user]
    destination = resolve_destination(params, session)

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
        if connected?(socket), do: Events.subscribe_to_users()

        if connected?(socket) and confirmed_since_mount?(user) do
          {:ok, redirect(socket, to: destination)}
        else
          {:ok,
           socket
           |> assign(form: to_form(%{"email" => user.email}, as: "user"))
           |> assign(awaiting_confirmation?: true)
           |> assign(destination: destination)}
        end
    end
  end

  defp confirmed_since_mount?(user) do
    case Auth.get_user(user.uuid) do
      %{confirmed_at: confirmed_at} -> not is_nil(confirmed_at)
      _ -> false
    end
  end

  def handle_event("send_instructions", %{"user" => %{"email" => email}}, socket) do
    if user = Auth.get_user_by_email(email) do
      Auth.deliver_user_confirmation_instructions(
        user,
        &Routes.url("/users/confirm/#{&1}")
      )
    end

    info =
      "If your email is in our system and it has not been confirmed yet, you will receive an email with instructions shortly."

    socket = put_flash(socket, :info, info)

    # A parked (logged-in, unconfirmed) user stays here so the live
    # auto-advance can fire once they click the emailed link; anonymous
    # visitors are sent on to the resolved destination.
    if socket.assigns.awaiting_confirmation? do
      {:noreply, socket}
    else
      {:noreply, redirect(socket, to: socket.assigns.destination)}
    end
  end

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

  # The admin users topic also carries created/updated/deleted/etc. events.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp resolve_destination(params, session) do
    Routes.post_auth_path([params["return_to"], session["user_return_to"]])
  end
end
