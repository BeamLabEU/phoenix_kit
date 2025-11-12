defmodule PhoenixKitWeb.Components.Core.NumberFormatter do
  @moduledoc """
  Number formatting components for PhoenixKit.

  Provides components for displaying numbers with proper formatting including
  thousand separators, abbreviations, and custom formatting options.
  """

  use Phoenix.Component

  @doc """
  Displays a formatted number with thousand separators.

  ## Attributes
  - `number` - The number to format (required, integer or any)
  - `format` - Format style (default: :grouped)
    - `:grouped` - Add comma separators (1,234,567)
    - `:short` - Abbreviate large numbers (1.2M, 3.5K)
  - `class` - Additional CSS classes

  ## Examples

      <.formatted_number number={1234567} />
      # Renders: 1,234,567

      <.formatted_number number={1234567} format={:short} />
      # Renders: 1.2M

      <.formatted_number number={0} />
      # Renders: 0
  """
  attr :number, :any, required: true
  attr :format, :atom, default: :grouped, values: [:grouped, :short]
  attr :class, :string, default: ""

  def formatted_number(assigns) do
    formatted = format_number_value(assigns.number, assigns.format)

    assigns = assign(assigns, :formatted, formatted)

    ~H"""
    <span class={@class}>{@formatted}</span>
    """
  end

  # Private helper functions

  # Format number with thousand separators
  defp format_number_value(number, :grouped) when is_integer(number) do
    number
    |> to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &Enum.join/1)
  end

  # Format number with abbreviations (K, M, B)
  defp format_number_value(number, :short) when is_integer(number) do
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

  # Fallback for non-integers
  defp format_number_value(number, _format), do: to_string(number)
end
