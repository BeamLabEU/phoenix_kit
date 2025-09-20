defmodule PhoenixKitWeb.Users.RegistrationLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Presence
  alias PhoenixKit.ReferralCodes
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Routes

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="{@project_title} - Create account"
    >
      <div class="flex items-center justify-center py-8 min-h-[80vh] bg-base-200">
        <div class="card bg-base-100 w-full max-w-sm shadow-2xl">
          <div class="card-body">
            <h1 class="text-2xl font-bold text-center mb-6">{@project_title} Create account</h1>

            <.form
              for={@form}
              id="registration_form"
              phx-submit="save"
              phx-change="validate"
              phx-trigger-action={@trigger_submit}
              action={Routes.path("/users/log-in?_action=registered")}
              method="post"
            >
              <fieldset class="fieldset">
                <legend class="fieldset-legend sr-only">Account Information</legend>

                <div :if={@check_errors} class="alert alert-error text-sm mb-4">
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
                      d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  <span>Oops, something went wrong! Please check the errors below.</span>
                </div>

                <div phx-feedback-for="user[email]">
                  <.label for="user_email">Email</.label>
                  <.input
                    field={@form[:email]}
                    type="email"
                    placeholder="Enter your email address"
                    required
                  />
                </div>

                <%!-- Username Field (optional) --%>
                <div phx-feedback-for="user[username]">
                  <.label for="user_username">Username</.label>
                  <.input
                    field={@form[:username]}
                    type="text"
                    placeholder="Choose a unique username (optional)"
                  />
                  <div class="text-xs text-base-content/60 mt-1">
                    If not provided, we'll generate one from your email
                  </div>
                </div>

                <%!-- Referral Code Field (shown when referral codes are enabled) --%>
                <%= if @referral_codes_enabled do %>
                  <div phx-feedback-for="referral_code">
                    <.label for="referral_code">
                      Referral Code<%= if @referral_codes_required do %>
                        *
                      <% end %>
                    </.label>
                    <input
                      id="referral_code"
                      name="referral_code"
                      type="text"
                      class={[
                        "input input-bordered",
                        (@referral_code_error ||
                           (@check_errors && @referral_codes_required &&
                              (is_nil(@referral_code) || @referral_code == ""))) && "input-error"
                      ]}
                      placeholder="Enter your referral code"
                      value={@referral_code || ""}
                      required={@referral_codes_required}
                    />
                    <%= if @referral_code_error do %>
                      <.error>{@referral_code_error}</.error>
                    <% end %>
                  </div>
                <% end %>

                <div phx-feedback-for="user[password]">
                  <.label for="user_password">Password</.label>
                  <.input
                    field={@form[:password]}
                    type="password"
                    placeholder="Choose a secure password"
                    required
                  />
                </div>

                <button
                  type="submit"
                  phx-disable-with="Creating account..."
                  class="btn btn-primary w-full mt-4"
                >
                  Create account <span aria-hidden="true">→</span>
                </button>
              </fieldset>
            </.form>
            
    <!-- Login link -->
            <div class="text-center mt-4 text-sm">
              <span>Already have an account? </span>
              <.link
                navigate={Routes.path("/users/log-in")}
                class="font-semibold text-primary hover:underline"
              >
                Sign in
              </.link>
            </div>
            
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
    # Check if registration is allowed
    allow_registration = Settings.get_boolean_setting("allow_registration", true)

    if not allow_registration do
      socket =
        socket
        |> put_flash(
          :error,
          "User registration is currently disabled. Please contact an administrator."
        )
        |> redirect(to: Routes.path("/users/log-in"))

      {:ok, socket}
    else
      # Extract IP address for registration analytics
      ip_address = PhoenixKit.Utils.Geolocation.extract_ip_from_socket(socket)

      # Track anonymous visitor session
      if connected?(socket) do
        session_id = session["live_socket_id"] || generate_session_id()

        Presence.track_anonymous(session_id, %{
          connected_at: DateTime.utc_now(),
          ip_address: ip_address,
          user_agent: get_connect_info(socket, :user_agent),
          current_page: Routes.path("/users/register")
        })
      end

      # Get project title from settings
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      # Get referral codes configuration
      referral_codes_config = ReferralCodes.get_config()

      changeset = Auth.change_user_registration(%User{})

      socket =
        socket
        |> assign(trigger_submit: false, check_errors: false)
        |> assign(project_title: project_title)
        |> assign(referral_codes_enabled: referral_codes_config.enabled)
        |> assign(referral_codes_required: referral_codes_config.required)
        |> assign(referral_code: nil)
        |> assign(referral_code_error: nil)
        |> assign(user_ip_address: ip_address)
        |> assign_form(changeset)

      {:ok, socket, temporary_assigns: [form: nil]}
    end
  end

  def handle_event("save", %{"user" => user_params} = params, socket) do
    referral_code = params["referral_code"]

    # Validate referral code if system is enabled
    case validate_referral_code(referral_code, socket) do
      {:ok, validated_code} ->
        # Check if geolocation tracking is enabled
        track_geolocation = Settings.get_boolean_setting("track_registration_geolocation", false)

        registration_result =
          if track_geolocation do
            Auth.register_user_with_geolocation(user_params, socket.assigns.user_ip_address)
          else
            Auth.register_user(user_params)
          end

        case registration_result do
          {:ok, user} ->
            # Record referral code usage if provided and valid
            if validated_code do
              ReferralCodes.use_code(validated_code.code, user.id)
            end

            case Auth.deliver_user_confirmation_instructions(
                   user,
                   &Routes.url("/users/confirm/#{&1}")
                 ) do
              {:ok, _} ->
                # Email sent successfully
                :ok

              {:error, error} ->
                # Log error but don't fail registration
                require Logger
                Logger.error("Failed to send confirmation email: #{inspect(error)}")
                :ok
            end

            changeset = Auth.change_user_registration(user)
            {:noreply, socket |> assign(trigger_submit: true) |> assign_form(changeset)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, socket |> assign(check_errors: true) |> assign_form(changeset)}
        end

      {:error, error_message} ->
        socket =
          socket
          |> assign(referral_code: referral_code)
          |> assign(referral_code_error: error_message)
          |> assign(check_errors: true)

        {:noreply, socket}
    end
  end

  def handle_event("validate", %{"user" => user_params} = params, socket) do
    referral_code = params["referral_code"]

    # Validate referral code and update error state
    case validate_referral_code(referral_code, socket) do
      {:ok, _} ->
        socket =
          socket
          |> assign(referral_code: referral_code)
          |> assign(referral_code_error: nil)

        changeset = Auth.change_user_registration(%User{}, user_params)
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}

      {:error, error_message} ->
        socket =
          socket
          |> assign(referral_code: referral_code)
          |> assign(referral_code_error: error_message)

        changeset = Auth.change_user_registration(%User{}, user_params)
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")

    if changeset.valid? do
      assign(socket, form: form, check_errors: false)
    else
      assign(socket, form: form)
    end
  end

  defp validate_referral_code(referral_code, socket) do
    cond do
      # If referral codes are disabled, always allow registration
      not socket.assigns.referral_codes_enabled ->
        {:ok, nil}

      # If referral codes are required but none provided
      socket.assigns.referral_codes_required and
          (is_nil(referral_code) or String.trim(referral_code) == "") ->
        {:error, "Referral code is required"}

      # If referral code is provided, validate it
      referral_code && String.trim(referral_code) != "" ->
        validate_referral_code_value(String.trim(referral_code))

      # If referral codes are optional and none provided
      true ->
        {:ok, nil}
    end
  end

  defp validate_referral_code_value(code_string) do
    case ReferralCodes.get_code_by_string(code_string) do
      nil ->
        {:error, "Invalid referral code"}

      code ->
        cond do
          not code.status ->
            {:error, "This referral code is no longer active"}

          PhoenixKit.ReferralCodes.expired?(code) ->
            {:error, "This referral code has expired"}

          PhoenixKit.ReferralCodes.usage_limit_reached?(code) ->
            {:error, "This referral code has reached its usage limit"}

          true ->
            {:ok, code}
        end
    end
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
end
