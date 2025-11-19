defmodule PhoenixKit.Config.UeberAuth do
  @moduledoc """
  Ueberauth configuration management for PhoenixKit.

  This module provides a centralized way to manage Ueberauth OAuth configuration
  with type-safe getter and setter functions for different data types.

  ## Usage

      # Get all Ueberauth configuration
      config = PhoenixKit.Config.UeberAuth.get_all()

      # Get specific values
      providers = PhoenixKit.Config.UeberAuth.get_providers()
      base_path = PhoenixKit.Config.UeberAuth.get_base_path()

      # Set configuration
      PhoenixKit.Config.UeberAuth.set_providers(%{google: {Ueberauth.Strategy.Google, []}})
      PhoenixKit.Config.UeberAuth.set_base_path("/custom/auth")

  ## Configuration Keys

  - `:base_path` - Base path for OAuth routes (default: calculated from URL prefix)
  - `:providers` - Map of OAuth providers and their strategies

  ## Provider Management

  Functions are provided for adding, removing, and checking individual providers:
  - `update_provider/2` - Add or update a provider
  - `remove_provider/1` - Remove a provider
  - `has_provider?/1` - Check if a provider is configured
  - `get_provider_names/0` - Get list of all provider names
  - `get_provider/1` - Get specific provider configuration
  """

  alias PhoenixKit.Config

  @doc """
  Gets the full Ueberauth configuration from the application environment.

  This function retrieves the complete Ueberauth configuration including
  providers, base path, and other Ueberauth-specific settings.

  ## Examples

      iex> PhoenixKit.Config.UeberAuth.get_all()
      [base_path: "/users/auth", providers: %{google: {Ueberauth.Strategy.Google, []}}]

      iex> PhoenixKit.Config.UeberAuth.get_all()
      []

  """
  @spec get_all() :: Keyword.t()
  def get_all do
    Config.get_list(:ueberauth, [])
  end

  @doc """
  Gets specific Ueberauth configuration options by key.

  ## Examples

      iex> PhoenixKit.Config.UeberAuth.get_option(:providers)
      %{google: {Ueberauth.Strategy.Google, []}}

      iex> PhoenixKit.Config.UeberAuth.get_option(:base_path)
      "/users/auth"

      iex> PhoenixKit.Config.UeberAuth.get_option(:nonexistent)
      nil

  """
  @spec get_option(atom()) :: any() | nil
  def get_option(key) when is_atom(key) do
    config = get_all()
    Keyword.get(config, key)
  end

  @doc """
  Gets specific Ueberauth configuration options by key with a default value.

  ## Examples

      iex> PhoenixKit.Config.UeberAuth.get_option(:base_path, "/auth")
      "/users/auth"

      iex> PhoenixKit.Config.UeberAuth.get_option(:nonexistent, "default")
      "default"

  """
  @spec get_option(atom(), any()) :: any()
  def get_option(key, default) when is_atom(key) do
    config = get_all()
    Keyword.get(config, key, default)
  end

  @doc """
  Gets Ueberauth providers configuration.

  Returns the configured providers map or list, or an empty map if none configured.

  ## Examples

      iex> PhoenixKit.Config.UeberAuth.get_providers()
      %{google: {Ueberauth.Strategy.Google, []}, apple: {Ueberauth.Strategy.Apple, []}}

      iex> PhoenixKit.Config.UeberAuth.get_providers()
      %{}

  """
  @spec get_providers() :: map() | list()
  def get_providers do
    case get_option(:providers) do
      providers when is_map(providers) or is_list(providers) -> providers
      _ -> %{}
    end
  end

  @doc """
  Gets Ueberauth base path configuration.

  Returns the configured base path for OAuth routes or a default based on URL prefix.

  ## Examples

      iex> PhoenixKit.Config.UeberAuth.get_base_path()
      "/users/auth"

      iex> PhoenixKit.Config.UeberAuth.get_base_path()
      "/phoenix_kit/users/auth"

  """
  @spec get_base_path() :: String.t()
  def get_base_path do
    case get_option(:base_path) do
      base_path when is_binary(base_path) and base_path != "" -> base_path
      _ -> get_default_base_path()
    end
  end

  @doc """
  Sets Ueberauth configuration options.

  Updates the Ueberauth configuration in the application environment.

  ## Examples

      iex> PhoenixKit.Config.UeberAuth.set_all([providers: %{google: {Ueberauth.Strategy.Google, []}}])
      :ok

      iex> PhoenixKit.Config.UeberAuth.set_all([base_path: "/custom/auth"])
      :ok

  """
  @spec set_all(Keyword.t()) :: :ok
  def set_all(options) when is_list(options) do
    current_config = get_all()
    new_config = Keyword.merge(current_config, options)
    Config.set(:ueberauth, new_config)
    :ok
  end

  @doc """
  Sets specific Ueberauth configuration option.

  Updates a single key in the Ueberauth configuration.

  ## Examples

      iex> PhoenixKit.Config.UeberAuth.set_option(:base_path, "/custom/auth")
      :ok

      iex> PhoenixKit.Config.UeberAuth.set_option(:providers, %{google: {Ueberauth.Strategy.Google, []}})
      :ok

  """
  @spec set_option(atom(), any()) :: :ok
  def set_option(key, value) when is_atom(key) do
    set_all([{key, value}])
  end

  @doc """
  Sets Ueberauth providers configuration.

  Updates the providers map in Ueberauth configuration.

  ## Examples

      iex> PhoenixKit.Config.UeberAuth.set_providers(%{google: {Ueberauth.Strategy.Google, []}})
      :ok

  """
  @spec set_providers(map() | list()) :: :ok
  def set_providers(providers) when is_map(providers) or is_list(providers) do
    set_option(:providers, providers)
  end

  @doc """
  Sets Ueberauth base path configuration.

  Updates the base path for OAuth routes.

  ## Examples

      iex> PhoenixKit.Config.UeberAuth.set_base_path("/custom/auth")
      :ok

  """
  @spec set_base_path(String.t()) :: :ok
  def set_base_path(base_path) when is_binary(base_path) do
    set_option(:base_path, base_path)
  end

  @doc """
  Updates Ueberauth providers by adding or updating a specific provider.

  Adds a new provider or updates an existing one in the providers configuration.

  ## Examples

      iex> PhoenixKit.Config.UeberAuth.update_provider(:google, {Ueberauth.Strategy.Google, []})
      :ok

  """
  @spec update_provider(atom(), tuple()) :: :ok
  def update_provider(provider, strategy_config)
      when is_atom(provider) and is_tuple(strategy_config) do
    providers = get_providers()
    updated_providers = Map.put(providers, provider, strategy_config)
    set_providers(updated_providers)
  end

  @doc """
  Removes a specific Ueberauth provider from the configuration.

  ## Examples

      iex> PhoenixKit.Config.UeberAuth.remove_provider(:google)
      :ok

  """
  @spec remove_provider(atom()) :: :ok
  def remove_provider(provider) when is_atom(provider) do
    providers = get_providers()
    updated_providers = Map.delete(providers, provider)
    set_providers(updated_providers)
  end

  @doc """
  Checks if a specific Ueberauth provider is configured.

  ## Examples

      iex> PhoenixKit.Config.UeberAuth.has_provider?(:google)
      true

      iex> PhoenixKit.Config.UeberAuth.has_provider?(:facebook)
      false

  """
  @spec has_provider?(atom()) :: boolean()
  def has_provider?(provider) when is_atom(provider) do
    providers = get_providers()
    Map.has_key?(providers, provider)
  end

  @doc """
  Gets a list of all configured Ueberauth provider names.

  ## Examples

      iex> PhoenixKit.Config.UeberAuth.get_provider_names()
      [:google, :apple, :github]

      iex> PhoenixKit.Config.UeberAuth.get_provider_names()
      []

  """
  @spec get_provider_names() :: [atom()]
  def get_provider_names do
    providers = get_providers()

    case providers do
      p when is_map(p) -> Map.keys(p)
      p when is_list(p) -> Keyword.keys(p)
    end
  end

  @doc """
  Gets the Ueberauth provider configuration for a specific provider.

  ## Examples

      iex> PhoenixKit.Config.UeberAuth.get_provider(:google)
      {Ueberauth.Strategy.Google, []}

      iex> PhoenixKit.Config.UeberAuth.get_provider(:nonexistent)
      nil

  """
  @spec get_provider(atom()) :: tuple() | nil
  def get_provider(provider) when is_atom(provider) do
    providers = get_providers()

    case providers do
      p when is_map(p) -> Map.get(p, provider)
      p when is_list(p) -> Keyword.get(p, provider)
    end
  end

  # Helper function to get the default base path based on URL prefix
  defp get_default_base_path do
    url_prefix = Config.get_url_prefix()

    case url_prefix do
      "" -> "/users/auth"
      "/" -> "/users/auth"
      prefix -> "#{prefix}/users/auth"
    end
  end
end
