defmodule PhoenixKit.Install.OAuthConfig do
  @moduledoc """
  Handles OAuth configuration notices for PhoenixKit installation.

  PhoenixKit uses **fully dynamic OAuth** - no compile-time configuration required.
  All OAuth providers are configured at runtime from database settings.

  ## How It Works

  Instead of using `plug Ueberauth` (which requires compile-time providers configuration),
  PhoenixKit calls Ueberauth functions directly in the OAuth controller:

  ```elixir
  # In PhoenixKitWeb.Users.OAuth controller:
  # - request/2 calls Ueberauth.run_request/4
  # - callback/2 calls Ueberauth.run_callback/4
  ```

  This approach allows:
  - **No compile-time configuration required** - OAuth works without any config.exs entries
  - **Database-driven credentials** - Credentials loaded from Settings table at runtime
  - **Dynamic provider management** - Add/remove/modify providers without app restart

  ## Runtime OAuth Flow

  1. User clicks "Sign in with Google"
  2. `PhoenixKitWeb.Plugs.EnsureOAuthConfig` loads credentials from database
  3. `PhoenixKitWeb.Users.OAuth.request/2` calls `Ueberauth.run_request/4` dynamically
  4. User authenticates with provider
  5. `PhoenixKitWeb.Users.OAuth.callback/2` calls `Ueberauth.run_callback/4` dynamically
  6. User is logged in

  ## Related Modules

  - `PhoenixKit.Users.OAuthConfig` - Configures credentials in Application env at runtime
  - `PhoenixKit.Workers.OAuthConfigLoader` - Loads OAuth config on app startup
  - `PhoenixKitWeb.Plugs.EnsureOAuthConfig` - Ensures credentials loaded before OAuth
  - `PhoenixKitWeb.Users.OAuth` - OAuth controller with dynamic Ueberauth calls
  """

  @doc """
  Adds OAuth configuration notice for PhoenixKit installation.

  No compile-time configuration is added - OAuth is fully dynamic.
  This function only adds an informational notice.

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with informational notice about dynamic OAuth.

  ## Example
  ```elixir
  igniter
  |> OAuthConfig.add_oauth_configuration()
  ```
  """
  def add_oauth_configuration(igniter) do
    # No static config needed - OAuth is fully dynamic
    # Just add informational notice
    add_oauth_configuration_notice(igniter)
  end

  # Add informational notice about OAuth configuration
  defp add_oauth_configuration_notice(igniter) do
    notice = """
    🔐 OAuth ready (providers configured dynamically from database at runtime)
    """

    Igniter.add_notice(igniter, String.trim(notice))
  end
end
