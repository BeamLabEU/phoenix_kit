defmodule PhoenixKitWeb.Users.Session do
  @moduledoc """
  Controller for handling user session management.

  This controller manages user login and logout operations, including:
  - Creating new sessions via email/password authentication
  - Handling post-registration and password update flows
  - Session termination (logout)
  - GET-based logout for direct URL access

  ## Security Features

  - Prevents user enumeration by not disclosing whether an email is registered
  - Supports remember me functionality via UserAuth module
  - Session renewal on login/logout to prevent fixation attacks
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: UserAuth

  def create(conn, %{"_action" => "registered"} = params) do
    create(conn, params, "Account created successfully!")
  end

  def create(conn, %{"_action" => "password_updated"} = params) do
    conn
    |> put_session(:user_return_to, Routes.path("/users/settings"))
    |> create(params, "Password updated successfully!")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params
    ip_address = get_ip_address(conn)

    case Auth.get_user_by_email_and_password(email, password, ip_address) do
      {:ok, %Auth.User{is_active: false}} ->
        # Valid credentials but account is inactive
        conn
        |> put_flash(
          :error,
          "Your account is currently inactive. Please contact the team if you believe this is an error."
        )
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: Routes.path("/users/log-in"))

      {:ok, user} ->
        # Valid credentials and active account
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      {:error, :rate_limit_exceeded} ->
        # Rate limit exceeded - show specific error message
        conn
        |> put_flash(:error, "Too many login attempts. Please try again later.")
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: Routes.path("/users/log-in"))

      {:error, :invalid_credentials} ->
        # Invalid credentials (wrong email or password)
        # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
        conn
        |> put_flash(:error, "Invalid email or password")
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: Routes.path("/users/log-in"))
    end
  end

  defp get_ip_address(conn) do
    case Plug.Conn.get_peer_data(conn) do
      %{address: {a, b, c, d}} -> "#{a}.#{b}.#{c}.#{d}"
      %{address: address} -> to_string(address)
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end

  # Support GET logout for direct URL access
  def get_logout(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
