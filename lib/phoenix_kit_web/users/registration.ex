defmodule PhoenixKitWeb.Users.Registration do
  @moduledoc """
  LiveView for user registration.

  Provides a registration form for new users to create an account.
  Supports referral codes and respects the allow_registration setting.
  Tracks anonymous visitor sessions during registration.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Presence
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.Referrals
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: WebAuth

  def mount(params, session, socket) do
    case WebAuth.maybe_redirect_authenticated(socket) do
      {:redirect, socket} ->
        {:ok, socket}

      :cont ->
        do_mount(params, session, socket)
    end
  end

  defp do_mount(params, session, socket) do
    # Check if registration is allowed
    allow_registration = Settings.get_boolean_setting("allow_registration", true)

    if allow_registration do
      # Track anonymous visitor session
      if connected?(socket) do
        session_id = session["live_socket_id"] || generate_session_id()

        Presence.track_anonymous(session_id, %{
          connected_at: UtilsDate.utc_now(),
          ip_address: IpAddress.extract_from_socket(socket),
          user_agent: get_connect_info(socket, :user_agent),
          current_page: Routes.path("/users/register")
        })
      end

      # Get project title from settings (with Config fallback)
      project_title = PhoenixKit.Settings.get_project_title()

      # Get referral codes configuration
      referral_codes_config = Referrals.get_config()

      # Get Magic Link registration setting
      magic_link_registration_enabled =
        Settings.get_boolean_setting("magic_link_registration_enabled", true)

      # Get username field visibility setting
      show_username = Settings.get_setting("registration_show_username", "true") != "false"

      # Get organization accounts setting
      org_accounts_enabled =
        Settings.get_boolean_setting("enable_organization_accounts", false)

      changeset = Auth.change_user_registration(%User{})

      # Extract and store IP address during mount for later use
      ip_address = IpAddress.extract_from_socket(socket)

      # Parse invitation token from URL params
      invitation_token = Map.get(params, "invitation")
      pending_invitation = load_pending_invitation(invitation_token)

      # Support return_to query param for post-registration redirect
      # (mirrors the login page; wins over the after_registration_path setting)
      return_to = sanitize_return_to(params["return_to"])

      socket =
        socket
        |> assign(trigger_submit: false, check_errors: false)
        |> assign(username_edited: false)
        |> assign(project_title: project_title)
        |> assign(referral_codes_enabled: referral_codes_config.enabled)
        |> assign(referral_codes_required: referral_codes_config.required)
        |> assign(referral_code: nil)
        |> assign(referral_code_error: nil)
        |> assign(user_ip_address: ip_address)
        |> assign(magic_link_registration_enabled: magic_link_registration_enabled)
        |> assign(show_username: show_username)
        |> assign(org_accounts_enabled: org_accounts_enabled)
        |> assign(pending_invitation: pending_invitation)
        |> assign(pending_invitation_token: invitation_token)
        |> assign(return_to: return_to)
        |> assign(remember_me_available: WebAuth.remember_me_enabled?())
        |> assign(remember_me: WebAuth.remember_me_default?())
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
    user_params = form_params(user_params)

    # If the username was never manually edited, let the schema (re)generate it
    # from the final email rather than persisting a possibly-stale preview value.
    user_params = maybe_sync_username(user_params, socket.assigns.username_edited)

    # Validate referral code if system is enabled
    case validate_referral_code(referral_code, socket) do
      {:ok, validated_code} ->
        # Check if geolocation tracking is enabled
        track_geolocation = Settings.get_boolean_setting("track_registration_geolocation", false)
        ip_address = socket.assigns.user_ip_address

        # Use appropriate registration function based on geolocation setting
        registration_result =
          if track_geolocation do
            Auth.register_user_with_geolocation(user_params, ip_address)
          else
            Auth.register_user(user_params, ip_address)
          end

        case registration_result do
          {:ok, user} ->
            # Record referral code usage if provided and valid
            if validated_code do
              Referrals.use_code(validated_code.code, user.uuid)
            end

            # Store invitation UUID in custom_fields for auto-accept after email confirmation
            if socket.assigns[:pending_invitation] do
              Auth.update_user_fields(user, %{
                "pending_invitation_uuid" => socket.assigns.pending_invitation.uuid
              })

              # That auto-accept only fires from `confirm_user/1`. With
              # confirmation not required there is no confirmation step, so
              # accept now or the invitation is never redeemed.
              maybe_accept_invitation_without_confirmation(user)
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

            PhoenixKit.Activity.log(%{
              action: "user.registered",
              module: "users",
              mode: "manual",
              actor_uuid: user.uuid,
              resource_type: "user",
              resource_uuid: user.uuid,
              metadata: %{"method" => "self_registration", "actor_role" => "user"}
            })

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
    user_params = form_params(user_params)

    # Track whether the user owns the username field, then keep it in sync with
    # the email while it's still auto-managed.
    username_edited = username_manually_edited?(socket, params, user_params)
    user_params = maybe_sync_username(user_params, username_edited)

    # The form re-renders on every change, so the checkbox has to be driven by
    # what the user actually left it at — otherwise unticking it would snap
    # back to the site default on the next keystroke.
    socket =
      socket
      |> assign(username_edited: username_edited)
      |> assign(remember_me: user_params["remember_me"] == "true")

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

  # Determines whether the user has taken manual ownership of the username field.
  #
  # `phx-change` reports the touched field in `_target`. Typing a non-empty value
  # into the username field claims it (auto-sync stops); clearing it releases
  # ownership so auto-sync from email resumes. Any other field leaves the current
  # ownership state untouched.
  defp username_manually_edited?(socket, params, user_params) do
    case params["_target"] do
      ["user", "username"] -> String.trim(user_params["username"] || "") != ""
      _ -> socket.assigns.username_edited
    end
  end

  # While the username is still auto-managed, blank it so the registration
  # changeset regenerates it from the (possibly just-corrected) email. Once the
  # user owns the field, their value is passed through unchanged.
  defp maybe_sync_username(user_params, true = _username_edited), do: user_params

  defp maybe_sync_username(user_params, false = _username_edited),
    do: Map.put(user_params, "username", "")

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
    case Referrals.get_code_by_string(code_string) do
      nil ->
        {:error, "Invalid referral code"}

      code ->
        cond do
          not code.status ->
            {:error, "This referral code is no longer active"}

          Referrals.expired?(code) ->
            {:error, "This referral code has expired"}

          Referrals.usage_limit_reached?(code) ->
            {:error, "This referral code has reached its usage limit"}

          true ->
            {:ok, code}
        end
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end

  # Only allow relative paths to prevent open redirect attacks
  defp sanitize_return_to(path) do
    if Routes.local_path?(path), do: path, else: nil
  end

  # Fields the public form is allowed to set. `registration_changeset/3` also
  # casts `custom_fields` and the `registration_*` geo columns — legitimate for
  # server-side callers (OAuth, the geolocation path) but attacker-controlled
  # here, since a phx-submit payload is whatever the client sends. Writing
  # `custom_fields` from the browser would let a visitor plant
  # `pending_invitation_uuid` or an `oauth_avatar_url` that the admin user list
  # renders as an <img src>.
  @form_fields ~w(email username password first_name last_name account_type
                  organization_name user_timezone remember_me return_to)

  defp form_params(user_params) when is_map(user_params),
    do: Map.take(user_params, @form_fields)

  defp form_params(other), do: other

  defp maybe_accept_invitation_without_confirmation(user) do
    if Settings.get_boolean_setting("require_email_confirmation", true) do
      :ok
    else
      user = Auth.get_user(user.uuid) || user
      uuid = user.custom_fields && user.custom_fields["pending_invitation_uuid"]

      case uuid && Invitations.accept_invitation_by_uuid(uuid, user) do
        {:ok, _} ->
          Auth.update_user_fields(user, %{"pending_invitation_uuid" => nil})
          :ok

        _ ->
          :ok
      end
    end
  end

  defp load_pending_invitation(nil), do: nil

  defp load_pending_invitation(token) when is_binary(token) do
    case Invitations.get_by_token(token) do
      {:ok, invitation} -> invitation
      {:error, _} -> nil
    end
  end
end
