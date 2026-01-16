defmodule PhoenixKitWeb.Components.Core.InvoiceStatusBadge do
  @moduledoc """
  Provides invoice status badge components for the billing system.

  Supports all invoice lifecycle statuses with appropriate color coding.
  Follows daisyUI badge styling conventions.
  """

  use Phoenix.Component

  @doc """
  Renders an invoice status badge with appropriate styling.

  ## Attributes
  - `status` - Invoice status string (required)
  - `size` - Badge size: :xs, :sm, :md, :lg (default: :sm)
  - `class` - Additional CSS classes

  ## Supported Statuses
  - `draft` - Invoice in draft state (ghost/gray)
  - `sent` - Invoice sent to customer (info/blue)
  - `paid` - Invoice paid successfully (success/green)
  - `void` - Invoice voided (error/red)
  - `overdue` - Invoice payment overdue (warning/yellow)

  ## Examples

      <.invoice_status_badge status="paid" />
      <.invoice_status_badge status="overdue" size={:md} />
      <.invoice_status_badge status={@invoice.status} class="ml-2" />
  """
  attr :status, :string, required: true
  attr :size, :atom, default: :sm, values: [:xs, :sm, :md, :lg]
  attr :class, :string, default: ""

  def invoice_status_badge(assigns) do
    ~H"""
    <span class={["badge", status_class(@status), size_class(@size), @class]}>
      {format_status(@status)}
    </span>
    """
  end

  # Private helper functions

  # Invoice status badge classes
  defp status_class("draft"), do: "badge-ghost"
  defp status_class("sent"), do: "badge-info"
  defp status_class("paid"), do: "badge-success"
  defp status_class("void"), do: "badge-error"
  defp status_class("overdue"), do: "badge-warning"
  defp status_class(_), do: "badge-ghost"

  # Format status text for display
  defp format_status(status), do: String.capitalize(status)

  # Size classes
  defp size_class(:xs), do: "badge-xs"
  defp size_class(:sm), do: "badge-sm"
  defp size_class(:md), do: "badge-md"
  defp size_class(:lg), do: "badge-lg"
end
