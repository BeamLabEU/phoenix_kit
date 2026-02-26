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
    case PhoenixKitWeb.Users.Auth.maybe_redirect_authenticated(socket) do
      {:redirect, socket} -> {:ok, socket}
      :cont -> {:ok, assign(socket, form: to_form(%{}, as: "user"))}
    end
  end

  def handle_event("send_email", %{"user" => %{"email" => email}}, socket) do
    result =
      if user = Auth.get_user_by_email(email) do
        Auth.deliver_user_reset_password_instructions(
          user,
          &Routes.url("/users/reset-password/#{&1}")
        )
      else
        {:ok, nil}
      end

    case result do
      {:ok, _} ->
        info =
          "If your email is in our system, you will receive instructions to reset your password shortly."

        {:noreply,
         socket
         |> put_flash(:info, info)
         |> redirect(to: "/")}

      {:error, :rate_limit_exceeded} ->
        {:noreply,
         socket
         |> put_flash(:error, "Too many password reset requests. Please try again later.")
         |> redirect(to: Routes.path("/users/log-in"))}
    end
  end
end
