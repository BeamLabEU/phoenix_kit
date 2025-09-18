defmodule PhoenixKitWeb.Users.MagicLinkLive do
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
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, session, socket) do
    # Track anonymous visitor session
    if connected?(socket) do
      session_id = session["live_socket_id"] || generate_session_id()

      Presence.track_anonymous(session_id, %{
        connected_at: DateTime.utc_now(),
        ip_address: get_connect_info(socket, :peer_data) |> extract_ip_address(),
        user_agent: get_connect_info(socket, :user_agent),
        current_page: Routes.path("/users/magic-link")
      })
    end

    form = to_form(%{"email" => ""}, as: "magic_link")

    {:ok,
     socket
     |> assign(:page_title, "Magic Link Login")
     |> assign(:form, form)
     |> assign(:sent, false)
     |> assign(:loading, false)
     |> assign(:error, nil)}
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
       |> send_magic_link_async(email)}
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
  defp send_magic_link_email_to_user(user, token) do
    magic_link_url = MagicLink.magic_link_url(token)

    case Mailer.send_magic_link_email(user, magic_link_url) do
      {:ok, _} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  # Process the magic link sending in the background
  defp send_magic_link_async(socket, email) do
    Phoenix.LiveView.start_async(socket, :send_magic_link, fn ->
      case MagicLink.generate_magic_link(email) do
        {:ok, user, token} ->
          send_magic_link_email_to_user(user, token)

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

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
    >
      <div class="mx-auto max-w-sm">
        <.header class="text-center">
          Magic Link Login
          <:subtitle>Enter your email to receive a secure login link</:subtitle>
        </.header>

        <.form
          for={@form}
          id="magic_link_form"
          phx-submit="send_magic_link"
          phx-change="validate"
        >
          <fieldset class="fieldset">
            <legend class="fieldset-legend sr-only">Magic Link Authentication</legend>

            <div :if={@error} class="alert alert-error text-sm mb-4">
              <PhoenixKitWeb.Components.Core.Icons.icon_error_circle class="stroke-current shrink-0 h-6 w-6" />
              <span>{@error}</span>
            </div>

            <label class="label" for="magic_link_email">Email</label>
            <input
              id="magic_link_email"
              name="magic_link[email]"
              type="email"
              class="input input-bordered w-full"
              placeholder="you@example.com"
              value={@form.params["email"] || ""}
              required
            />

            <button
              type="submit"
              phx-disable-with="Sending magic link..."
              class="btn btn-primary w-full mt-4"
              disabled={@loading || @sent}
            >
              <%= if @loading do %>
                <span class="loading loading-spinner loading-sm mr-2"></span> Sending magic link...
              <% else %>
                Send Magic Link <span aria-hidden="true">→</span>
              <% end %>
            </button>
          </fieldset>
        </.form>

        <div :if={@sent} class="mt-6 p-4 bg-green-50 border border-green-200 rounded-md">
          <div class="flex">
            <.icon name="hero-check-circle" class="h-5 w-5 text-green-400" />
            <div class="ml-3">
              <h3 class="text-sm font-medium text-green-800">
                Magic link sent!
              </h3>
              <p class="mt-1 text-sm text-green-700">
                Check your email for a secure login link. The link will expire in 15 minutes.
              </p>
            </div>
          </div>
        </div>
        
    <!-- Development Mode Notice -->
        <div :if={show_dev_notice?()} class="alert alert-info text-sm mt-6">
          <PhoenixKitWeb.Components.Core.Icons.icon_info class="stroke-current shrink-0 h-6 w-6" />
          <span>
            Development mode: Check
            <.link href="/dev/mailbox" class="font-semibold underline">mailbox</.link>
            for confirmation emails
          </span>
        </div>

        <div class="mt-6">
          <div class="relative">
            <div class="absolute inset-0 flex items-center">
              <div class="w-full border-t border-gray-300" />
            </div>
            <div class="relative flex justify-center text-sm">
              <span class="px-2 bg-white text-gray-500">Or continue with</span>
            </div>
          </div>

          <div class="mt-6 text-center">
            <.link navigate={Routes.path("/users/log-in")} class="text-sm text-brand hover:underline">
              Sign in with password
            </.link>
          </div>

          <div class="mt-3 text-center">
            <.link
              navigate={Routes.path("/users/register")}
              class="text-sm text-gray-600 hover:text-gray-500"
            >
              Don't have an account? Sign up
            </.link>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp show_dev_notice? do
    case Application.get_env(:phoenix_kit, PhoenixKit.Mailer)[:adapter] do
      Swoosh.Adapters.Local -> true
      _ -> false
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end

  defp extract_ip_address(nil), do: "unknown"
  defp extract_ip_address(%{address: {a, b, c, d}}), do: "#{a}.#{b}.#{c}.#{d}"
  defp extract_ip_address(%{address: address}), do: to_string(address)
  defp extract_ip_address(_), do: "unknown"
end
