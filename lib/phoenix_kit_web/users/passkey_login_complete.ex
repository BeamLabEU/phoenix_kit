defmodule PhoenixKitWeb.Users.PasskeyLoginComplete do
  @moduledoc """
  Completion endpoint for passkey sign-in.

  The sign-in LiveView (`PhoenixKitWeb.Users.Login`) verifies the passkey, then
  navigates here with a one-time token (`PhoenixKit.Users.Passkeys.mint_login_token/1`,
  60 seconds). This controller exchanges it for the user, exactly once, and signs them
  in with PhoenixKit's own session machinery, so remember-me, `return_to`, the
  new-login alerts and every sign-in refusal apply as for any other method.

  A replayed or stale URL lands on the sign-in page and signs nobody in.
  """
  use PhoenixKitWeb, :controller

  require Logger

  alias PhoenixKit.Users.Passkeys
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: UserAuth

  def complete(conn, %{"token" => token} = params) do
    case safe_consume(token) do
      {:ok, user} ->
        conn
        # log_in_user/3 reads :user_return_to from the session for its redirect,
        # so stash the (sanitized) destination there before signing in.
        |> maybe_store_return_to(params["return_to"])
        |> put_flash(:info, gettext("Signed in with a passkey."))
        |> UserAuth.log_in_user(user, login_params(params))

      :error ->
        refuse(conn)
    end
  end

  def complete(conn, _params), do: refuse(conn)

  # The switch is read at consumption too: turning passkeys off stops a sign-in
  # that was verified a moment before.
  defp safe_consume(token) do
    if Passkeys.enabled?(), do: Passkeys.consume_login_token(token), else: :error
  rescue
    error ->
      Logger.warning(
        "[PhoenixKit.PasskeyLoginComplete] could not consume the token: #{inspect(error.__struct__)}"
      )

      :error
  end

  defp refuse(conn) do
    conn
    |> put_flash(:error, gettext("This passkey sign-in has expired. Please try again."))
    |> redirect(to: Routes.path("/users/log-in"))
  end

  # Only "true" (the page's "Keep me logged in" box) asks for a persistent cookie;
  # log_in_user/3 still applies the site's policy.
  defp login_params(%{"remember_me" => "true"}), do: %{"remember_me" => "true"}
  defp login_params(_params), do: %{}

  defp maybe_store_return_to(conn, return_to) do
    if is_binary(return_to) and Routes.local_path?(return_to) do
      put_session(conn, :user_return_to, return_to)
    else
      conn
    end
  end
end
