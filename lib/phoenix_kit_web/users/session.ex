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
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: UserAuth

  def create(conn, %{"_action" => "registered"} = params) do
    create(conn, params, "Account created successfully!")
  end

  def create(conn, %{"_action" => "password_updated"} = params) do
    conn
    |> put_session(:user_return_to, Routes.path("/dashboard/settings"))
    |> create(params, "Password updated successfully!")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  defp create(conn, %{"user" => user_params}, info) do
    %{"password" => password} = user_params
    # Support both old "email" field and new "email_or_username" field for backwards compatibility
    email_or_username = user_params["email_or_username"] || user_params["email"]
    ip_address = IpAddress.extract_from_conn(conn)

    case Auth.get_user_by_email_or_username_and_password(email_or_username, password, ip_address) do
      {:ok, %Auth.User{is_active: false}} ->
        # Valid credentials but account is inactive
        conn
        |> put_flash(
          :error,
          "Your account is currently inactive. Please contact the team if you believe this is an error."
        )
        |> put_flash(:email_or_username, String.slice(email_or_username, 0, 160))
        |> redirect(to: Routes.path("/users/log-in"))

      {:ok, user} ->
        # Valid credentials and active account
        conn
        |> maybe_store_return_to_from_params(user_params)
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      {:error, :rate_limit_exceeded} ->
        # Rate limit exceeded - show specific error message
        conn
        |> put_flash(:error, "Too many login attempts. Please try again later.")
        |> put_flash(:email_or_username, String.slice(email_or_username, 0, 160))
        |> redirect(to: Routes.path("/users/log-in"))

      {:error, :invalid_credentials} ->
        # Invalid credentials (wrong email/username or password)
        # In order to prevent user enumeration attacks, don't disclose whether the email/username is registered.
        conn
        |> put_flash(:error, "Invalid email/username or password")
        |> put_flash(:email_or_username, String.slice(email_or_username, 0, 160))
        |> redirect(to: Routes.path("/users/log-in"))
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end

  # Store return_to from form params (e.g., guest checkout → login → back to checkout)
  defp maybe_store_return_to_from_params(conn, %{"return_to" => return_to})
       when is_binary(return_to) and return_to != "" do
    if String.starts_with?(return_to, "/") and not String.starts_with?(return_to, "//") do
      put_session(conn, :user_return_to, return_to)
    else
      conn
    end
  end

  defp maybe_store_return_to_from_params(conn, _params), do: conn

  # Support GET logout for direct URL access
  def get_logout(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
