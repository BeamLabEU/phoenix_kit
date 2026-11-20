defmodule PhoenixKit.Users.OAuthAvailability do
  @moduledoc """
  Checks OAuth availability and configured providers.

  This module provides runtime checks to determine if OAuth dependencies are loaded
  and which providers are properly configured. It enables graceful degradation when
  OAuth dependencies are not installed.
  """

  @doc """
  Checks if Ueberauth library is loaded and available.

  Returns `true` if the Ueberauth module is available, `false` otherwise.

  ## Examples

      iex> PhoenixKit.Users.OAuthAvailability.ueberauth_loaded?()
      true

      iex> PhoenixKit.Users.OAuthAvailability.ueberauth_loaded?()
      false
  """
  @spec ueberauth_loaded? :: boolean()
  def ueberauth_loaded? do
    Code.ensure_loaded?(Ueberauth) and
      Code.ensure_loaded?(Ueberauth.Strategy)
  end

  @doc """
  Gets list of configured OAuth providers.

  Returns a list of provider names (as atoms) that have both:
  - Credentials configured in the database
  - Provider enabled in settings

  Returns an empty list if Ueberauth is not loaded or no providers are properly configured.

  ## Examples

      iex> PhoenixKit.Users.OAuthAvailability.configured_providers()
      [:google, :github]

      iex> PhoenixKit.Users.OAuthAvailability.configured_providers()
      []
  """
  @spec configured_providers :: [atom()]
  def configured_providers do
    if ueberauth_loaded?() and oauth_enabled_in_settings?() do
      Enum.filter([:google, :github, :facebook], fn provider ->
        provider_switch_enabled?(provider) and
          PhoenixKit.Settings.has_oauth_credentials_direct?(provider)
      end)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Checks if OAuth is enabled in settings.

  Returns `true` if OAuth is explicitly enabled in settings, defaults to `false`.

  ## Examples

      iex> PhoenixKit.Users.OAuthAvailability.oauth_enabled_in_settings?()
      true
  """
  @spec oauth_enabled_in_settings? :: boolean()
  def oauth_enabled_in_settings? do
    if Code.ensure_loaded?(PhoenixKit.Settings) do
      try do
        PhoenixKit.Settings.get_boolean_setting("oauth_enabled", false)
      rescue
        # Handle cases where repo is not configured (like in tests)
        _ -> false
      catch
        :exit, _ -> false
      end
    else
      false
    end
  end

  @doc """
  Checks if a specific OAuth provider is enabled in settings.

  Returns `true` if both the master OAuth switch and the individual provider are enabled.
  Requires the master `oauth_enabled` setting to be true.

  ## Examples

      iex> PhoenixKit.Users.OAuthAvailability.provider_enabled?(:google)
      true

      iex> PhoenixKit.Users.OAuthAvailability.provider_enabled?(:github)
      false
  """
  @spec provider_enabled?(atom()) :: boolean()
  def provider_enabled?(provider) when provider in [:google, :github, :facebook] do
    oauth_enabled_in_settings?() and provider_switch_enabled?(provider)
  end

  def provider_enabled?(_), do: false

  defp provider_switch_enabled?(provider) do
    PhoenixKit.Settings.get_boolean_setting("oauth_#{provider}_enabled", false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  Checks if OAuth is available (enabled in settings, Ueberauth loaded, and at least one provider configured).

  ## Examples

      iex> PhoenixKit.Users.OAuthAvailability.oauth_available?()
      true

      iex> PhoenixKit.Users.OAuthAvailability.oauth_available?()
      false
  """
  @spec oauth_available? :: boolean()
  def oauth_available? do
    configured_providers() != []
  end

  @doc """
  Checks if a specific provider is configured.

  A provider is considered configured if:
  - It's enabled in settings
  - It has valid credentials in the database
  - Ueberauth is loaded

  ## Examples

      iex> PhoenixKit.Users.OAuthAvailability.provider_configured?(:google)
      true

      iex> PhoenixKit.Users.OAuthAvailability.provider_configured?(:github)
      false
  """
  @spec provider_configured?(atom() | String.t()) :: boolean()
  def provider_configured?(provider) when is_atom(provider) do
    provider in configured_providers()
  end

  def provider_configured?(provider) when is_binary(provider) do
    provider_atom = String.to_existing_atom(provider)
    provider_configured?(provider_atom)
  rescue
    ArgumentError -> false
  end

  @doc """
  Gets OAuth status information for debugging and admin interfaces.

  ## Examples

      iex> PhoenixKit.Users.OAuthAvailability.status()
      %{
        enabled_in_settings: true,
        ueberauth_loaded: true,
        providers: [:google, :github],
        available: true
      }
  """
  @spec status :: map()
  def status do
    %{
      enabled_in_settings: oauth_enabled_in_settings?(),
      ueberauth_loaded: ueberauth_loaded?(),
      providers: configured_providers(),
      available: oauth_available?()
    }
  end
end
