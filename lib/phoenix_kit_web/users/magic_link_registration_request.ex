defmodule PhoenixKitWeb.Users.MagicLinkRegistrationRequest do
  @moduledoc """
  LiveView for requesting magic link registration.

  Allows users to enter their email and receive a magic link to complete registration.
  """

  use PhoenixKitWeb, :live_view

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth

  @impl true
  def mount(_params, _session, socket) do
    case Auth.maybe_redirect_authenticated(socket) do
      {:redirect, socket} ->
        {:ok, socket}

      :cont ->
        if Settings.get_boolean_setting("allow_registration", true) do
          # Get project title from settings (with Config fallback)
          project_title = PhoenixKit.Settings.get_project_title()

          {:ok,
           socket
           |> assign(:page_title, "Register via Magic Link")
           |> assign(:project_title, project_title)
           |> assign(:email, "")
           |> assign(:email_sent, false)
           |> assign(:error_message, nil)
           |> assign(:loading, false)}
        else
          socket =
            socket
            |> put_flash(
              :error,
              "User registration is currently disabled. Please contact an administrator."
            )
            |> redirect(to: Routes.path("/users/log-in"))

          {:ok, socket}
        end
    end
  end

  @impl true
  def handle_event("send_magic_link", %{"email" => email}, socket) do
    if Settings.get_boolean_setting("allow_registration", true) do
      # Send in the background via start_async so the `@loading` spinner
      # actually renders (a synchronous handler never re-renders with
      # loading: true before completing). Mirrors PhoenixKitWeb.Users.MagicLink.
      email = String.trim(email)

      {:noreply,
       socket
       |> assign(:email, email)
       |> assign(:loading, true)
       |> assign(:error_message, nil)
       |> send_registration_link_async(email)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "User registration is currently disabled.")
       |> redirect(to: Routes.path("/users/log-in"))}
    end
  end

  @impl true
  def handle_async(:send_magic_link, {:ok, result}, socket) do
    case result do
      {:ok, sent_email, _token} ->
        {:noreply,
         socket
         |> assign(:email_sent, true)
         |> assign(:email, sent_email)
         |> assign(:loading, false)
         |> assign(:error_message, nil)
         |> put_flash(:info, "Registration link sent! Check your email.")}

      # Deliberately indistinguishable from success: saying "already
      # registered" here turned this public form into an account-existence
      # oracle, while login and magic-link login both answer generically.
      {:error, :email_already_exists} ->
        {:noreply,
         socket
         |> assign(:email_sent, true)
         |> assign(:loading, false)
         |> assign(:error_message, nil)
         |> put_flash(:info, "Registration link sent! Check your email.")}

      {:error, :invalid_email} ->
        {:noreply,
         error_state(socket, "Please enter a valid email address.", "Invalid email format")}

      {:error, _reason} ->
        {:noreply, generic_failure(socket)}
    end
  end

  # A crashed/exited task is indistinguishable to the user from a failed send.
  @impl true
  def handle_async(:send_magic_link, {:exit, _reason}, socket) do
    {:noreply, generic_failure(socket)}
  end

  defp send_registration_link_async(socket, email) do
    Phoenix.LiveView.start_async(socket, :send_magic_link, fn ->
      MagicLinkRegistration.send_registration_link(email)
    end)
  end

  defp generic_failure(socket) do
    error_state(
      socket,
      "Failed to send registration link. Please try again.",
      "Something went wrong"
    )
  end

  defp error_state(socket, message, flash_message) do
    socket
    |> assign(:loading, false)
    |> assign(:error_message, message)
    |> put_flash(:error, flash_message)
  end
end
