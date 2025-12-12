defmodule PhoenixKitWeb.Components.Core.OrderStatusBadge do
  @moduledoc """
  Provides order status badge components for the billing system.

  Supports all order lifecycle statuses with appropriate color coding.
  Follows daisyUI badge styling conventions.
  """

  use Phoenix.Component

  @doc """
  Renders an order status badge with appropriate styling.

  ## Attributes
  - `status` - Order status string (required)
  - `size` - Badge size: :xs, :sm, :md, :lg (default: :sm)
  - `class` - Additional CSS classes

  ## Supported Statuses
  - `draft` - Order in draft state (ghost/gray)
  - `pending` - Order pending confirmation (warning/yellow)
  - `confirmed` - Order confirmed (info/blue)
  - `paid` - Order paid successfully (success/green)
  - `cancelled` - Order cancelled (error/red)
  - `refunded` - Order refunded (secondary/purple)

  ## Examples

      <.order_status_badge status="paid" />
      <.order_status_badge status="pending" size={:md} />
      <.order_status_badge status={@order.status} class="ml-2" />
  """
  attr :status, :string, required: true
  attr :size, :atom, default: :sm, values: [:xs, :sm, :md, :lg]
  attr :class, :string, default: ""

  def order_status_badge(assigns) do
    ~H"""
    <span class={["badge", status_class(@status), size_class(@size), @class]}>
      {format_status(@status)}
    </span>
    """
  end

  # Private helper functions

  # Order status badge classes
  defp status_class("draft"), do: "badge-ghost"
  defp status_class("pending"), do: "badge-warning"
  defp status_class("confirmed"), do: "badge-info"
  defp status_class("paid"), do: "badge-success"
  defp status_class("cancelled"), do: "badge-error"
  defp status_class("refunded"), do: "badge-secondary"
  defp status_class(_), do: "badge-ghost"

  # Format status text for display
  defp format_status(status), do: String.capitalize(status)

  # Size classes
  defp size_class(:xs), do: "badge-xs"
  defp size_class(:sm), do: "badge-sm"
  defp size_class(:md), do: "badge-md"
  defp size_class(:lg), do: "badge-lg"
end
