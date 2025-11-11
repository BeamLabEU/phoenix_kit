defmodule PhoenixKit.Utils.Number do
  @moduledoc """
  Number formatting utilities for PhoenixKit.

  Provides functions for formatting numbers with thousand separators,
  abbreviations, and other common number formatting needs.
  """

  @doc """
  Formats a number with thousand separators.

  ## Examples

      iex> PhoenixKit.Utils.Number.format(1234567)
      "1,234,567"

      iex> PhoenixKit.Utils.Number.format(0)
      "0"

      iex> PhoenixKit.Utils.Number.format(nil)
      "0"
  """
  @spec format(integer() | nil) :: String.t()
  def format(number) when is_integer(number) do
    number
    |> to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &Enum.join/1)
  end

  def format(_number), do: "0"

  @doc """
  Formats a number with abbreviations (K, M, B).

  ## Examples

      iex> PhoenixKit.Utils.Number.format_short(1_234_567)
      "1.2M"

      iex> PhoenixKit.Utils.Number.format_short(5_432)
      "5.4K"

      iex> PhoenixKit.Utils.Number.format_short(123)
      "123"
  """
  @spec format_short(integer() | nil) :: String.t()
  def format_short(number) when is_integer(number) do
    cond do
      number >= 1_000_000_000 ->
        "#{Float.round(number / 1_000_000_000, 1)}B"

      number >= 1_000_000 ->
        "#{Float.round(number / 1_000_000, 1)}M"

      number >= 1_000 ->
        "#{Float.round(number / 1_000, 1)}K"

      true ->
        to_string(number)
    end
  end

  def format_short(_number), do: "0"

  @doc """
  Formats a number as a percentage.

  ## Examples

      iex> PhoenixKit.Utils.Number.format_percentage(95.5)
      "95.5%"

      iex> PhoenixKit.Utils.Number.format_percentage(100)
      "100%"

      iex> PhoenixKit.Utils.Number.format_percentage(nil)
      "0%"
  """
  @spec format_percentage(float() | integer() | nil) :: String.t()
  def format_percentage(rate) when is_float(rate) do
    "#{:erlang.float_to_binary(rate, decimals: 1)}%"
  end

  def format_percentage(rate) when is_integer(rate) do
    "#{rate}%"
  end

  def format_percentage(_), do: "0%"
end
