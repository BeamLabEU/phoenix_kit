defmodule PhoenixKit do
  @moduledoc """
  PhoenixKit
  """

  alias PhoenixKit.Config

  @doc """
  Returns the current version of PhoenixKit.

  ## Examples

      iex> PhoenixKit.version()
      "1.3.3"

  """
  @spec version() :: String.t()
  def version do
    Application.spec(:phoenix_kit, :vsn) |> to_string()
  end

  @doc """
  Validates if PhoenixKit is properly configured.

  Checks for required configuration keys and returns a status.

  ## Examples

      iex> PhoenixKit.configured?()
      false

  """
  @spec configured?() :: boolean()
  def configured? do
    case Config.get(:repo, nil) do
      nil -> false
      _repo -> true
    end
  end

  @doc """
  Returns PhoenixKit configuration.

  ## Examples

      iex> PhoenixKit.config()
      %{ecto_repos: []}

  """
  @spec config() :: map()
  def config do
    :phoenix_kit
    |> Application.get_all_env()
    |> Enum.into(%{})
  end
end
