defmodule PhoenixKitWeb.Users.LoginLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Presence
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="{@project_title} - Sign in"
    >
      <div class="flex items-center justify-center py-8 min-h-[80vh] bg-base-200">
        <div class="card bg-base-100 w-full max-w-sm shadow-2xl">
          <div class="card-body">
            <h1 class="text-2xl font-bold text-center mb-6">{@project_title} Sign in</h1>
            <.form
              for={@form}
              id="login_form"
              action={Routes.path("/users/log-in")}
              phx-update="ignore"
            >
              <fieldset class="fieldset">
                <legend class="fieldset-legend sr-only">Login with Password</legend>

                <label class="label" for="user_email">Email</label>
                <input
                  id="user_email"
                  name="user[email]"
                  type="email"
                  class="input input-bordered w-full"
                  placeholder="Email"
                  value={@form.params["email"] || ""}
                  required
                />

                <label class="label" for="user_password">Password</label>
                <input
                  id="user_password"
                  name="user[password]"
                  type="password"
                  class="input input-bordered w-full"
                  placeholder="Password"
                  required
                />

                <div class="form-control mt-4">
                  <label class="label cursor-pointer">
                    <span class="label-text">Keep me logged in</span>
                    <input
                      id="user_remember_me"
                      name="user[remember_me]"
                      type="checkbox"
                      class="checkbox checkbox-info"
                    />
                  </label>
                </div>

                <div class="text-center mt-2">
                  <.link
                    href={Routes.path("/users/reset-password")}
                    class="text-sm font-semibold text-primary hover:underline"
                  >
                    Forgot your password?
                  </.link>
                </div>

                <button
                  type="submit"
                  phx-disable-with="Logging in..."
                  class="btn btn-primary w-full mt-4"
                >
                  Log in <span aria-hidden="true">→</span>
                </button>
              </fieldset>
            </.form>
            
    <!-- Registration link -->
            <%= if @allow_registration do %>
              <div class="text-center mt-4 text-sm">
                <span>New to {@project_title}? </span>
                <.link
                  navigate={Routes.path("/users/register")}
                  class="font-semibold text-primary hover:underline"
                >
                  Create an account
                </.link>
              </div>
            <% end %>
            
    <!-- Development Mode Notice -->
            <div :if={show_dev_notice?()} class="alert alert-info text-sm mt-4">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="stroke-current shrink-0 h-6 w-6"
                fill="none"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                >
                </path>
              </svg>
              <span>
                Development mode: Check
                <.link href="/dev/mailbox" class="font-semibold underline">mailbox</.link>
                for confirmation emails
              </span>
            </div>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  def mount(_params, session, socket) do
    # Track anonymous visitor session
    if connected?(socket) do
      session_id = session["live_socket_id"] || generate_session_id()

      Presence.track_anonymous(session_id, %{
        connected_at: DateTime.utc_now(),
        ip_address: get_connect_info(socket, :peer_data) |> extract_ip_address(),
        user_agent: get_connect_info(socket, :user_agent),
        current_page: Routes.path("/users/log-in")
      })
    end

    # Get project title and registration setting from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    allow_registration = Settings.get_boolean_setting("allow_registration", true)

    email = Phoenix.Flash.get(socket.assigns.flash, :email)
    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     assign(socket,
       form: form,
       project_title: project_title,
       allow_registration: allow_registration
     ), temporary_assigns: [form: form]}
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
