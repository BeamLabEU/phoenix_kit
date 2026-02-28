defmodule PhoenixKitWeb.Components.Core.TimeDisplay do
  @moduledoc """
  Provides time and date display components with relative and absolute formatting.

  These components handle time formatting consistently across the application,
  including relative time displays ("5m ago"), age badges with color coding,
  and expiration date formatting.
  """

  use Phoenix.Component
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @doc """
  Displays relative time (e.g., "5m ago", "2h ago", "3d ago").

  Uses a client-side JavaScript hook for efficient updates without server load.
  Updates every second for recent times, less frequently for older times.

  ## Attributes
  - `datetime` - DateTime struct or nil
  - `class` - CSS classes (default: "text-xs")

  ## Examples

      <.time_ago datetime={session.connected_at} />
      <.time_ago datetime={user.last_seen} class="text-sm text-gray-500" />
      <.time_ago datetime={nil} />  <!-- Shows "—" -->
      <.time_ago datetime={request.inserted_at} id="request-time-123" />
  """
  attr :datetime, :any, required: true
  attr :class, :string, default: "text-xs"
  attr :id, :string, default: nil, doc: "Optional DOM id (auto-generated if not provided)"

  def time_ago(assigns) do
    assigns =
      assigns
      |> assign(:iso_datetime, format_iso8601(assigns.datetime))
      |> assign_new(:dom_id, fn ->
        # Use provided id, or generate a unique one to avoid collisions
        assigns[:id] || "time-ago-#{System.unique_integer([:positive])}"
      end)

    ~H"""
    <%= if @iso_datetime do %>
      <time
        phx-hook="TimeAgo"
        id={@dom_id}
        class={@class}
        datetime={@iso_datetime}
        data-datetime={@iso_datetime}
        title={format_datetime_title(@datetime)}
      >
        {format_time_ago(@datetime)}
      </time>
    <% else %>
      <span class={@class}>—</span>
    <% end %>
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

  @doc """
  Displays formatted duration between two DateTime values.

  Formats duration in human-readable format with appropriate units:
  - Less than 1 minute: "45s"
  - Less than 1 hour: "5m 30s"
  - 1 hour or more: "2h 15m"

  ## Attributes
  - `start_time` - Start DateTime
  - `end_time` - End DateTime
  - `class` - CSS classes

  ## Examples

      <.duration_display start_time={@log.queued_at} end_time={@log.sent_at} />
      <%!-- Shows: "3m 45s" --%>

      <.duration_display
        start_time={@log.sent_at}
        end_time={@log.delivered_at}
        class="text-sm font-mono"
      />
      <%!-- Shows: "125s" --%>
  """
  attr :start_time, :any, required: true
  attr :end_time, :any, required: true
  attr :class, :string, default: ""

  def duration_display(assigns) do
    ~H"""
    <span class={@class}>
      {format_duration(@start_time, @end_time)}
    </span>
    """
  end

  # Private formatters

  defp format_iso8601(nil), do: nil

  defp format_iso8601(datetime) when is_struct(datetime, DateTime) do
    DateTime.to_iso8601(datetime)
  end

  defp format_iso8601(datetime) when is_struct(datetime, NaiveDateTime) do
    NaiveDateTime.to_iso8601(datetime) <> "Z"
  end

  defp format_iso8601(_), do: nil

  defp format_time_ago(nil), do: "—"

  defp format_time_ago(datetime) when is_struct(datetime, DateTime) do
    now = UtilsDate.utc_now()
    diff_seconds = DateTime.diff(now, datetime, :second)
    format_seconds_ago(diff_seconds)
  end

  defp format_time_ago(datetime) when is_struct(datetime, NaiveDateTime) do
    now = NaiveDateTime.utc_now()
    diff_seconds = NaiveDateTime.diff(now, datetime, :second)
    format_seconds_ago(diff_seconds)
  end

  defp format_time_ago(_), do: "Unknown"

  defp format_seconds_ago(diff_seconds) do
    cond do
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3_600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3_600)}h ago"
      true -> "#{div(diff_seconds, 86_400)}d ago"
    end
  end

  defp format_datetime_title(nil), do: nil

  defp format_datetime_title(datetime) when is_struct(datetime, DateTime) do
    Calendar.strftime(datetime, "%B %d, %Y at %H:%M:%S UTC")
  end

  defp format_datetime_title(datetime) when is_struct(datetime, NaiveDateTime) do
    Calendar.strftime(datetime, "%B %d, %Y at %H:%M:%S")
  end

  defp format_datetime_title(_), do: nil

  defp format_expiration(nil), do: "No expiration"

  defp format_expiration(date) do
    Calendar.strftime(date, "%B %d, %Y")
  end

  defp format_age(days) when days < 1, do: {"badge-success", "Today"}
  defp format_age(days) when days < 7, do: {"badge-info", "#{days}d"}
  defp format_age(days) when days < 30, do: {"badge-warning", "#{days}d"}
  defp format_age(days), do: {"badge-error", "#{days}d"}

  defp format_duration(start_time, end_time)
       when is_struct(start_time, DateTime) and is_struct(end_time, DateTime) do
    diff_seconds = DateTime.diff(end_time, start_time, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m #{rem(diff_seconds, 60)}s"
      true -> "#{div(diff_seconds, 3600)}h #{div(rem(diff_seconds, 3600), 60)}m"
    end
  end

  defp format_duration(_, _), do: "—"
end
