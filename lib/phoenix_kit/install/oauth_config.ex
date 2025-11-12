defmodule PhoenixKit.Install.OAuthConfig do
  @moduledoc """
  Handles Ueberauth OAuth configuration for PhoenixKit installation.

  This module ensures proper Ueberauth compile-time configuration is set up
  during PhoenixKit installation. The key requirement is:

  - **Compile-time**: Empty map `providers: %{}` (not empty list `[]`)
  - **Runtime**: Providers loaded dynamically from database via `PhoenixKit.Workers.OAuthConfigLoader`

  ## Why Empty Map vs Empty List?

  Ueberauth expects `providers` to be a map-like structure. Using an empty list `[]`
  causes runtime errors when Ueberauth tries to access provider configuration.

  ### Incorrect (causes errors):
  ```elixir
  config :ueberauth, Ueberauth, providers: []  # ❌ Empty list
  ```

  ### Correct:
  ```elixir
  config :ueberauth, Ueberauth, providers: %{}  # ✅ Empty map
  ```

  ## Runtime Configuration

  PhoenixKit uses runtime configuration through:
  - `PhoenixKit.Workers.OAuthConfigLoader` - Loads providers from database at startup
  - `PhoenixKit.Users.OAuthConfig.configure_providers()` - Updates Application config
  - `PhoenixKitWeb.Plugs.EnsureOAuthConfig` - Fallback protection for race conditions

  The compile-time configuration serves as a foundation that runtime configuration builds upon.
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
