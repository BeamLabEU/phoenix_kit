defmodule PhoenixKitWeb.Users.ForgotPassword do
  @moduledoc """
  LiveView for password reset request.

  Allows users to request a password reset by providing their email address.
  Sends password reset instructions via email if the account exists.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.BotCheck

  def mount(_params, _session, socket) do
    socket = assign(socket, :page_title, gettext("Forgot your password?"))

    case PhoenixKitWeb.Users.Auth.maybe_redirect_authenticated(socket) do
      {:redirect, socket} ->
        {:ok, socket}

      :cont ->
        {:ok,
         socket
         |> assign(form: to_form(%{}, as: "user"))
         # Connect info is readable during mount and nowhere else, so the
         # address the per-IP bucket needs at submit time is captured here.
         |> assign(ip_address: IpAddress.client_address_from_socket(socket))}
    end
  end

  def handle_event("send_email", %{"user" => %{"email" => _}} = params, socket) do
    case BotCheck.run(socket, params, socket.assigns[:ip_address]) do
      {:ok, socket} -> send_email(params, socket)
      {:error, socket} -> {:noreply, socket}
    end
  end

  defp send_email(%{"user" => %{"email" => email}}, socket) do
    # Rate-limit BEFORE the lookup, and answer identically whatever happens.
    # The limiter used to run inside deliver_*, i.e. only for addresses that
    # resolved to a user — so past the threshold a registered address got
    # "Too many password reset requests" while an unregistered one still got
    # the generic notice. That turned the deliberately vague copy into a
    # precise account-existence oracle: N+1 requests told you the answer.
    #
    # `rate_limit: false` because that check is this request's — deliver_* still
    # limits by default for callers without one (the admin "send reset link"
    # action), and both hit the same per-email bucket, so charging it twice
    # would halve a real user's allowance and swallow every second email while
    # this page still showed the success notice.
    case RateLimiter.check_password_reset_rate_limit(email, socket.assigns[:ip_address]) do
      :ok ->
        if user = Auth.get_user_by_email(email) do
          Auth.deliver_user_reset_password_instructions(
            user,
            &Routes.url("/users/reset-password/#{&1}"),
            rate_limit: false,
            locale: socket.assigns[:current_locale]
          )
        end

      {:error, :rate_limit_exceeded} ->
        :throttled
    end

    info =
      gettext(
        "If your email is in our system, you will receive instructions to reset your password shortly."
      )

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> redirect(
       to: Routes.safe_destination(socket, scope: socket.assigns[:phoenix_kit_current_scope])
     )}
  end
end
