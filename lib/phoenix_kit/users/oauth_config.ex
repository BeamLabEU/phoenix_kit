defmodule PhoenixKit.Users.OAuthConfig do
  @moduledoc """
  Runtime OAuth configuration management using database credentials.

  This module provides functions to configure OAuth providers at runtime
  by reading credentials from the database and updating the application
  configuration dynamically.
  """

  alias PhoenixKit.Settings
  require Logger

  @doc """
  Configures all OAuth providers from database settings.

  This function reads OAuth credentials from the database and updates
  the application configuration at runtime. It should be called:
  - On application startup
  - After updating OAuth credentials via admin UI

  Skips configuration if OAuth is disabled in settings (oauth_enabled = false).

  ## Examples

      iex> PhoenixKit.Users.OAuthConfig.configure_providers()
      :ok
  """
  def configure_providers do
    # Always configure Ueberauth base with available providers
    # This ensures Ueberauth has providers configured even if oauth_enabled is false
    # The oauth_enabled flag controls UI visibility, not the underlying OAuth infrastructure
    configure_ueberauth_base()
    configure_google()
    configure_apple()
    configure_github()
    configure_facebook()

    :ok
  end

  @doc """
  Configures a specific OAuth provider from database settings.

  ## Examples

      iex> PhoenixKit.Users.OAuthConfig.configure_provider(:google)
      :ok
  """
  def configure_provider(provider) when provider in [:google, :apple, :github, :facebook] do
    case provider do
      :google -> configure_google()
      :apple -> configure_apple()
      :github -> configure_github()
      :facebook -> configure_facebook()
    end
  end

  # Configure base Ueberauth with available providers
  defp configure_ueberauth_base do
    providers = build_provider_list()

    config = [
      providers: providers
    ]

    # Always update Ueberauth configuration, even if providers list is empty
    # This ensures Ueberauth has a valid configuration at all times
    Application.put_env(:ueberauth, Ueberauth, config)

    if providers != %{} do
      Logger.debug("OAuth: Configured Ueberauth with providers: #{inspect(Map.keys(providers))}")
    else
      Logger.debug("OAuth: Configured Ueberauth with no active providers")
    end
  end

  # Build the list of available providers based on configured credentials
  defp build_provider_list do
    providers = %{}

    # Add Google if credentials exist
    providers =
      if Settings.has_oauth_credentials?(:google) and
           Settings.get_boolean_setting("oauth_google_enabled", false) do
        Map.put(providers, :google, {Ueberauth.Strategy.Google, []})
      else
        providers
      end

    # Add Apple if credentials exist
    providers =
      if Settings.has_oauth_credentials?(:apple) and
           Settings.get_boolean_setting("oauth_apple_enabled", false) do
        Map.put(providers, :apple, {Ueberauth.Strategy.Apple, []})
      else
        providers
      end

    # Add GitHub if credentials exist
    providers =
      if Settings.has_oauth_credentials?(:github) and
           Settings.get_boolean_setting("oauth_github_enabled", false) do
        Map.put(providers, :github, {Ueberauth.Strategy.Github, []})
      else
        providers
      end

    # Add Facebook if credentials exist
    providers =
      if Settings.has_oauth_credentials?(:facebook) and
           Settings.get_boolean_setting("oauth_facebook_enabled", false) do
        Map.put(providers, :facebook, {Ueberauth.Strategy.Facebook, []})
      else
        providers
      end

    providers
  end

  # Configure Google OAuth
  defp configure_google do
    if Settings.get_boolean_setting("oauth_google_enabled", false) do
      credentials = Settings.get_oauth_credentials(:google)

      if credentials.client_id != "" and credentials.client_secret != "" do
        config = [
          client_id: credentials.client_id,
          client_secret: credentials.client_secret
        ]

        Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, config)
        Logger.debug("OAuth: Configured Google OAuth provider")
      else
        Logger.debug("OAuth: Google enabled but credentials not configured")
      end
    end
  end

  # Configure Apple OAuth
  defp configure_apple do
    if Settings.get_boolean_setting("oauth_apple_enabled", false) do
      credentials = Settings.get_oauth_credentials(:apple)

      if credentials.client_id != "" and
           credentials.team_id != "" and
           credentials.key_id != "" and
           credentials.private_key != "" do
        config = [
          client_id: credentials.client_id,
          team_id: credentials.team_id,
          key_id: credentials.key_id,
          private_key: credentials.private_key
        ]

        Application.put_env(:ueberauth, Ueberauth.Strategy.Apple.OAuth, config)
        Logger.debug("OAuth: Configured Apple OAuth provider")
      else
        Logger.debug("OAuth: Apple enabled but credentials not fully configured")
      end
    end
  end

  # Configure GitHub OAuth
  defp configure_github do
    if Settings.get_boolean_setting("oauth_github_enabled", false) do
      credentials = Settings.get_oauth_credentials(:github)

      if credentials.client_id != "" and credentials.client_secret != "" do
        config = [
          client_id: credentials.client_id,
          client_secret: credentials.client_secret
        ]

        Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, config)
        Logger.debug("OAuth: Configured GitHub OAuth provider")
      else
        Logger.debug("OAuth: GitHub enabled but credentials not configured")
      end
    end
  end

  # Configure Facebook OAuth
  defp configure_facebook do
    if Settings.get_boolean_setting("oauth_facebook_enabled", false) do
      credentials = Settings.get_oauth_credentials(:facebook)

      if credentials.app_id != "" and credentials.app_secret != "" do
        config = [
          client_id: credentials.app_id,
          client_secret: credentials.app_secret
        ]

        Application.put_env(:ueberauth, Ueberauth.Strategy.Facebook.OAuth, config)
        Logger.debug("OAuth: Configured Facebook OAuth provider")
      else
        Logger.debug("OAuth: Facebook enabled but credentials not configured")
      end
    end
  end

  @doc """
  Validates OAuth credentials for a specific provider.

  Returns `{:ok, provider}` if credentials are valid, or `{:error, reason}` if not.

  ## Examples

      iex> PhoenixKit.Users.OAuthConfig.validate_credentials(:google)
      {:ok, :google}

      iex> PhoenixKit.Users.OAuthConfig.validate_credentials(:apple)
      {:error, "Missing Apple private key"}
  """
  def validate_credentials(provider) when provider in [:google, :apple, :github, :facebook] do
    credentials = Settings.get_oauth_credentials(provider)

    case provider do
      :google -> validate_google_credentials(credentials)
      :apple -> validate_apple_credentials(credentials)
      :github -> validate_github_credentials(credentials)
      :facebook -> validate_facebook_credentials(credentials)
    end
  end

  defp validate_google_credentials(credentials) do
    missing = find_missing_google_credentials(credentials)

    if missing == [] do
      {:ok, :google}
    else
      {:error, "Missing Google OAuth credentials: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_apple_credentials(credentials) do
    missing = find_missing_apple_credentials(credentials)

    if missing == [] do
      {:ok, :apple}
    else
      {:error, "Missing Apple OAuth credentials: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_github_credentials(credentials) do
    missing = find_missing_github_credentials(credentials)

    if missing == [] do
      {:ok, :github}
    else
      {:error, "Missing GitHub OAuth credentials: #{Enum.join(missing, ", ")}"}
    end
  end

  defp find_missing_google_credentials(credentials) do
    []
    |> add_if_missing("Client ID", credentials.client_id)
    |> add_if_missing("Client Secret", credentials.client_secret)
  end

  defp find_missing_apple_credentials(credentials) do
    []
    |> add_if_missing("Client ID", credentials.client_id)
    |> add_if_missing("Team ID", credentials.team_id)
    |> add_if_missing("Key ID", credentials.key_id)
    |> add_if_missing("Private Key", credentials.private_key)
  end

  defp find_missing_github_credentials(credentials) do
    []
    |> add_if_missing("Client ID", credentials.client_id)
    |> add_if_missing("Client Secret", credentials.client_secret)
  end

  defp validate_facebook_credentials(credentials) do
    missing = find_missing_facebook_credentials(credentials)

    if missing == [] do
      {:ok, :facebook}
    else
      {:error, "Missing Facebook OAuth credentials: #{Enum.join(missing, ", ")}"}
    end
  end

  defp find_missing_facebook_credentials(credentials) do
    []
    |> add_if_missing("App ID", credentials.app_id)
    |> add_if_missing("App Secret", credentials.app_secret)
  end

  defp add_if_missing(list, field_name, value) do
    if value == "" do
      [field_name | list]
    else
      list
    end
  end

  @doc """
  Tests OAuth connection for a specific provider.

  This function validates the credentials format but does not make actual API calls.
  For true connection testing, OAuth flow needs to be initiated through the browser.

  ## Examples

      iex> PhoenixKit.Users.OAuthConfig.test_connection(:google)
      {:ok, "Google OAuth credentials are properly formatted"}
  """
  def test_connection(provider) when provider in [:google, :apple, :github, :facebook] do
    case validate_credentials(provider) do
      {:ok, _provider} ->
        {:ok,
         "#{provider_name(provider)} OAuth credentials are properly formatted. Initiate OAuth flow to test actual connection."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp provider_name(:google), do: "Google"
  defp provider_name(:apple), do: "Apple"
  defp provider_name(:github), do: "GitHub"
  defp provider_name(:facebook), do: "Facebook"
end
