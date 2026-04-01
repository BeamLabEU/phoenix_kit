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

  def mount(%{"token" => token}, _session, socket) do
    form = to_form(%{"token" => token}, as: "user")
    {:ok, assign(socket, form: form), temporary_assigns: [form: nil]}
  end

  # Do not log in the user after confirmation to avoid a
  # leaked token giving the user access to the account.
  def handle_event("confirm_account", %{"user" => %{"token" => token}}, socket) do
    case Auth.confirm_user(token) do
      {:ok, user} ->
        maybe_accept_pending_invitation(user)

        {:noreply,
         socket
         |> put_flash(:info, "User confirmed successfully.")
         |> redirect(to: "/")}

      :error ->
        # If there is a current user and the account was already confirmed,
        # then odds are that the confirmation link was already visited, either
        # by some automation or by the user themselves, so we redirect without
        # a warning message.
        case socket.assigns do
          %{phoenix_kit_current_user: %{confirmed_at: confirmed_at}}
          when not is_nil(confirmed_at) ->
            {:noreply, redirect(socket, to: "/")}

          %{} ->
            {:noreply,
             socket
             |> put_flash(:error, "User confirmation link is invalid or it has expired.")
             |> redirect(to: "/")}
        end
    end
  end

  # Auto-accept a pending invitation stored in custom_fields during registration.
  # The invitation token is placed there by the registration flow when user
  # arrives via an invite link (?invitation=TOKEN).
  defp maybe_accept_pending_invitation(user) do
    token = user.custom_fields && user.custom_fields["pending_invitation_token"]

    if token do
      case Invitations.get_by_token(token) do
        {:ok, invitation} ->
          case Invitations.accept_invitation_by_uuid(invitation.uuid, user) do
            {:ok, _} ->
              # Clear the stored token after accepting
              Auth.update_user_fields(
                user,
                Map.delete(user.custom_fields, "pending_invitation_token")
              )

            {:error, reason} ->
              Logger.warning(
                "Failed to auto-accept invitation for user #{user.uuid}: #{inspect(reason)}"
              )
          end

        {:error, _} ->
          # Token expired or invalid — silently ignore
          :ok
      end
    end
  end
end
