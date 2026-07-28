defmodule PhoenixKitWeb.Users.MagicLink do
  @moduledoc """
  LiveView for magic link authentication.

  This LiveView handles the magic link authentication flow:
  1. User enters their email address
  2. System sends magic link to their email
  3. User clicks link to authenticate

  The magic link verification is handled by the controller, this LiveView
  handles the email input and confirmation flow.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Presence
  alias PhoenixKit.Mailer
  alias PhoenixKit.Users.MagicLink
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth

  @impl true
  def mount(params, session, socket) do
    case Auth.maybe_redirect_authenticated(socket) do
      {:redirect, socket} ->
        {:ok, socket}

      :cont ->
        # Track anonymous visitor session
        if connected?(socket) do
          session_id = session["live_socket_id"] || generate_session_id()

          Presence.track_anonymous(session_id, %{
            connected_at: UtilsDate.utc_now(),
            ip_address: IpAddress.extract_from_socket(socket),
            user_agent: get_connect_info(socket, :user_agent),
            current_page: Routes.path("/users/magic-link")
          })
        end

        form = to_form(%{"email" => ""}, as: "magic_link")

        # Carried into the emailed link so a user sent here from a protected
        # page still lands there after clicking it. Sanitized on the way in and
        # again on the way out.
        return_to = if Routes.local_path?(params["return_to"]), do: params["return_to"]

        {:ok,
         socket
         |> assign(:page_title, "Magic Link Login")
         |> assign(:form, form)
         |> assign(:sent, false)
         |> assign(:loading, false)
         |> assign(:error, nil)
         |> assign(:return_to, return_to)}
    end
  end

  @impl true
  def handle_event("validate", %{"magic_link" => magic_link_params}, socket) do
    form = to_form(magic_link_params, as: "magic_link")
    {:noreply, assign(socket, form: form)}
  end

  @impl true
  def handle_event("send_magic_link", %{"magic_link" => %{"email" => email}}, socket) do
    if valid_email?(email) do
      form = to_form(%{"email" => email}, as: "magic_link")

      {:noreply,
       socket
       |> assign(:form, form)
       |> assign(:loading, true)
       |> assign(:error, nil)
       |> send_magic_link_async(email, socket.assigns[:return_to])}
    else
      form = to_form(%{"email" => email}, as: "magic_link")

      {:noreply,
       socket
       |> assign(:form, form)
       |> assign(:error, "Please enter a valid email address")}
    end
  end

  @impl true
  def handle_async(:send_magic_link, {:ok, result}, socket) do
    case result do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(:sent, true)
         |> assign(:loading, false)
         |> put_flash(:info, "Magic link sent! Check your email.")}

      {:error, _} ->
        # For security, we don't reveal whether the email exists or not
        {:noreply,
         socket
         |> assign(:sent, true)
         |> assign(:loading, false)
         |> put_flash(:info, "If that email address exists, a magic link has been sent.")}
    end
  end

  @impl true
  def handle_async(:send_magic_link, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:error, "Failed to send magic link. Please try again.")}
  end

  # Send magic link email to user and handle response
  defp send_magic_link_email_to_user(user, token, return_to) do
    magic_link_url = MagicLink.magic_link_url(token) <> Routes.return_to_query(return_to)

    case Mailer.send_magic_link_email(user, magic_link_url) do
      {:ok, _} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  # Process the magic link sending in the background
  defp send_magic_link_async(socket, email, return_to) do
    Phoenix.LiveView.start_async(socket, :send_magic_link, fn ->
      case MagicLink.generate_magic_link(email) do
        {:ok, user, token} ->
          send_magic_link_email_to_user(user, token, return_to)

        {:error, :user_not_found} ->
          # For security, we simulate the same delay as successful case
          Process.sleep(100)
          {:error, :user_not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # Simple email validation
  defp valid_email?(email) when is_binary(email) do
    String.match?(email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end
end
