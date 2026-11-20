defmodule PhoenixKitWeb.Users.Confirmation do
  @moduledoc """
  The page the emailed confirmation link opens: it confirms the account at once
  and moves on, with no button to press.

  The token is spent on the CONNECTED mount, not on the plain GET. A mail
  scanner (Outlook's Safe Links and the like) fetches every link in an inbox
  before the person clicks it, but it does not run the page's JavaScript, so it
  never opens the LiveView socket and the token survives for the person. That
  is why this used to be a page with a "Confirm my account" button; the socket
  gives the same protection without the extra click. Until the socket connects,
  the page says it is confirming.

  Open pages of the account hear of the confirmation
  (`PhoenixKit.Admin.Events.broadcast_user_confirmed/1` refreshes their scope),
  so a "check your email" notice in another tab goes away by itself.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Utils.Routes

  def mount(%{"token" => token} = params, session, socket) do
    socket = assign(socket, :page_title, gettext("Confirm your account"))

    # Same destination rule as the parked /users/confirm page, so the tab that
    # clicks the emailed link and a tab parked waiting for confirmation don't
    # land in two different places. `?return_to=` is read as well as the
    # session key because a LiveView gate can only pass the destination in the
    # query string — it has no conn to `put_session` on.
    #
    # `:context` threads the socket's router into the resolver so that `"/"` —
    # the host's home page that core cannot declare — is only used where the
    # host proves it exists. Without it the resolver synthesises `"/"` literally,
    # which 404s on any host that never declared a root route.
    destination =
      Routes.post_auth_path([params["return_to"], session["user_return_to"]],
        context: socket,
        scope: socket.assigns[:phoenix_kit_current_scope]
      )

    socket = assign(socket, :destination, destination)

    if connected?(socket), do: {:ok, confirm(socket, token)}, else: {:ok, socket}
  end

  # Kept for a page rendered before this module confirmed on mount (an open tab
  # across a deploy): its button still works.
  def handle_event("confirm_account", %{"user" => %{"token" => token}}, socket) do
    {:noreply, confirm(socket, token)}
  end

  # Do not log in the user after confirmation to avoid a
  # leaked token giving the user access to the account.
  defp confirm(socket, token) do
    destination = socket.assigns.destination

    case Auth.confirm_user(token) do
      {:ok, user} ->
        maybe_accept_pending_invitation(user)

        socket
        |> put_flash(:info, gettext("User confirmed successfully."))
        |> redirect(to: destination)

      :error ->
        # If there is a current user and the account was already confirmed,
        # then odds are that the confirmation link was already visited, either
        # by some automation or by the user themselves, so we redirect without
        # a warning message.
        case socket.assigns do
          %{phoenix_kit_current_user: %{confirmed_at: confirmed_at}}
          when not is_nil(confirmed_at) ->
            redirect(socket, to: destination)

          %{} ->
            socket
            |> put_flash(
              :error,
              gettext("User confirmation link is invalid or it has expired.")
            )
            |> redirect(
              to:
                Routes.safe_destination(socket,
                  scope: socket.assigns[:phoenix_kit_current_scope]
                )
            )
        end
    end
  end

  # Auto-accept a pending invitation stored in custom_fields during registration.
  # The invitation UUID is placed there by the registration flow when user
  # arrives via an invite link (?invitation=TOKEN).
  defp maybe_accept_pending_invitation(user) do
    uuid = user.custom_fields && user.custom_fields["pending_invitation_uuid"]

    if uuid do
      case Invitations.accept_invitation_by_uuid(uuid, user) do
        {:ok, _} ->
          Auth.update_user_fields(user, %{"pending_invitation_uuid" => nil})

        {:error, reason} ->
          Logger.warning(
            "Failed to auto-accept invitation for user #{user.uuid}: #{inspect(reason)}"
          )
      end
    end
  end
end
