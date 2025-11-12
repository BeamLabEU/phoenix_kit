defmodule PhoenixKitWeb.Users.MagicLinkRegistrationVerify do
  @moduledoc """
  Controller for handling magic link registration verification.
  """

  use PhoenixKitWeb, :controller

  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Utils.Routes

  @doc """
  Verifies a magic link registration token and redirects to completion form.
  """
  def verify(conn, %{"token" => token}) do
    case MagicLinkRegistration.verify_registration_token(token) do
      {:ok, _email} ->
        # Redirect to LiveView completion form
        redirect(conn, to: Routes.path("/users/register/complete/#{token}"))

      {:error, _} ->
        conn
        |> put_flash(
          :error,
          "Registration link is invalid or has expired. Please request a new one."
        )
        |> redirect(to: Routes.path("/users/register"))
    end
  end

  def verify(conn, _params) do
    conn
    |> put_flash(:error, "Invalid registration link. Please request a new one.")
    |> redirect(to: Routes.path("/users/register"))
  end
end
