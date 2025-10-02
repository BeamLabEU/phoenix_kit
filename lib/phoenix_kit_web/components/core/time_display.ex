defmodule PhoenixKitWeb.Components.Core.TimeDisplay do
  @moduledoc """
  Provides time and date display components with relative and absolute formatting.

  These components handle time formatting consistently across the application,
  including relative time displays ("5m ago"), age badges with color coding,
  and expiration date formatting.
  """

  use Phoenix.Component

  @doc """
  Displays relative time (e.g., "5m ago", "2h ago", "3d ago").

  ## Attributes
  - `datetime` - DateTime struct or nil
  - `class` - CSS classes (default: "text-xs")

  ## Examples

      <.time_ago datetime={session.connected_at} />
      <.time_ago datetime={user.last_seen} class="text-sm text-gray-500" />
      <.time_ago datetime={nil} />  <!-- Shows "—" -->
  """
  attr :datetime, :any, required: true
  attr :class, :string, default: "text-xs"

  def time_ago(assigns) do
    ~H"""
    <span class={@class}>
      {format_time_ago(@datetime)}
    </span>
    """
  end

  @doc """
  Displays expiration date with formatting.

  ## Attributes
  - `date` - DateTime or nil
  - `class` - CSS classes

  ## Examples

      <.expiration_date date={code.expiration_date} />
      <.expiration_date date={nil} />  <!-- Shows "No expiration" -->
  """
  attr :date, :any, default: nil
  attr :class, :string, default: "text-sm"

  def expiration_date(assigns) do
    ~H"""
    <span class={@class}>
      {format_expiration(@date)}
    </span>
    """
  end

  @doc """
  Displays age badge with color coding based on age in days.

  Color coding:
  - Green (success): Today (< 1 day)
  - Blue (info): Recent (< 7 days)
  - Yellow (warning): Week+ (< 30 days)
  - Red (error): Month+ (>= 30 days)

  ## Attributes
  - `days` - Number of days (integer)
  - `class` - Additional CSS classes

  ## Examples

      <.age_badge days={session.age_in_days} />
      <.age_badge days={0} />  <!-- Shows "Today" in green -->
      <.age_badge days={45} class="ml-2" />  <!-- Shows "45d" in red -->
  """
  attr :days, :integer, required: true
  attr :class, :string, default: ""

  def age_badge(assigns) do
    assigns = assign(assigns, :badge_data, format_age(assigns.days))

    ~H"""
    <% {badge_class, badge_text} = @badge_data %>
    <span class={["badge", badge_class, @class]}>
      {badge_text}
    </span>
    """
  end

  # Private formatters

  defp format_time_ago(nil), do: "—"

  defp format_time_ago(datetime) when is_struct(datetime, DateTime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3_600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3_600)}h ago"
      true -> "#{div(diff_seconds, 86_400)}d ago"
    end
  end

  defp format_time_ago(_), do: "Unknown"

  defp format_expiration(nil), do: "No expiration"

  defp format_expiration(date) do
    Calendar.strftime(date, "%B %d, %Y")
  end

  defp format_age(days) when days < 1, do: {"badge-success", "Today"}
  defp format_age(days) when days < 7, do: {"badge-info", "#{days}d"}
  defp format_age(days) when days < 30, do: {"badge-warning", "#{days}d"}
  defp format_age(days), do: {"badge-error", "#{days}d"}
end
