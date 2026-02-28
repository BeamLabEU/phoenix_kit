if Code.ensure_loaded?(Ueberauth) do
  defmodule PhoenixKitWeb.Users.OAuth do
    @moduledoc """
    OAuth authentication controller using Ueberauth with dynamic provider configuration.

    This controller uses `Ueberauth.run_request/4` and `Ueberauth.run_callback/4` for
    dynamic OAuth invocation, eliminating compile-time configuration requirements.
    OAuth credentials are loaded from database at runtime.

    This controller requires the following optional dependencies to be installed:
    - ueberauth
    - ueberauth_google (for Google Sign-In)
    - ueberauth_apple (for Apple Sign-In)
    - ueberauth_github (for GitHub Sign-In)
    - ueberauth_facebook (for Facebook Sign-In)

    If these dependencies are not installed, a fallback controller will be used instead.
    """

    use PhoenixKitWeb, :controller

    plug PhoenixKitWeb.Plugs.EnsureOAuthScheme
    plug PhoenixKitWeb.Plugs.EnsureOAuthConfig
    # NOTE: No `plug Ueberauth` - we call Ueberauth.run_request/4 and run_callback/4 dynamically

    alias PhoenixKit.Config
    alias PhoenixKit.Settings
    alias PhoenixKit.Users.OAuth
    alias PhoenixKit.Utils.IpAddress
    alias PhoenixKit.Utils.Routes
    alias PhoenixKitWeb.Users.Auth, as: UserAuth

    require Logger

    # Map provider names (strings) to strategy modules
    @provider_strategies %{
      "google" => Ueberauth.Strategy.Google,
      "apple" => Ueberauth.Strategy.Apple,
      "github" => Ueberauth.Strategy.Github,
      "facebook" => Ueberauth.Strategy.Facebook
    }

    @doc """
    Initiates OAuth authentication flow.

    Uses `Ueberauth.run_request/4` for dynamic OAuth invocation,
    reading credentials from database at runtime.
    """
    def request(conn, %{"provider" => provider} = params) do
      Logger.debug("PhoenixKit OAuth request for provider: #{provider}")

      # Check if OAuth is enabled in settings
      if oauth_enabled_in_settings?() do
        # Check if provider is supported and enabled
        case validate_provider(provider) do
          {:ok, strategy_module} ->
            handle_oauth_request(conn, provider, strategy_module, params)

          {:error, :unknown_provider} ->
            Logger.warning("PhoenixKit OAuth: Unknown provider '#{provider}'")

            conn
            |> put_flash(:error, "Unknown OAuth provider: #{provider}")
            |> redirect(to: Routes.path("/users/log-in"))

          {:error, :provider_disabled} ->
            Logger.warning("PhoenixKit OAuth: Provider '#{provider}' is disabled in settings")

            conn
            |> put_flash(:error, "OAuth provider '#{provider}' is currently disabled.")
            |> redirect(to: Routes.path("/users/log-in"))

          {:error, :no_credentials} ->
            Logger.warning(
              "PhoenixKit OAuth: No credentials configured for provider '#{provider}'"
            )

            conn
            |> put_flash(
              :error,
              "OAuth provider '#{provider}' is not configured. Please contact your administrator."
            )
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

    defp handle_oauth_request(conn, provider, strategy_module, params) do
      # Store referral_code and return_to in session
      conn =
        conn
        |> maybe_put_session(:oauth_referral_code, params["referral_code"])
        |> maybe_put_session(:oauth_return_to, params["return_to"])

      # Build provider config for dynamic Ueberauth call
      base_path = Config.UeberAuth.get_base_path()

      provider_config =
        {strategy_module,
         [
           request_path: "#{base_path}/#{provider}",
           callback_path: "#{base_path}/#{provider}/callback"
         ]}

      # Dynamic Ueberauth call - reads credentials from Application env
      # (configured by EnsureOAuthConfig plug)
      Ueberauth.run_request(conn, provider, provider_config)
    end

    defp validate_provider(provider) do
      case Map.get(@provider_strategies, provider) do
        nil ->
          {:error, :unknown_provider}

        strategy_module ->
          # Check if provider is enabled in settings
          if Settings.get_boolean_setting("oauth_#{provider}_enabled", false) do
            # Check if credentials exist
            if Settings.has_oauth_credentials_direct?(String.to_existing_atom(provider)) do
              {:ok, strategy_module}
            else
              {:error, :no_credentials}
            end
          else
            {:error, :provider_disabled}
          end
      end
    end

    defp maybe_put_session(conn, _key, nil), do: conn
    defp maybe_put_session(conn, key, value), do: put_session(conn, key, value)

    defp oauth_enabled_in_settings? do
      Settings.get_boolean_setting("oauth_enabled", false)
    end

    @doc """
    Handles OAuth callback from provider.

    Uses `Ueberauth.run_callback/4` for dynamic OAuth invocation,
    then processes the result from conn.assigns.
    """
    def callback(conn, %{"provider" => provider} = _params) do
      Logger.debug("PhoenixKit OAuth callback for provider: #{provider}")

      case Map.get(@provider_strategies, provider) do
        nil ->
          Logger.error("PhoenixKit OAuth: Unknown provider in callback: #{provider}")

          conn
          |> put_flash(:error, "Unknown OAuth provider: #{provider}")
          |> redirect(to: Routes.path("/users/log-in"))

        strategy_module ->
          # Build provider config for dynamic Ueberauth call
          base_path = Config.UeberAuth.get_base_path()

          provider_config =
            {strategy_module,
             [
               request_path: "#{base_path}/#{provider}",
               callback_path: "#{base_path}/#{provider}/callback"
             ]}

          # Dynamic Ueberauth callback - processes OAuth response
          conn = Ueberauth.run_callback(conn, provider, provider_config)

          # Handle the result based on assigns set by Ueberauth
          handle_callback_result(conn)
      end
    end

    # Handle successful OAuth authentication
    defp handle_callback_result(%{assigns: %{ueberauth_auth: auth}} = conn) do
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
            "PhoenixKit: User #{user.uuid} (#{user.email}) authenticated via OAuth (#{auth.provider})"
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

    # Handle OAuth authentication failure
    defp handle_callback_result(%{assigns: %{ueberauth_failure: failure}} = conn) do
      error_message = format_ueberauth_failure(failure)
      Logger.warning("PhoenixKit: OAuth authentication failure: #{inspect(failure)}")

      conn
      |> put_flash(:error, error_message)
      |> redirect(to: Routes.path("/users/log-in"))
    end

    # Handle unexpected callback without auth or failure
    defp handle_callback_result(conn) do
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
