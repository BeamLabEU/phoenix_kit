defmodule PhoenixKit.Utils.UUID do
  @moduledoc """
  Utilities for working with UUIDs.
  """

  @doc """
  Checks if a string is a valid UUID.

  Uses `Ecto.UUID.cast/1` for robust validation that handles
  all UUID formats (v4, v7, etc.).

  ## Examples

      iex> PhoenixKit.Utils.UUID.valid?("550e8400-e29b-41d4-a716-446655440000")
      true

      iex> PhoenixKit.Utils.UUID.valid?("not-a-uuid")
      false

      iex> PhoenixKit.Utils.UUID.valid?(123)
      false
  """
  def valid?(string) when is_binary(string) do
    match?({:ok, _}, Ecto.UUID.cast(string))
  end

  def valid?(_), do: false
end
