defmodule PhoenixKitWeb.Users.Registration do
  @moduledoc """
  LiveView for user registration.

  Provides a registration form for new users to create an account.
  Supports referral codes and respects the allow_registration setting.
  Tracks anonymous visitor sessions during registration.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Presence
  alias PhoenixKit.Config
  alias PhoenixKit.ReferralCodes
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.IpAddress
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
          ip_address: IpAddress.extract_from_socket(socket),
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
      ip_address = IpAddress.extract_from_socket(socket)

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
            ip_address = socket.assigns.user_ip_address
            Auth.register_user(user_params, ip_address)
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
    Config.mailer_local?()
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end
end
