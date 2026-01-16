defmodule PhoenixKit.Config.AWS do
  @moduledoc """
  AWS configuration management for PhoenixKit.

  This module provides a centralized way to manage AWS configuration.

  ## Usage

      # Get AWS region
      region = PhoenixKit.Config.AWS.region()

      # Get AWS access key ID
      access_key_id = PhoenixKit.Config.AWS.access_key_id()

      # Get AWS secret access key
      secret_access_key = PhoenixKit.Config.AWS.secret_access_key()

  ## Configuration

  AWS configuration is grouped under the `:aws` key in PhoenixKit config:

      config :phoenix_kit,
        aws: [
          region: "eu-north-1",
          access_key_id: "AKIAIOSFODNN7EXAMPLE",
          secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        ]

  ## Configuration Keys

  - `:region` - AWS region (default: "eu-north-1")
  - `:access_key_id` - AWS access key ID
  - `:secret_access_key` - AWS secret access key

  ## Examples

      # Get AWS region
      region = PhoenixKit.Config.AWS.region()
      #=> "eu-north-1"

      # Get AWS access key ID
      access_key_id = PhoenixKit.Config.AWS.access_key_id()
      #=> "AKIAIOSFODNN7EXAMPLE"

  """

  alias PhoenixKit.Config

  @default_region "eu-north-1"

  @doc """
  Gets the AWS configuration keyword list.

  ## Examples

      iex> PhoenixKit.Config.AWS.get_all()
      [region: "eu-north-1", access_key_id: "AKIA...", secret_access_key: "..."]

  """
  @spec get_all() :: Keyword.t()
  def get_all do
    Config.get(:aws, [])
  end

  @doc """
  Gets a specific AWS configuration value.

  ## Examples

      iex> PhoenixKit.Config.AWS.get(:region)
      {:ok, "eu-north-1"}

      iex> PhoenixKit.Config.AWS.get(:nonexistent)
      :not_found

  """
  @spec get(atom()) :: {:ok, any()} | :not_found
  def get(key) when is_atom(key) do
    case get_all() do
      aws_config when is_list(aws_config) ->
        case Keyword.get(aws_config, key) do
          nil -> :not_found
          value -> {:ok, value}
        end
    end
  end

  @doc """
  Gets a specific AWS configuration value with a default.

  ## Examples

      iex> PhoenixKit.Config.AWS.get(:region, "us-east-1")
      "eu-north-1"

  """
  @spec get(atom(), any()) :: any()
  def get(key, default) when is_atom(key) do
    case get(key) do
      {:ok, value} -> value
      :not_found -> default
    end
  end

  @doc """
  Gets the AWS region.

  Returns the configured region from application config
  with a fallback to "eu-north-1".

  ## Examples

      iex> PhoenixKit.Config.AWS.region()
      "us-east-1"

      iex> PhoenixKit.Config.AWS.region()
      "eu-north-1"

  """
  @spec region() :: String.t()
  def region do
    case get(:region) do
      {:ok, region} when is_binary(region) and region != "" ->
        region

      _ ->
        @default_region
    end
  end

  @doc """
  Gets the AWS access key ID.

  Returns the configured access key ID from application config.

  ## Examples

      iex> PhoenixKit.Config.AWS.access_key_id()
      "AKIAIOSFODNN7EXAMPLE"

      iex> PhoenixKit.Config.AWS.access_key_id()
      nil

  """
  @spec access_key_id() :: String.t()
  def access_key_id do
    case get(:access_key_id) do
      {:ok, key_id} when is_binary(key_id) and key_id != "" -> key_id
      _ -> ""
    end
  end

  @doc """
  Gets the AWS secret access key.

  Returns the configured secret access key from application config.

  ## Examples

      iex> PhoenixKit.Config.AWS.secret_access_key()
      "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

      iex> PhoenixKit.Config.AWS.secret_access_key()
      nil

  """
  @spec secret_access_key() :: String.t()
  def secret_access_key do
    case get(:secret_access_key) do
      {:ok, secret} when is_binary(secret) and secret != "" -> secret
      _ -> ""
    end
  end
end
