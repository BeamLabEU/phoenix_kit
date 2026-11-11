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
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")

    case safe_consume(token) do
      {:ok, user} ->
        conn
        |> put_flash(:info, gettext("Signed in with a passkey."))
        |> UserAuth.log_in_user(user, Map.take(params, ["remember_me", "return_to"]))

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
  catch
    :exit, _reason ->
      Logger.warning("[PhoenixKit.PasskeyLoginComplete] token consumption exited")
      :error
  end

  defp refuse(conn) do
    conn
    |> put_flash(:error, gettext("This passkey sign-in has expired. Please try again."))
    |> redirect(to: Routes.path("/users/log-in"))
  end
end
