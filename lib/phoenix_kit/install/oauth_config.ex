defmodule PhoenixKit.Install.OAuthConfig do
  @moduledoc """
  Handles Ueberauth OAuth configuration for PhoenixKit installation.

  PhoenixKit uses **dynamic OAuth invocation** via `Ueberauth.run_request/4` and
  `Ueberauth.run_callback/4`, eliminating compile-time configuration requirements.

  ## How It Works

  Instead of using `plug Ueberauth` (which requires compile-time providers configuration),
  PhoenixKit calls Ueberauth functions directly in the OAuth controller:

  ```elixir
  # In PhoenixKitWeb.Users.OAuth controller:
  # - request/2 calls Ueberauth.run_request/4
  # - callback/2 calls Ueberauth.run_callback/4
  ```

  This approach allows:
  - **No compile-time configuration required** - OAuth works without any providers in config
  - **Database-driven credentials** - Credentials loaded from Settings table at runtime
  - **Dynamic provider management** - Add/remove/modify providers without app restart

  ## Configuration

  While compile-time configuration is no longer required, we still add a minimal
  Ueberauth config for compatibility with libraries that may check for it:

  ```elixir
  config :ueberauth, Ueberauth, providers: %{}  # Empty map for compatibility
  ```

  ## Runtime OAuth Flow

  1. User clicks "Sign in with Google"
  2. `PhoenixKitWeb.Plugs.EnsureOAuthConfig` loads credentials from database
  3. `PhoenixKitWeb.Users.OAuth.request/2` calls `Ueberauth.run_request/4` dynamically
  4. User authenticates with provider
  5. `PhoenixKitWeb.Users.OAuth.callback/2` calls `Ueberauth.run_callback/4` dynamically
  6. User is logged in

  ## Related Modules

  - `PhoenixKit.Users.OAuthConfig` - Configures credentials in Application env
  - `PhoenixKitWeb.Plugs.EnsureOAuthConfig` - Ensures credentials loaded before OAuth
  - `PhoenixKitWeb.Users.OAuth` - OAuth controller with dynamic Ueberauth calls
  """
  use PhoenixKit.Install.IgniterCompat

  @doc """
  Adds minimal Ueberauth configuration required for PhoenixKit OAuth functionality.

  This function adds compile-time configuration with an empty providers map.
  Runtime configuration will populate providers from the database.

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with Ueberauth configuration and informational notice.

  ## Example
  ```elixir
  igniter
  |> OAuthConfig.add_oauth_configuration()
  ```
  """
  def add_oauth_configuration(igniter) do
    igniter
    |> add_ueberauth_config()
    |> add_oauth_configuration_notice()
  end

  # Add minimal Ueberauth configuration with empty providers map
  defp add_ueberauth_config(igniter) do
    # Add compile-time Ueberauth config with empty map (not empty list!)
    # Runtime configuration (OAuthConfigLoader) will populate providers from database

    ueberauth_config = """

    # Configure Ueberauth (minimal configuration for compilation)
    # Applications using PhoenixKit should configure their own providers
    config :ueberauth, Ueberauth, providers: %{}
    """

    try do
      Igniter.update_file(igniter, "config/config.exs", fn source ->
        current_content = Rewrite.Source.get(source, :content)

        # Check if already configured
        if String.contains?(current_content, "config :ueberauth, Ueberauth") do
          source
        else
          # Append to end of file
          updated_content = current_content <> ueberauth_config
          Rewrite.Source.update(source, :content, updated_content)
        end
      end)
    rescue
      _ ->
        # If update fails, return igniter as-is (better than failing install)
        igniter
    end
  end

  # Add informational notice about OAuth configuration
  defp add_oauth_configuration_notice(igniter) do
    notice = """
    🔐 OAuth configured (providers loaded at runtime from database)
    """

    Igniter.add_notice(igniter, String.trim(notice))
  end
end
