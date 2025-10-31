defmodule PhoenixKitWeb.Users.Settings do
  @moduledoc """
  LiveView for user account settings management.

  Allows authenticated users to update their email, password, profile information,
  and personal preferences such as timezone, date format, and time format.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Config
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.OAuth
  alias PhoenixKit.Users.OAuthAvailability
  alias PhoenixKit.Utils.Routes

  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Auth.update_user_email(socket.assigns.phoenix_kit_current_user, token) do
        :ok ->
          put_flash(socket, :info, "Email changed successfully.")

        :error ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: Routes.path("/users/settings"))}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.phoenix_kit_current_user
    email_changeset = Auth.change_user_email(user)
    password_changeset = Auth.change_user_password(user)
    profile_changeset = Auth.change_user_profile(user)

    # Get timezone options from Settings module
    setting_options = Settings.get_setting_options()
    timezone_options = [{"Use System Default", nil} | setting_options["time_zone"]]

    # Load OAuth providers for the user
    oauth_providers = OAuth.get_user_oauth_providers(user.id)
    oauth_available = OAuthAvailability.oauth_available?()

    # Check which providers are available to connect
    available_providers = get_available_oauth_providers(oauth_providers)

    socket =
      socket
      |> assign(:current_password, nil)
      |> assign(:email_form_current_password, nil)
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:profile_form, to_form(profile_changeset))
      |> assign(:timezone_options, timezone_options)
      |> assign(:browser_timezone_name, nil)
      |> assign(:browser_timezone_offset, nil)
      |> assign(:timezone_mismatch_warning, nil)
      |> assign(:trigger_submit, false)
      |> assign(:oauth_providers, oauth_providers)
      |> assign(:oauth_available, oauth_available)
      |> assign(:available_providers, available_providers)

    {:ok, socket}
  end

  def handle_event("validate_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    email_form =
      socket.assigns.phoenix_kit_current_user
      |> Auth.change_user_email(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form, email_form_current_password: password)}
  end

  def handle_event("update_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.phoenix_kit_current_user

    case Auth.apply_user_email(user, password, user_params) do
      {:ok, applied_user} ->
        Auth.deliver_user_update_email_instructions(
          applied_user,
          user.email,
          &Routes.url("/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info) |> assign(email_form_current_password: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, :email_form, to_form(Map.put(changeset, :action, :insert)))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    password_form =
      socket.assigns.phoenix_kit_current_user
      |> Auth.change_user_password(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form, current_password: password)}
  end

  def handle_event("update_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.phoenix_kit_current_user

    case Auth.update_user_password(user, password, user_params) do
      {:ok, user} ->
        password_form =
          user
          |> Auth.change_user_password(user_params)
          |> to_form()

        {:noreply, assign(socket, trigger_submit: true, password_form: password_form)}

      {:error, changeset} ->
        {:noreply, assign(socket, password_form: to_form(changeset))}
    end
  end

  def handle_event("validate_profile", params, socket) do
    %{"user" => user_params} = params

    # Check if browser timezone data is included in the form submission
    socket =
      case {params["browser_timezone_name"], params["browser_timezone_offset"]} do
        {name, offset} when is_binary(name) and is_binary(offset) ->
          socket
          |> assign(:browser_timezone_name, name)
          |> assign(:browser_timezone_offset, offset)

        _ ->
          socket
      end

    profile_form =
      socket.assigns.phoenix_kit_current_user
      |> Auth.change_user_profile(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    # Check for timezone mismatch when user changes timezone
    socket =
      socket
      |> assign(profile_form: profile_form)
      |> check_timezone_mismatch(user_params["user_timezone"])

    {:noreply, socket}
  end

  def handle_event("update_profile", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.phoenix_kit_current_user

    case Auth.update_user_profile(user, user_params) do
      {:ok, _user} ->
        {:noreply, socket |> put_flash(:info, "Profile updated successfully")}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(Map.put(changeset, :action, :insert)))}
    end
  end

  def handle_event("use_browser_timezone", _params, socket) do
    browser_offset = socket.assigns.browser_timezone_offset

    if browser_offset do
      # Update the profile form with browser timezone
      user = socket.assigns.phoenix_kit_current_user
      updated_attrs = %{"user_timezone" => browser_offset}

      profile_form =
        user
        |> Auth.change_user_profile(updated_attrs)
        |> to_form()

      socket =
        socket
        |> assign(:profile_form, profile_form)
        |> assign(:timezone_mismatch_warning, nil)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("connect_oauth_provider", %{"provider" => provider}, socket) do
    # Redirect to OAuth authorization URL
    # Store return_to in session so OAuth callback knows to return here
    oauth_url = Routes.url("/users/auth/#{provider}?return_to=/phoenix_kit/users/settings")

    socket =
      socket
      |> put_flash(:info, "Redirecting to #{format_provider_name(provider)}...")
      |> redirect(external: oauth_url)

    {:noreply, socket}
  end

  def handle_event("disconnect_oauth_provider", %{"provider" => provider}, socket) do
    user = socket.assigns.phoenix_kit_current_user

    # Check if user can safely disconnect this provider
    if can_disconnect_provider?(user, provider) do
      case OAuth.unlink_oauth_provider(user.id, provider) do
        {:ok, _} ->
          # Reload OAuth providers list
          oauth_providers = OAuth.get_user_oauth_providers(user.id)
          available_providers = get_available_oauth_providers(oauth_providers)

          socket =
            socket
            |> assign(:oauth_providers, oauth_providers)
            |> assign(:available_providers, available_providers)
            |> put_flash(
              :info,
              "#{format_provider_name(provider)} account disconnected successfully"
            )

          {:noreply, socket}

        {:error, :not_found} ->
          socket = put_flash(socket, :error, "Provider not found")
          {:noreply, socket}

        {:error, _reason} ->
          socket = put_flash(socket, :error, "Failed to disconnect provider. Please try again.")
          {:noreply, socket}
      end
    else
      # User cannot disconnect - show warning
      warning_message =
        if user.hashed_password == nil do
          "Cannot disconnect #{format_provider_name(provider)}. This is your only sign-in method. Please set a password or connect another provider first."
        else
          "Cannot disconnect #{format_provider_name(provider)}. Please ensure you have at least one sign-in method available."
        end

      socket = put_flash(socket, :error, warning_message)
      {:noreply, socket}
    end
  end

  # Check for timezone mismatch based on current form values
  defp check_timezone_mismatch(socket, selected_timezone) do
    browser_offset = socket.assigns[:browser_timezone_offset]
    browser_name = socket.assigns[:browser_timezone_name]

    # Get selected timezone from parameters or current form value
    user_timezone =
      selected_timezone ||
        get_in(socket.assigns.profile_form.params, ["user_timezone"]) ||
        socket.assigns.phoenix_kit_current_user.user_timezone

    case {browser_offset, user_timezone} do
      {nil, _} ->
        # No browser timezone detected, no warning
        assign(socket, :timezone_mismatch_warning, nil)

      {browser_tz, nil} when browser_tz != "0" ->
        # User selected "Use System Default" but browser is not UTC
        system_tz = Settings.get_setting("time_zone", "0")

        if browser_tz != system_tz do
          warning_msg =
            "Your browser timezone appears to be #{browser_name} (#{format_timezone_offset(browser_tz)}) " <>
              "but you selected 'Use System Default' which is #{format_timezone_offset(system_tz)}."

          assign(socket, :timezone_mismatch_warning, warning_msg)
        else
          assign(socket, :timezone_mismatch_warning, nil)
        end

      {browser_tz, user_tz} when browser_tz != user_tz ->
        # Normalize user timezone for comparison (remove + if present, browser_tz has +)
        normalized_user_tz = String.replace(user_tz, "+", "")
        normalized_browser_tz = String.replace(browser_tz, "+", "")

        # Only show warning if they're actually different (not just formatting)
        if normalized_browser_tz != normalized_user_tz do
          # User selected specific timezone that doesn't match browser
          warning_msg =
            "Your browser timezone appears to be #{browser_name} (#{format_timezone_offset(browser_tz)}) " <>
              "but you selected #{format_timezone_offset(user_tz)}. Please verify this is correct."

          assign(socket, :timezone_mismatch_warning, warning_msg)
        else
          assign(socket, :timezone_mismatch_warning, nil)
        end

      _ ->
        # Timezones match or no significant difference
        assign(socket, :timezone_mismatch_warning, nil)
    end
  end

  # Format timezone offset for display
  defp format_timezone_offset(offset) do
    case offset do
      "0" ->
        "UTC+0"

      "+" <> _ ->
        "UTC" <> offset

      "-" <> _ ->
        "UTC" <> offset

      _ when is_binary(offset) ->
        # If it's a positive number without +, add the +
        case Integer.parse(offset) do
          {num, ""} when num > 0 -> "UTC+" <> offset
          {num, ""} when num < 0 -> "UTC" <> offset
          {0, ""} -> "UTC+0"
          _ -> "UTC" <> offset
        end

      _ ->
        "Unknown"
    end
  end

  defp show_dev_notice? do
    Config.mailer_local?()
  end

  # OAuth helper functions

  defp get_available_oauth_providers(oauth_providers) do
    # Get list of connected provider names
    connected = Enum.map(oauth_providers, & &1.provider)

    # All possible providers
    all_providers = ["google", "apple", "github"]

    # Filter out connected ones and check if each is enabled
    all_providers
    |> Enum.reject(&(&1 in connected))
    |> Enum.filter(&provider_enabled?/1)
  end

  defp provider_enabled?("google"), do: OAuthAvailability.provider_enabled?(:google)
  defp provider_enabled?("apple"), do: OAuthAvailability.provider_enabled?(:apple)
  defp provider_enabled?("github"), do: OAuthAvailability.provider_enabled?(:github)
  defp provider_enabled?(_), do: false

  defp can_disconnect_provider?(user, _provider) do
    # User can disconnect if they have:
    # 1. A password set, OR
    # 2. Multiple OAuth providers connected

    has_password = user.hashed_password != nil
    oauth_count = length(OAuth.get_user_oauth_providers(user.id))

    has_password or oauth_count > 1
  end

  defp format_provider_name("google"), do: "Google"
  defp format_provider_name("apple"), do: "Apple"
  defp format_provider_name("github"), do: "GitHub"
  defp format_provider_name(provider), do: String.capitalize(provider)
end
