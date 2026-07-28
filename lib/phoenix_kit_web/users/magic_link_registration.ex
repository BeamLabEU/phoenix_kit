defmodule PhoenixKitWeb.Users.MagicLinkRegistration do
  @moduledoc """
  LiveView for magic link registration completion form.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Users.Referrals
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: WebAuth

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case WebAuth.maybe_redirect_authenticated(socket) do
      {:redirect, socket} ->
        {:ok, socket}

      :cont ->
        case MagicLinkRegistration.verify_registration_token(token) do
          {:ok, email} ->
            # Get referral codes configuration
            referral_codes_config = Referrals.get_config()

            # Generate username suggestion from email
            suggested_username = User.generate_username_from_email(email)

            changeset =
              Auth.change_user_registration(%User{
                email: email,
                username: suggested_username
              })

            # Extract IP address for geolocation
            ip_address =
              case get_connect_info(socket, :peer_data) do
                %{address: {a, b, c, d}} -> "#{a}.#{b}.#{c}.#{d}"
                %{address: address} -> to_string(address)
                _ -> "unknown"
              end

            {:ok,
             socket
             |> assign(:page_title, "Complete Registration")
             |> assign(:token, token)
             |> assign(:email, email)
             |> assign(:ip_address, ip_address)
             |> assign(:referral_codes_enabled, referral_codes_config.enabled)
             |> assign(:referral_codes_required, referral_codes_config.required)
             |> assign(:referral_code, nil)
             |> assign(:referral_code_error, nil)
             |> assign(:trigger_submit, false)
             |> assign(:check_errors, false)
             |> assign(:remember_me_available, WebAuth.remember_me_enabled?())
             |> assign(:remember_me, WebAuth.remember_me_default?())
             |> assign_form(changeset)}

          {:error, _} ->
            {:ok,
             socket
             |> put_flash(:error, "Registration link is invalid or has expired.")
             |> redirect(to: Routes.path("/users/register"))}
        end
    end
  end

  @impl true
  def handle_event("validate", %{"user" => user_params} = params, socket) do
    referral_code = params["referral_code"]
    user_params = form_params(user_params)

    # Track the checkbox across re-renders so unticking it sticks.
    socket = assign(socket, :remember_me, user_params["remember_me"] == "true")

    case validate_referral_code(referral_code, socket) do
      {:ok, _} ->
        socket =
          socket
          |> assign(referral_code: referral_code)
          |> assign(referral_code_error: nil)

        changeset =
          %User{email: socket.assigns.email}
          |> Auth.change_user_registration(user_params)
          |> Map.put(:action, :validate)

        {:noreply, assign_form(socket, changeset)}

      {:error, error_message} ->
        socket =
          socket
          |> assign(referral_code: referral_code)
          |> assign(referral_code_error: error_message)

        changeset =
          %User{email: socket.assigns.email}
          |> Auth.change_user_registration(user_params)
          |> Map.put(:action, :validate)

        {:noreply, assign_form(socket, changeset)}
    end
  end

  @impl true
  def handle_event("save", %{"user" => user_params} = params, socket) do
    referral_code = params["referral_code"]
    user_params = form_params(user_params)

    case validate_referral_code(referral_code, socket) do
      {:ok, _validated_code} ->
        # Add referral_code to user params
        user_params =
          if referral_code && String.trim(referral_code) != "" do
            Map.put(user_params, "referral_code", referral_code)
          else
            user_params
          end

        # Complete registration
        case MagicLinkRegistration.complete_registration(
               socket.assigns.token,
               user_params,
               socket.assigns.ip_address
             ) do
          {:ok, user} ->
            changeset = Auth.change_user_registration(user)
            {:noreply, socket |> assign(trigger_submit: true) |> assign_form(changeset)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, socket |> assign(check_errors: true) |> assign_form(changeset)}

          # `complete_registration/3` also returns bare atoms — `:invalid_token`
          # once the token expires while the form sits open, and
          # `:email_already_exists` if the address is claimed in between.
          # Without these clauses either outcome was a CaseClauseError.
          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, completion_error_message(reason))
             |> redirect(to: Routes.path("/users/register/magic-link"))}
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

  defp completion_error_message(:email_already_exists),
    do: "That email is already registered. Please log in instead."

  defp completion_error_message(_),
    do: "Registration link is invalid or has expired. Please request a new one."

  # Only what this form legitimately owns. `registration_changeset/3` also casts
  # `custom_fields` and the geo columns — fine for server-side callers, but a
  # phx-submit payload is whatever the client sends.
  @form_fields ~w(email username password first_name last_name account_type
                  organization_name user_timezone remember_me return_to)

  defp form_params(user_params) when is_map(user_params),
    do: Map.take(user_params, @form_fields)

  defp form_params(other), do: other

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
      not socket.assigns.referral_codes_enabled ->
        {:ok, nil}

      socket.assigns.referral_codes_required and
          (is_nil(referral_code) or String.trim(referral_code) == "") ->
        {:error, "Referral code is required"}

      referral_code && String.trim(referral_code) != "" ->
        validate_referral_code_value(String.trim(referral_code))

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
end
