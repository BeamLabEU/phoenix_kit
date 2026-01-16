defmodule PhoenixKit.Modules.Storage.ProviderRegistry do
  @moduledoc """
  Registry for storage providers.

  Maps provider types to their implementation modules.
  """

  @providers %{
    "local" => PhoenixKit.Modules.Storage.Providers.Local,
    "s3" => PhoenixKit.Modules.Storage.Providers.S3,
    # B2 uses S3-compatible API
    "b2" => PhoenixKit.Modules.Storage.Providers.S3,
    # R2 uses S3-compatible API
    "r2" => PhoenixKit.Modules.Storage.Providers.S3
  }

  @doc """
  Gets the provider module for a given provider type.
  """
  def get_provider("local"), do: {:ok, PhoenixKit.Modules.Storage.Providers.Local}
  def get_provider("s3"), do: {:ok, PhoenixKit.Modules.Storage.Providers.S3}
  # B2 is S3-compatible
  def get_provider("b2"), do: {:ok, PhoenixKit.Modules.Storage.Providers.S3}
  # R2 is S3-compatible
  def get_provider("r2"), do: {:ok, PhoenixKit.Modules.Storage.Providers.S3}
  def get_provider(provider), do: {:error, "Unknown provider: #{provider}"}

  @doc """
  Lists all available provider types.
  """
  def list_providers do
    Map.keys(@providers)
  end

  @doc """
  Checks if a provider type is supported.
  """
  def provider_supported?(provider) when is_binary(provider) do
    Map.has_key?(@providers, provider)
  end

  def provider_supported?(_), do: false

  @doc """
  Gets all providers as a map of provider type to module.
  """
  def all_providers, do: @providers
end
