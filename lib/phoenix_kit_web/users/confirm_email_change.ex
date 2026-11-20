defmodule PhoenixKitWeb.Users.ConfirmEmailChange do
  @moduledoc """
  Confirms an email change requested while the account was still
  unconfirmed — the "Wrong email? Change it" flow on the parked
  `/users/confirm` page.

  Lives on the same ungated public surface as `PhoenixKitWeb.Users.Confirmation`,
  and for the same reason `/users/confirm` itself does: the normal change-email
  landing page, `/profile/settings/confirm-email/:token`, sits behind the
  authenticated-AND-confirmed live_session — gating it would put the fix for
  "I'm unconfirmed" behind a requirement of already being confirmed.

  `Auth.update_user_email/2` needs the account's CURRENT (pre-change) email to
  rebuild the token's context, so the visitor must still be logged in as that
  account; not logged in bounces to log-in with a `return_to` back here. The
  token is spent on the CONNECTED mount, not on the plain GET, so an
  email-scanning bot in the inbox (which runs no JavaScript and never opens the
  socket) can't spend it before the person does — the same defense
  `PhoenixKitWeb.Users.Confirmation` uses for the account-confirmation link,
  without a button to press.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  def mount(%{"token" => token}, _session, socket) do
    socket = assign(socket, :page_title, gettext("Confirm Email Change"))

    case socket.assigns[:phoenix_kit_current_user] do
      nil ->
        {:ok,
         redirect(socket,
           to:
             Routes.path("/users/log-in") <> Routes.return_to_query(Routes.path("/users/confirm"))
         )}

      _user ->
        if connected?(socket), do: {:ok, confirm(socket, token)}, else: {:ok, socket}
    end
  end

  # Kept for a page rendered before this module confirmed on mount (an open tab
  # across a deploy): its button still works.
  def handle_event("confirm_email_change", %{"user" => %{"token" => token}}, socket) do
    {:noreply, confirm(socket, token)}
  end

  defp confirm(socket, token) do
    user = socket.assigns.phoenix_kit_current_user

    case Auth.update_user_email(user, token) do
      :ok ->
        socket
        |> put_flash(:info, gettext("Email changed and confirmed. Welcome!"))
        |> redirect(
          to:
            Routes.post_auth_path([],
              context: socket,
              scope: socket.assigns[:phoenix_kit_current_scope]
            )
        )

      :error ->
        socket
        |> put_flash(:error, gettext("Email change link is invalid or it has expired."))
        |> redirect(to: Routes.path("/users/confirm"))
    end
  end
end
