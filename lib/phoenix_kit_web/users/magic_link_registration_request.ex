defmodule PhoenixKitWeb.Users.MagicLinkRegistrationRequest do
  @moduledoc """
  LiveView for requesting magic link registration.

  Allows users to enter their email and receive a magic link to complete registration.
  """

  use PhoenixKitWeb, :live_view

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
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
  end

  @impl true
  def handle_event("send_magic_link", %{"email" => email}, socket) do
    email = String.trim(email)

    socket = assign(socket, :loading, true)

    case MagicLinkRegistration.send_registration_link(email) do
      {:ok, sent_email, _token} ->
        {:noreply,
         socket
         |> assign(:email_sent, true)
         |> assign(:email, sent_email)
         |> assign(:loading, false)
         |> assign(:error_message, nil)
         |> put_flash(:info, "Registration link sent! Check your email.")}

      {:error, :email_already_exists} ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:error_message, "This email is already registered. Please log in instead.")
         |> put_flash(:error, "Email already exists")}

      {:error, :invalid_email} ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:error_message, "Please enter a valid email address.")
         |> put_flash(:error, "Invalid email format")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:error_message, "Failed to send registration link. Please try again.")
         |> put_flash(:error, "Something went wrong")}
    end
  end
end
