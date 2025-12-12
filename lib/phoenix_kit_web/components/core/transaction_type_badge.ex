defmodule PhoenixKitWeb.Components.Core.TransactionTypeBadge do
  @moduledoc """
  Provides transaction type badge components for the billing system.

  Supports payment and refund types with appropriate color coding.
  Follows daisyUI badge styling conventions.
  """

  use Phoenix.Component

  @doc """
  Renders a transaction type badge with appropriate styling.

  ## Attributes
  - `type` - Transaction type string: "payment" or "refund" (required)
  - `size` - Badge size: :xs, :sm, :md, :lg (default: :sm)
  - `class` - Additional CSS classes

  ## Supported Types
  - `payment` - Positive transaction (success/green)
  - `refund` - Negative transaction (error/red)

  ## Examples

      <.transaction_type_badge type="payment" />
      <.transaction_type_badge type="refund" size={:md} />
  """
  attr :type, :string, required: true
  attr :size, :atom, default: :sm, values: [:xs, :sm, :md, :lg]
  attr :class, :string, default: ""

  def transaction_type_badge(assigns) do
    ~H"""
    <span class={["badge", type_class(@type), size_class(@size), @class]}>
      {format_type(@type)}
    </span>
    """
  end

  # Type badge classes
  defp type_class("payment"), do: "badge-success"
  defp type_class("refund"), do: "badge-error"
  defp type_class(_), do: "badge-ghost"

  # Format type text for display
  defp format_type(type), do: String.capitalize(type)

  # Size classes
  defp size_class(:xs), do: "badge-xs"
  defp size_class(:sm), do: "badge-sm"
  defp size_class(:md), do: "badge-md"
  defp size_class(:lg), do: "badge-lg"
end
