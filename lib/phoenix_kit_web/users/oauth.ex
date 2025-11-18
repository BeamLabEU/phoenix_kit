if Code.ensure_loaded?(Ueberauth) do
  defmodule PhoenixKitWeb.Users.OAuth do
    @moduledoc """
    OAuth authentication controller using Ueberauth.

    This controller requires the following optional dependencies to be installed:
    - ueberauth
    - ueberauth_google (for Google Sign-In)
    - ueberauth_apple (for Apple Sign-In)

    If these dependencies are not installed, a fallback controller will be used instead.
    """

    use PhoenixKitWeb, :controller

    plug PhoenixKitWeb.Plugs.EnsureOAuthScheme
    # Ensure OAuth config is loaded before Ueberauth plug runs
    # This prevents MatchError if configuration is missing
    plug PhoenixKitWeb.Plugs.EnsureOAuthConfig
    plug Ueberauth

    alias PhoenixKit.Config
    alias PhoenixKit.Settings
    alias PhoenixKit.Users.OAuth
    alias PhoenixKit.Utils.IpAddress
    alias PhoenixKit.Utils.Routes
    alias PhoenixKitWeb.Users.Auth, as: UserAuth

    require Logger

    @doc """
    Initiates OAuth authentication flow.
    """
    def request(conn, %{"provider" => provider} = params) do
      Logger.debug("PhoenixKit OAuth request for provider: #{provider}")

      # Check if OAuth is enabled in settings
      if oauth_enabled_in_settings?() do
        # Check if OAuth is properly configured
        case get_ueberauth_providers() do
          [] ->
            Logger.warning("PhoenixKit OAuth: No providers configured")

            conn
            |> put_flash(
              :error,
              "OAuth authentication is not configured. To enable OAuth, please add provider configuration to your config.exs file. See PhoenixKit documentation for details."
            )
            |> redirect(to: Routes.path("/users/log-in"))

          providers when providers != [] ->
            provider_names =
              Enum.map(providers, fn {provider, _strategy} -> to_string(provider) end)

            Logger.debug("PhoenixKit OAuth: Available providers: #{inspect(provider_names)}")

            if provider in provider_names do
              handle_oauth_request(conn, params)
            else
              Logger.warning(
                "PhoenixKit OAuth: Provider '#{provider}' not in configured providers: #{inspect(provider_names)}"
              )

              conn
              |> put_flash(
                :error,
                "Provider '#{provider}' is not configured. Available providers: #{Enum.join(provider_names, ", ")}"
              )
              |> redirect(to: Routes.path("/users/log-in"))
            end

          error ->
            Logger.error("PhoenixKit OAuth: Configuration error: #{inspect(error)}")

            conn
            |> put_flash(:error, "OAuth configuration error. Please contact your administrator.")
            |> redirect(to: Routes.path("/users/log-in"))
        end
      else
        Logger.warning("PhoenixKit OAuth: OAuth is disabled in settings")

        conn
        |> put_flash(
          :error,
          "OAuth authentication is currently disabled. Please contact your administrator to enable it."
        )
        |> redirect(to: Routes.path("/users/log-in"))
      end
    end

    defp handle_oauth_request(conn, params) do
      conn =
        if referral_code = params["referral_code"] do
          put_session(conn, :oauth_referral_code, referral_code)
        else
          conn
        end

      conn =
        if return_to = params["return_to"] do
          put_session(conn, :oauth_return_to, return_to)
        else
          conn
        end

      # Check if Ueberauth plug has already sent a response (e.g., a redirect)
      # If response was already sent by Ueberauth, halt() to stop further processing
      if conn.state != :unset do
        # Response already sent by Ueberauth (e.g., redirect to OAuth provider)
        halt(conn)
      else
        # No response sent - Ueberauth couldn't process the request
        # This can happen if provider configuration is missing or invalid
        Logger.error(
          "PhoenixKit OAuth: Ueberauth plugin did not process request for provider. Check if GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET environment variables are set correctly."
        )

        conn
        |> put_flash(
          :error,
          "OAuth authentication unavailable. The provider credentials are not configured. Please contact your administrator or use another sign-in method."
        )
        |> redirect(to: Routes.path("/users/log-in"))
      end
    end

    defp get_ueberauth_providers do
      providers = Config.UeberAuth.get_providers()

      # Normalize Map or List to list of {provider_atom, strategy} tuples
      case providers do
        p when is_map(p) -> Map.to_list(p)
        p when is_list(p) -> p
        _ -> []
      end
    end

    defp oauth_enabled_in_settings? do
      Settings.get_boolean_setting("oauth_enabled", false)
    end

    @doc """
    Handles OAuth callback from provider.
    """
    def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
      track_geolocation = Settings.get_boolean_setting("track_registration_geolocation", false)
      ip_address = IpAddress.extract_from_conn(conn)
      referral_code = get_session(conn, :oauth_referral_code)
      return_to = get_session(conn, :oauth_return_to)

      opts = [
        track_geolocation: track_geolocation,
        ip_address: ip_address,
        referral_code: referral_code
      ]

      case OAuth.handle_oauth_callback(auth, opts) do
        {:ok, user} ->
          Logger.info(
            "PhoenixKit: User #{user.id} (#{user.email}) authenticated via OAuth (#{auth.provider})"
          )

          conn =
            conn
            |> delete_session(:oauth_referral_code)
            |> delete_session(:oauth_return_to)

          flash_message = "Successfully signed in with #{format_provider_name(auth.provider)}!"

          conn
          |> put_flash(:info, flash_message)
          |> UserAuth.log_in_user(user, return_to: return_to)

        {:error, %Ecto.Changeset{} = changeset} ->
          errors = format_changeset_errors(changeset)

          Logger.warning(
            "PhoenixKit: OAuth authentication failed for #{auth.info.email}: #{inspect(errors)}"
          )

          conn
          |> put_flash(:error, "Authentication failed: #{errors}")
          |> redirect(to: Routes.path("/users/log-in"))

        {:error, reason} ->
          Logger.error("PhoenixKit: OAuth authentication error: #{inspect(reason)}")

          conn
          |> put_flash(
            :error,
            "Authentication failed. Please try again or use a different sign-in method."
          )
          |> redirect(to: Routes.path("/users/log-in"))
      end
    end

    def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
      error_message = format_ueberauth_failure(failure)
      Logger.warning("PhoenixKit: OAuth authentication failure: #{inspect(failure)}")

      conn
      |> put_flash(:error, error_message)
      |> redirect(to: Routes.path("/users/log-in"))
    end

    def callback(conn, _params) do
      Logger.error("PhoenixKit: Unexpected OAuth callback without auth or failure")

      conn
      |> put_flash(:error, "Authentication failed. Please try again.")
      |> redirect(to: Routes.path("/users/log-in"))
    end

    # Private helper functions

    defp format_provider_name(provider) when is_atom(provider) do
      provider |> to_string() |> format_provider_name()
    end

    defp format_provider_name("google"), do: "Google"
    defp format_provider_name("apple"), do: "Apple"
    defp format_provider_name("github"), do: "GitHub"
    defp format_provider_name("facebook"), do: "Facebook"
    defp format_provider_name("twitter"), do: "Twitter"
    defp format_provider_name("microsoft"), do: "Microsoft"
    defp format_provider_name(provider), do: String.capitalize(provider)

    defp format_changeset_errors(changeset) do
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)
      |> Enum.map_join("; ", fn {field, errors} ->
        "#{field}: #{Enum.join(errors, ", ")}"
      end)
    end

    defp format_ueberauth_failure(%Ueberauth.Failure{errors: errors}) do
      case errors do
        [] ->
          "Authentication failed. Please try again."

        [%{message: message} | _] when is_binary(message) ->
          "Authentication failed: #{message}"

        _ ->
          "Authentication failed. Please try again."
      end
    end
  end
else
  # Fallback controller when Ueberauth is not loaded
  defmodule PhoenixKitWeb.Users.OAuth do
    @moduledoc """
    Fallback OAuth controller when Ueberauth dependencies are not installed.

    This controller provides user-friendly error messages when OAuth authentication
    is attempted but the required dependencies are not installed.

    To enable OAuth authentication, add the following dependencies to your mix.exs:

        {:ueberauth, "~> 0.10"},
        {:ueberauth_google, "~> 0.12"},  # For Google Sign-In
        {:ueberauth_apple, "~> 0.1"}      # For Apple Sign-In

    Then configure the providers in your config.exs as described in the PhoenixKit documentation.
    """

    use PhoenixKitWeb, :controller

    alias PhoenixKit.Utils.Routes

    require Logger

    @doc """
    Handles OAuth request when Ueberauth is not available.
    """
    def request(conn, %{"provider" => provider}) do
      Logger.warning(
        "PhoenixKit OAuth: Attempted to use #{provider} authentication but Ueberauth dependencies are not installed"
      )

      conn
      |> put_flash(
        :error,
        "OAuth authentication is not available. Please install the required dependencies (ueberauth, ueberauth_#{provider}) and configure your application. See PhoenixKit documentation for details."
      )
      |> redirect(to: Routes.path("/users/log-in"))
    end

    @doc """
    Handles OAuth callback when Ueberauth is not available.
    """
    def callback(conn, _params) do
      Logger.error(
        "PhoenixKit OAuth: Received OAuth callback but Ueberauth dependencies are not installed"
      )

      conn
      |> put_flash(
        :error,
        "OAuth authentication is not configured. Please contact your administrator."
      )
      |> redirect(to: Routes.path("/users/log-in"))
    end
  end
end
