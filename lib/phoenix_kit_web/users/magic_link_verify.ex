defmodule PhoenixKitWeb.Users.MagicLinkVerify do
  @moduledoc """
  Controller for handling magic link verification and authentication.

  This controller handles the server-side verification of magic link tokens
  when users click on the links received via email.
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Utils.Routes

  alias PhoenixKit.Users.MagicLink
  alias PhoenixKitWeb.Users.Auth, as: UserAuth

  @doc """
  Verifies a magic link token and logs the user in.

  This is the endpoint that magic link URLs point to. It:
  1. Verifies the token is valid and not expired
  2. Logs the user in by creating a session
  3. Redirects to the appropriate post-login destination
  4. Handles invalid/expired tokens gracefully
  """
  def verify(conn, %{"token" => token}) do
    case MagicLink.verify_magic_link(token) do
      {:ok, user} ->
        # A magic-link user just proved control of their own inbox on this
        # device, so the session persists by default — without the remember-me
        # cookie the login rides a browser-session cookie that mobile browsers
        # drop overnight. There's no checkbox to tick when arriving from an
        # email, so this follows the site-wide policy setting.
        conn
        |> put_flash(:info, "Successfully logged in with magic link!")
        |> UserAuth.log_in_user(user, UserAuth.remember_me_params())

      {:error, :invalid_token} ->
        conn
        |> put_flash(:error, "Magic link is invalid or has expired. Please request a new one.")
        |> redirect(to: Routes.path("/users/log-in"))
    end
  end

  def verify(conn, _params) do
    conn
    |> put_flash(:error, "Invalid magic link. Please request a new one.")
    |> redirect(to: Routes.path("/users/log-in"))
  end
end
