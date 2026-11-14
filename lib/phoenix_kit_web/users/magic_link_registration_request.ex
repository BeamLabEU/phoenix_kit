defmodule PhoenixKitWeb.Users.MagicLinkRegistrationRequest do
  @moduledoc """
  LiveView for requesting magic link registration.

  Allows users to enter their email and receive a magic link to complete registration.
  """

  use PhoenixKitWeb, :live_view

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.EmailDomain
  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth
  alias PhoenixKitWeb.Users.AuthSEO
  alias PhoenixKitWeb.Users.BotCheck

  @impl true
  def mount(_params, _session, socket) do
    case Auth.maybe_redirect_authenticated(socket) do
      {:redirect, socket} ->
        {:ok, socket}

      :cont ->
        # Both gates apply: registration has to be open at all, AND magic-link
        # registration specifically has to be enabled. The second setting used
        # to hide the button on /users/register and nothing else, leaving this
        # route reachable by anyone with the URL.
        if Settings.get_boolean_setting("allow_registration", true) and
             Auth.magic_link_registration_enabled?() do
          # Get project title from settings (with Config fallback)
          project_title = PhoenixKit.Settings.get_project_title()
          seo = AuthSEO.seo_assigns("/users/register/magic-link")

          {:ok,
           socket
           |> assign(:page_title, gettext("Register via Magic Link"))
           |> assign(:project_title, project_title)
           |> assign(:email, "")
           |> assign(:email_suggestion, nil)
           |> assign(:ip_address, IpAddress.extract_from_socket(socket))
           |> assign(:email_sent, false)
           |> assign(:error_message, nil)
           |> assign(:loading, false)
           |> assign(:canonical_url, seo.canonical_url)
           |> assign(:hreflang_links, seo.hreflang_links)}
        else
          socket =
            socket
            |> put_flash(
              :error,
              gettext("User registration is currently disabled. Please contact an administrator.")
            )
            |> redirect(to: Routes.path("/users/log-in"))

          {:ok, socket}
        end
    end
  end

  # Keeps the typed address and the "did you mean" hint under it: a pure rule
  # over the text, no DNS and no lookup.
  @impl true
  def handle_event("validate", %{"email" => email}, socket) when is_binary(email) do
    {:noreply,
     socket
     |> assign(:email, email)
     |> assign(:email_suggestion, EmailDomain.suggestion(email))}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("use_email_suggestion", _params, socket) do
    case socket.assigns[:email_suggestion] do
      suggestion when is_binary(suggestion) ->
        {:noreply, socket |> assign(:email, suggestion) |> assign(:email_suggestion, nil)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("send_magic_link", %{"email" => _} = params, socket) do
    if Settings.get_boolean_setting("allow_registration", true) do
      case BotCheck.run(socket, params, socket.assigns[:ip_address]) do
        {:ok, socket} -> request_link(params, socket)
        {:error, socket} -> {:noreply, socket}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("User registration is currently disabled."))
       |> redirect(to: Routes.path("/users/log-in"))}
    end
  end

  defp request_link(%{"email" => email}, socket) do
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
         |> put_flash(:info, gettext("Registration link sent! Check your email."))}

      # Deliberately indistinguishable from success: saying "already
      # registered" here turned this public form into an account-existence
      # oracle, while login and magic-link login both answer generically.
      {:error, :email_already_exists} ->
        {:noreply,
         socket
         |> assign(:email_sent, true)
         |> assign(:loading, false)
         |> assign(:error_message, nil)
         |> put_flash(:info, gettext("Registration link sent! Check your email."))}

      {:error, :invalid_email} ->
        {:noreply,
         error_state(
           socket,
           gettext("Please enter a valid email address."),
           gettext("Invalid email format")
         )}

      {:error, :no_mail_host} ->
        {:noreply,
         error_state(
           socket,
           gettext("This email domain cannot receive mail. Please check the address."),
           gettext("Email domain cannot receive mail")
         )}

      {:error, :rate_limit_exceeded} ->
        {:noreply,
         error_state(
           socket,
           gettext("Too many registration attempts. Please try again later."),
           gettext("Too many attempts")
         )}

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
    ip_address = socket.assigns[:ip_address]
    # Read here: the task below is another process, with no page language.
    locale = socket.assigns[:current_locale]

    Phoenix.LiveView.start_async(socket, :send_magic_link, fn ->
      MagicLinkRegistration.send_registration_link(email, ip_address, locale: locale)
    end)
  end

  defp generic_failure(socket) do
    error_state(
      socket,
      gettext("Failed to send registration link. Please try again."),
      gettext("Something went wrong")
    )
  end

  defp error_state(socket, message, flash_message) do
    socket
    |> assign(:loading, false)
    |> assign(:error_message, message)
    |> put_flash(:error, flash_message)
  end
end
