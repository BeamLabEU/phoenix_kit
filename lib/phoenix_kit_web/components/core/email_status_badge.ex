defmodule PhoenixKitWeb.Components.Core.EmailStatusBadge do
  @moduledoc """
  Provides email status badge components for email tracking system.

  Supports all email lifecycle statuses with appropriate color coding.
  Follows daisyUI badge styling conventions.
  """

  use Phoenix.Component

  @doc """
  Renders an email status badge with appropriate styling.

  ## Attributes
  - `status` - Email status string (required)
  - `size` - Badge size: :xs, :sm, :md, :lg (default: :sm)
  - `class` - Additional CSS classes

  ## Supported Statuses
  - `queued` - Email queued for sending (ghost/gray)
  - `sent` - Email sent to provider (info/blue)
  - `delivered` - Email delivered successfully (success/green)
  - `opened` - Email opened by recipient (primary)
  - `clicked` - Links clicked (secondary)
  - `bounced` - General bounce (error/red)
  - `hard_bounced` - Permanent bounce (error/red)
  - `soft_bounced` - Temporary bounce (warning/yellow)
  - `rejected` - Rejected by provider (error/red)
  - `delayed` - Delivery delayed (warning/yellow)
  - `complaint` - Spam complaint (error/red)
  - `failed` - Send failed (error/red)

  ## Examples

      <.email_status_badge status="delivered" />
      <.email_status_badge status="hard_bounced" size={:md} />
      <.email_status_badge status={@log.status} class="ml-2" />
  """
  attr :status, :string, required: true
  attr :size, :atom, default: :sm, values: [:xs, :sm, :md, :lg]
  attr :class, :string, default: ""

  def email_status_badge(assigns) do
    ~H"""
    <span class={["badge", status_class(@status), size_class(@size), @class]}>
      {format_status(@status)}
    </span>
    """
  end

  # Private helper functions

  # Email status badge classes
  defp status_class("queued"), do: "badge-ghost"
  defp status_class("sent"), do: "badge-info"
  defp status_class("delivered"), do: "badge-success"
  defp status_class("opened"), do: "badge-primary"
  defp status_class("clicked"), do: "badge-secondary"
  defp status_class("bounced"), do: "badge-error"
  defp status_class("hard_bounced"), do: "badge-error"
  defp status_class("soft_bounced"), do: "badge-warning"
  defp status_class("rejected"), do: "badge-error"
  defp status_class("delayed"), do: "badge-warning"
  defp status_class("complaint"), do: "badge-error"
  defp status_class("failed"), do: "badge-error"
  defp status_class(_), do: "badge-ghost"

  # Format status text for display
  defp format_status("hard_bounced"), do: "Hard Bounced"
  defp format_status("soft_bounced"), do: "Soft Bounced"
  defp format_status(status), do: String.capitalize(status)

  # Size classes
  defp size_class(:xs), do: "badge-xs"
  defp size_class(:sm), do: "badge-sm"
  defp size_class(:md), do: "badge-md"
  defp size_class(:lg), do: "badge-lg"
end
