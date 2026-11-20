defmodule PhoenixKitWeb.Users.Confirmation do
  @moduledoc """
  LiveView for email confirmation.

  Handles the email confirmation flow after a user clicks the confirmation link
  from their registration email. Validates the confirmation token and confirms
  the user account.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Utils.Routes

  def mount(%{"token" => token} = params, session, socket) do
    socket = assign(socket, :page_title, gettext("Confirm your account"))

    form = to_form(%{"token" => token}, as: "user")

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

    {:ok, assign(socket, form: form, destination: destination), temporary_assigns: [form: nil]}
  end

  # Do not log in the user after confirmation to avoid a
  # leaked token giving the user access to the account.
  def handle_event("confirm_account", %{"user" => %{"token" => token}}, socket) do
    destination = socket.assigns.destination

    case Auth.confirm_user(token) do
      {:ok, user} ->
        maybe_accept_pending_invitation(user)

        {:noreply,
         socket
         |> put_flash(:info, gettext("User confirmed successfully."))
         |> redirect(to: destination)}

      :error ->
        # If there is a current user and the account was already confirmed,
        # then odds are that the confirmation link was already visited, either
        # by some automation or by the user themselves, so we redirect without
        # a warning message.
        case socket.assigns do
          %{phoenix_kit_current_user: %{confirmed_at: confirmed_at}}
          when not is_nil(confirmed_at) ->
            {:noreply, redirect(socket, to: destination)}

          %{} ->
            {:noreply,
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
             )}
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
