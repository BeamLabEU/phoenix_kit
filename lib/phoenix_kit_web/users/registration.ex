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
  alias PhoenixKit.Users.EmailDomain
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.Referrals
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: WebAuth
  alias PhoenixKitWeb.Users.AuthSEO
  alias PhoenixKitWeb.Users.BotCheck

  def mount(params, session, socket) do
    socket = assign(socket, :page_title, gettext("Register"))

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

      # Parse invitation token from URL params
      invitation_token = Map.get(params, "invitation")
      pending_invitation = load_pending_invitation(invitation_token)

      # What this form is allowed to create — see `account_type_mode/1`.
      account_type_mode = account_type_mode(pending_invitation)

      # Seeded with the type the site fixes, so the form renders the
      # Organization Name field from the first paint in organization-only mode
      # (the changeset carries no `:action` yet, so its "can't be blank" does
      # not display until the visitor submits).
      changeset =
        Auth.change_user_registration(%User{
          account_type: default_account_type(account_type_mode)
        })

      # Extract and store IP address during mount for later use
      ip_address = IpAddress.extract_from_socket(socket)

      seo = AuthSEO.seo_assigns("/users/register")

      # Support return_to query param for post-registration redirect
      # (mirrors the login page; wins over the after_registration_path setting)
      return_to = sanitize_return_to(params["return_to"])

      socket =
        socket
        |> assign(trigger_submit: false, check_errors: false)
        |> assign(username_edited: false)
        |> assign(project_title: project_title)
        |> assign(canonical_url: seo.canonical_url)
        |> assign(hreflang_links: seo.hreflang_links)
        |> assign(referral_codes_enabled: referral_codes_config.enabled)
        |> assign(referral_codes_required: referral_codes_config.required)
        |> assign(referral_code: nil)
        |> assign(referral_code_error: nil)
        |> assign(user_ip_address: ip_address)
        |> assign(magic_link_registration_enabled: magic_link_registration_enabled)
        |> assign(show_username: show_username)
        |> assign(account_type_mode: account_type_mode)
        |> assign(account_type_selectable: account_type_mode == "choice")
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
          gettext("User registration is currently disabled. Please contact an administrator.")
        )
        |> redirect(to: Routes.path("/users/log-in"))

      {:ok, socket}
    end
  end

  # An anonymous visitor's request: counted against the site-wide sign-up cap,
  # and the address's domain is asked for in DNS.
  @public_door [site_wide: true, check_email_domain: true]

  def handle_event("save", %{"user" => user_params} = params, socket) do
    if Settings.get_boolean_setting("allow_registration", true) do
      case BotCheck.run(socket, params, socket.assigns[:user_ip_address]) do
        {:ok, socket} -> do_save(user_params, params, socket)
        {:error, socket} -> {:noreply, socket}
      end
    else
      # Re-checked here, not just in mount/3. A LiveView socket outlives the
      # page load that created it, so a form mounted while registration was open
      # keeps a working submit endpoint for as long as the tab stays open —
      # closing registration has to close the submit, not only the entrance.
      {:noreply,
       socket
       |> put_flash(:error, gettext("Registration is currently disabled."))
       |> redirect(to: Routes.path("/users/log-in"))}
    end
  end

  # The hint under the email field, taken. The form is a temporary assign (it
  # holds the typed password), so it cannot be rebuilt here: the browser is
  # told to put the address into the field, and the field's own change event
  # brings the whole form back through "validate".
  def handle_event("use_email_suggestion", _params, socket) do
    case socket.assigns[:email_suggestion] do
      suggestion when is_binary(suggestion) ->
        {:noreply,
         socket
         |> assign(:email_suggestion, nil)
         |> push_event("phoenix_kit:set_input", %{id: "user_email", value: suggestion})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("validate", %{"user" => user_params} = params, socket) do
    referral_code = params["referral_code"]
    user_params = form_params(user_params, socket.assigns.account_type_mode)

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
    case validate_referral_code(referral_code, socket, :change) do
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

  defp do_save(user_params, params, socket) do
    referral_code = params["referral_code"]
    user_params = form_params(user_params, socket.assigns.account_type_mode)

    # If the username was never manually edited, let the schema (re)generate it
    # from the final email rather than persisting a possibly-stale preview value.
    user_params = maybe_sync_username(user_params, socket.assigns.username_edited)

    # Validate referral code if system is enabled
    case validate_referral_code(referral_code, socket, :submit) do
      {:ok, validated_code} ->
        # Check if geolocation tracking is enabled
        track_geolocation = Settings.get_boolean_setting("track_registration_geolocation", false)
        ip_address = socket.assigns.user_ip_address

        # Use appropriate registration function based on geolocation setting
        registration_result =
          if track_geolocation do
            Auth.register_user_with_geolocation(user_params, ip_address, @public_door)
          else
            Auth.register_user(user_params, ip_address, @public_door)
          end

        case registration_result do
          {:ok, user} ->
            # The page's language becomes theirs, so their mail is in it.
            user = Auth.remember_page_locale(user, socket.assigns[:current_locale])

            # Records the use AND marks the account as having satisfied
            # invite-only, so a code supplied here is not asked for again by
            # the access gate.
            Referrals.record_signup_use(user, validated_code)

            # Store invitation UUID in custom_fields for auto-accept after email
            # confirmation — only when the address registered IS the invited one;
            # a forwarded invite link must not enrol an arbitrary address.
            if invitation_for?(socket.assigns[:pending_invitation], user) do
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
                   &Routes.url("/users/confirm/#{&1}"),
                   locale: socket.assigns[:current_locale]
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

    # "Did you mean …@gmail.com?" under the email field. A pure rule over the
    # typed text (no DNS, no lookup), so it is safe on every keystroke.
    socket =
      assign(
        socket,
        :email_suggestion,
        EmailDomain.suggestion(Ecto.Changeset.get_field(changeset, :email))
      )

    if changeset.valid? do
      assign(socket, form: form, check_errors: false)
    else
      assign(socket, form: form)
    end
  end

  # `context` is `:change` while the user types and `:submit` on the final
  # attempt. See `PhoenixKit.Users.Referrals.validate_for_signup/2` for why the
  # two differ and why every rejection reads the same.
  defp validate_referral_code(referral_code, socket, context) do
    Referrals.validate_for_signup(referral_code,
      enabled?: socket.assigns.referral_codes_enabled,
      required?: socket.assigns.referral_codes_required,
      context: context,
      ip_address: socket.assigns[:user_ip_address]
    )
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

  defp form_params(user_params, mode) when is_map(user_params) do
    user_params
    |> Map.take(@form_fields)
    |> Auth.enforce_registration_account_type(mode)
  end

  defp form_params(other, _mode), do: other

  # The site policy, with one local override: a visitor arriving on an
  # organization invitation is joining an organization that already exists.
  # Letting them pick "Organization" would create a SECOND one — and an
  # organization account cannot hold an `organization_uuid`
  # (`validate_organization_fields/1` nils it), so the invitation could never
  # be redeemed afterwards.
  defp account_type_mode(nil), do: Auth.registration_account_type()
  defp account_type_mode(_pending_invitation), do: "person"

  defp default_account_type("organization"), do: "organization"
  defp default_account_type(_mode), do: "person"

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

  defp invitation_for?(nil, _user), do: false
  defp invitation_for?(invitation, user), do: Invitations.invitee?(invitation, user)

  defp load_pending_invitation(nil), do: nil

  defp load_pending_invitation(token) when is_binary(token) do
    case Invitations.get_by_token(token) do
      {:ok, invitation} -> invitation
      {:error, _} -> nil
    end
  end
end
