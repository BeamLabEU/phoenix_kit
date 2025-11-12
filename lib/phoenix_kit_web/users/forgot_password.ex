defmodule PhoenixKitWeb.Users.ForgotPassword do
  @moduledoc """
  LiveView for password reset request.

  Allows users to request a password reset by providing their email address.
  Sends password reset instructions via email if the account exists.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{}, as: "user"))}
  end

  def handle_event("send_email", %{"user" => %{"email" => email}}, socket) do
    if user = Auth.get_user_by_email(email) do
      Auth.deliver_user_reset_password_instructions(
        user,
        &Routes.url("/users/reset-password/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions to reset your password shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> redirect(to: "/")}
  end
end
