defmodule PhoenixKitWeb.Components.Core.EmailActivityBadges do
  @moduledoc """
  Provides email activity badges component for chronological event display.

  Renders timeline of email events as compact badges with smart date formatting.
  Shows date only when it changes between events, otherwise shows time only.

  Supported events: queued, send, delivery, open, click, bounce (hard/soft),
  rejected, delivery_delay, subscription, complaint, rendering_failure, failed.
  """

  use Phoenix.Component
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @doc """
  Renders chronological activity badges for an email log.

  Each badge shows an event with smart date/time formatting:
  - First event: shows date + time (e.g., "04.11 09:15")
  - Subsequent events on same day: shows time only (e.g., "09:20")
  - Events on different day: shows date + time again

  ## Attributes
  - `log` - Email log struct with status and timestamp fields (required)

  ## Examples

      <.email_activity_badges log={@email_log} />

      <%!-- Renders badges like: --%>
      <%!-- [queued: 04.11 09:15] [sent: 09:16] [delivered: 09:18] --%>
  """
  attr :log, :map, required: true

  def email_activity_badges(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1">
      <%!-- Activity badges with chronological status display --%>
      <%!-- Each badge shows status event with smart date formatting --%>
      <%= for {badge_class, formatted_text, _event_type} <- build_badges(@log) do %>
        <div class={"badge #{badge_class} badge-xs"}>
          {formatted_text}
        </div>
      <% end %>
    </div>
    """
  end

  # Private helper functions

  # Builds activity badges list with smart date display
  # Each badge shows date only when it differs from previous event
  # Returns list of {badge_class, formatted_text, event_type} tuples
  defp build_badges(log) do
    # Get all event times in chronological order
    # Note: bounce events are handled specially based on log.status
    events = [
      {"queued", get_event_time(log, "queued"), "badge-ghost"},
      {"send", get_event_time(log, "send"), "badge-info"},
      {"delivery", get_event_time(log, "delivery"), "badge-success"},
      {"open", get_event_time(log, "open"), "badge-warning"},
      {"click", get_event_time(log, "click"), "badge-secondary"},
      # Handle different bounce types based on status
      {get_bounce_type(log.status), get_event_time(log, "bounce"),
       get_bounce_badge_class(log.status)},
      {"rejected", get_event_time(log, "rejected"), "badge-error"},
      {"delivery_delay", get_event_time(log, "delivery_delay"), "badge-warning"},
      {"subscription", get_event_time(log, "subscription"), "badge-info"},
      {"complaint", get_event_time(log, "complaint"), "badge-accent"},
      {"rendering_failure", get_event_time(log, "rendering_failure"), "badge-error"},
      {"failed", get_event_time(log, "failed"), "badge-error"}
    ]

    # Filter out events that don't exist
    existing_events = Enum.filter(events, fn {_type, time, _class} -> time != nil end)

    # Start with nil to ensure first event shows date
    # Build badges with smart date display using reduce
    {badges, _} =
      Enum.reduce(existing_events, {[], nil}, fn {type, time, badge_class}, {acc, last_date} ->
        formatted_text = format_badge_text(type, last_date, time)
        new_date = DateTime.to_date(time)
        {acc ++ [{badge_class, formatted_text, type}], new_date}
      end)

    badges
  end

  # Get event timestamp from log's events association
  # Falls back to log fields if events not loaded
  defp get_event_time(log, event_type) do
    case log.events do
      # Events loaded - search for matching event type
      events when is_list(events) ->
        events
        |> Enum.find(fn event -> event.event_type == event_type end)
        |> case do
          nil -> get_fallback_time(log, event_type)
          event -> event.occurred_at
        end

      # Events not loaded - use fallback fields
      _ ->
        get_fallback_time(log, event_type)
    end
  end

  # Fallback to log timestamp fields if event not found
  defp get_fallback_time(log, "queued"), do: log.queued_at
  defp get_fallback_time(log, "send"), do: log.sent_at
  defp get_fallback_time(log, "delivery"), do: log.delivered_at
  defp get_fallback_time(log, "open"), do: log.opened_at
  defp get_fallback_time(log, "click"), do: log.clicked_at
  defp get_fallback_time(log, "bounce"), do: log.bounced_at
  defp get_fallback_time(log, "hard_bounce"), do: log.bounced_at
  defp get_fallback_time(log, "soft_bounce"), do: log.bounced_at
  defp get_fallback_time(log, "rejected"), do: log.rejected_at
  defp get_fallback_time(log, "delivery_delay"), do: log.delayed_at
  defp get_fallback_time(_log, "subscription"), do: nil
  defp get_fallback_time(log, "complaint"), do: log.complained_at
  defp get_fallback_time(log, "rendering_failure"), do: log.failed_at
  defp get_fallback_time(log, "failed"), do: log.failed_at
  defp get_fallback_time(_log, _type), do: nil

  # Determine bounce type label based on status
  defp get_bounce_type("hard_bounced"), do: "hard_bounce"
  defp get_bounce_type("soft_bounced"), do: "soft_bounce"
  defp get_bounce_type("bounced"), do: "bounce"
  defp get_bounce_type(_), do: "bounce"

  # Determine badge class for bounce based on status
  defp get_bounce_badge_class("hard_bounced"), do: "badge-error"
  defp get_bounce_badge_class("soft_bounced"), do: "badge-warning"
  defp get_bounce_badge_class("bounced"), do: "badge-error"
  defp get_bounce_badge_class(_), do: "badge-error"

  # Format badge text with smart date display (without label)
  # Shows only time, with date only if different from previous event
  defp format_badge_text(_event_type, previous_date, event_time) do
    format_time_smart(previous_date, event_time)
  end

  # Smart format for activity badges: shows date only if different from previous event
  # Compares event with previous shown event in the chain
  # If event happened same day as previous -> shows only time (09:14)
  # If event happened different day -> shows date+time (21.10 09:14)
  # If no previous date (first event) -> always shows date+time
  defp format_time_smart(_previous_date, nil), do: ""

  defp format_time_smart(nil, event_time) do
    # First event - always show date + time
    time_format = Settings.get_setting("time_format", "H:i")
    time_str = UtilsDate.format_time(event_time, time_format)
    event_date = DateTime.to_date(event_time)
    date_str = UtilsDate.format_date(event_date, "d.m")
    "#{date_str} #{time_str}"
  end

  defp format_time_smart(previous_date, event_time) do
    time_format = Settings.get_setting("time_format", "H:i")
    time_str = UtilsDate.format_time(event_time, time_format)
    event_date = DateTime.to_date(event_time)

    # Show date + time if day changed, otherwise just time
    if Date.compare(event_date, previous_date) == :eq do
      time_str
    else
      date_str = UtilsDate.format_date(event_date, "d.m")
      "#{date_str} #{time_str}"
    end
  end
end
