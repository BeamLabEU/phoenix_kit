defmodule PhoenixKitWeb.Users.ConfirmationInstructions do
  @moduledoc """
  LiveView for resending email confirmation instructions.

  Allows users to request a new confirmation email if they didn't receive
  the original or if the link expired. Only sends if the account exists
  and is not already confirmed.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{}, as: "user"))}
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

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> redirect(to: "/")}
  end
end
