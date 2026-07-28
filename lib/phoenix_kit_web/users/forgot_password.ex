defmodule PhoenixKitWeb.Users.ForgotPassword do
  @moduledoc """
  LiveView for password reset request.

  Allows users to request a password reset by providing their email address.
  Sends password reset instructions via email if the account exists.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Utils.Routes

  def mount(_params, _session, socket) do
    case PhoenixKitWeb.Users.Auth.maybe_redirect_authenticated(socket) do
      {:redirect, socket} -> {:ok, socket}
      :cont -> {:ok, assign(socket, form: to_form(%{}, as: "user"))}
    end
  end

  def handle_event("send_email", %{"user" => %{"email" => email}}, socket) do
    # Rate-limit BEFORE the lookup, and answer identically whatever happens.
    # The limiter used to run inside deliver_*, i.e. only for addresses that
    # resolved to a user — so past the threshold a registered address got
    # "Too many password reset requests" while an unregistered one still got
    # the generic notice. That turned the deliberately vague copy into a
    # precise account-existence oracle: N+1 requests told you the answer.
    case RateLimiter.check_password_reset_rate_limit(email) do
      :ok ->
        if user = Auth.get_user_by_email(email) do
          Auth.deliver_user_reset_password_instructions(
            user,
            &Routes.url("/users/reset-password/#{&1}")
          )
        end

      {:error, :rate_limit_exceeded} ->
        :throttled
    end

    info =
      "If your email is in our system, you will receive instructions to reset your password shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> redirect(to: "/")}
  end
end
