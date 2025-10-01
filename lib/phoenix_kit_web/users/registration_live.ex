defmodule PhoenixKitWeb.Users.RegistrationLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Presence
  alias PhoenixKit.ReferralCodes
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Routes

  def mount(_params, session, socket) do
    # Check if registration is allowed
    allow_registration = Settings.get_boolean_setting("allow_registration", true)

    if allow_registration do
      # Track anonymous visitor session
      if connected?(socket) do
        session_id = session["live_socket_id"] || generate_session_id()

        Presence.track_anonymous(session_id, %{
          connected_at: DateTime.utc_now(),
          ip_address: get_connect_info(socket, :peer_data) |> extract_ip_address(),
          user_agent: get_connect_info(socket, :user_agent),
          current_page: Routes.path("/users/register")
        })
      end

      # Get project title from settings
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      # Get referral codes configuration
      referral_codes_config = ReferralCodes.get_config()

      # Get Magic Link registration setting
      magic_link_registration_enabled =
        Settings.get_boolean_setting("magic_link_registration_enabled", true)

      changeset = Auth.change_user_registration(%User{})

      # Extract and store IP address during mount for later use
      ip_address = extract_ip_address(get_connect_info(socket, :peer_data))

      socket =
        socket
        |> assign(trigger_submit: false, check_errors: false)
        |> assign(project_title: project_title)
        |> assign(referral_codes_enabled: referral_codes_config.enabled)
        |> assign(referral_codes_required: referral_codes_config.required)
        |> assign(referral_code: nil)
        |> assign(referral_code_error: nil)
        |> assign(user_ip_address: ip_address)
        |> assign(magic_link_registration_enabled: magic_link_registration_enabled)
        |> assign_form(changeset)

      {:ok, socket, temporary_assigns: [form: nil]}
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

  def handle_event("save", %{"user" => user_params} = params, socket) do
    referral_code = params["referral_code"]

    # Validate referral code if system is enabled
    case validate_referral_code(referral_code, socket) do
      {:ok, validated_code} ->
        # Check if geolocation tracking is enabled
        track_geolocation = Settings.get_boolean_setting("track_registration_geolocation", false)

        # Use appropriate registration function based on geolocation setting
        registration_result =
          if track_geolocation do
            ip_address = socket.assigns.user_ip_address
            Auth.register_user_with_geolocation(user_params, ip_address)
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

  defp extract_ip_address(nil), do: "unknown"
  defp extract_ip_address(%{address: {a, b, c, d}}), do: "#{a}.#{b}.#{c}.#{d}"
  defp extract_ip_address(%{address: address}), do: to_string(address)
  defp extract_ip_address(_), do: "unknown"

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="{@project_title} - Create account"
    >
      <div class="flex items-center justify-center py-8 min-h-[80vh]">
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
                  <PhoenixKitWeb.Components.Core.Icons.icon_error_circle class="stroke-current shrink-0 h-6 w-6" />
                  <span>Oops, something went wrong! Please check the errors below.</span>
                </div>

                <div phx-feedback-for="user[email]">
                  <label class="label" for="user_email">
                    <span class="label-text flex items-center">
                      <PhoenixKitWeb.Components.Core.Icons.icon_email class="w-4 h-4 mr-2" /> Email
                    </span>
                  </label>
                  <.input
                    field={@form[:email]}
                    type="email"
                    placeholder="Enter your email address"
                    autocomplete="email"
                    class="transition-colors focus:input-primary"
                    required
                  />
                </div>

                <%!-- Username Field (optional) --%>
                <div phx-feedback-for="user[username]">
                  <label class="label" for="user_username">
                    <span class="label-text flex items-center">
                      <PhoenixKitWeb.Components.Core.Icons.icon_user_profile class="w-4 h-4 mr-2" />
                      Username
                    </span>
                  </label>
                  <.input
                    field={@form[:username]}
                    type="text"
                    placeholder="Choose a unique username (optional)"
                    autocomplete="username"
                    class="transition-colors focus:input-primary"
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
                  <label class="label" for="user_password">
                    <span class="label-text flex items-center">
                      <PhoenixKitWeb.Components.Core.Icons.icon_lock class="w-4 h-4 mr-2" /> Password
                    </span>
                  </label>
                  <.input
                    field={@form[:password]}
                    type="password"
                    placeholder="Choose a secure password"
                    autocomplete="new-password"
                    class="transition-colors focus:input-primary"
                    required
                  />
                </div>

                <button
                  type="submit"
                  phx-disable-with="Creating account..."
                  class="btn btn-primary w-full mt-4 transition-all hover:scale-[1.02] active:scale-[0.98]"
                >
                  <PhoenixKitWeb.Components.Core.Icons.icon_user_add class="w-5 h-5 mr-2" />
                  Create account <span aria-hidden="true">→</span>
                </button>
              </fieldset>
            </.form>

            <%!-- Alternative registration methods --%>
            <%!-- Only show this section if at least one alternative method is available --%>
            <%= if @magic_link_registration_enabled or PhoenixKit.Users.OAuthAvailability.oauth_available?() do %>
              <div class="mt-6">
                <div class="relative">
                  <div class="absolute inset-0 flex items-center">
                    <div class="w-full border-t border-base-300" />
                  </div>
                  <div class="relative flex justify-center text-sm">
                    <span class="px-2 bg-base-100 text-base-content/60">Or continue with</span>
                  </div>
                </div>

                <div class="mt-4 space-y-2">
                  <%!-- Magic Link Registration --%>
                  <%= if @magic_link_registration_enabled do %>
                    <.link
                      navigate={Routes.path("/users/register/magic-link")}
                      class="btn btn-outline w-full transition-all hover:scale-[1.02] active:scale-[0.98] hover:shadow-lg"
                    >
                      <PhoenixKitWeb.Components.Core.Icons.icon_email class="w-5 h-5 mr-2" />
                      Register with Magic Link
                    </.link>
                  <% end %>
                  <%!-- OAuth authentication --%>
                  <PhoenixKitWeb.Components.OAuthButtons.oauth_buttons show_divider={false} />
                </div>
              </div>
            <% end %>

            <%!-- Login link --%>
            <div class="text-center mt-4 text-sm">
              <span>Already have an account? </span>
              <.link
                navigate={Routes.path("/users/log-in")}
                class="font-semibold text-primary hover:underline"
              >
                Sign in
              </.link>
            </div>

            <%!-- Development Mode Notice --%>
            <div :if={show_dev_notice?()} class="alert alert-info text-sm mt-4">
              <PhoenixKitWeb.Components.Core.Icons.icon_info class="stroke-current shrink-0 h-6 w-6" />
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
end
