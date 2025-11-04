defmodule PhoenixKitWeb.Components.Core.EventTimelineItem do
  @moduledoc """
  Provides event timeline item component for email event visualization.

  Renders timeline events with markers, icons, titles, timestamps,
  and event-specific details. Used in email tracking details view.
  """

  use Phoenix.Component
  import PhoenixKitWeb.Components.Core.Icon

  @doc """
  Renders a timeline event item with marker, icon, title, and details.

  ## Attributes
  - `event` - Event struct with event_type, occurred_at, event_data, etc. (required)
  - `log` - Email log struct for context (optional)

  ## Examples

      <.event_timeline_item event={event} log={@log} />
      <.event_timeline_item event={event} />
  """
  attr :event, :map, required: true
  attr :log, :map, default: nil

  def event_timeline_item(assigns) do
    ~H"""
    <div class="flex gap-4">
      <%!-- Event marker with icon --%>
      <div class={marker_class(@event.event_type)}>
        <.icon name={event_icon(@event.event_type)} class="w-4 h-4" />
      </div>

      <%!-- Event content --%>
      <div class="flex-1 pb-8">
        <div class="flex items-center justify-between mb-1">
          <h3 class="text-sm font-medium text-base-content">
            {format_title(@event.event_type)}
          </h3>
          <time class="text-xs text-base-content/60">
            {Calendar.strftime(@event.occurred_at, "%b %d, %H:%M:%S")}
          </time>
        </div>

        <%!-- Event-specific details --%>
        {render_details(@event)}
      </div>
    </div>
    """
  end

  # Private helper functions

  # Event marker classes with background colors
  defp marker_class(event_type) do
    base = "w-6 h-6 rounded-full flex items-center justify-center text-white flex-shrink-0"

    color =
      case event_type do
        "queued" -> "bg-gray-500"
        "send" -> "bg-blue-500"
        "delivery" -> "bg-green-500"
        "bounce" -> "bg-red-500"
        "reject" -> "bg-red-600"
        "delay" -> "bg-yellow-500"
        "complaint" -> "bg-orange-500"
        "open" -> "bg-purple-500"
        "click" -> "bg-indigo-500"
        "fail" -> "bg-red-700"
        _ -> "bg-base-content"
      end

    "#{base} #{color}"
  end

  # Event icons
  defp event_icon("queued"), do: "hero-clock"
  defp event_icon("send"), do: "hero-paper-airplane"
  defp event_icon("delivery"), do: "hero-check-circle"
  defp event_icon("bounce"), do: "hero-exclamation-triangle"
  defp event_icon("reject"), do: "hero-x-circle"
  defp event_icon("delay"), do: "hero-clock"
  defp event_icon("complaint"), do: "hero-flag"
  defp event_icon("open"), do: "hero-eye"
  defp event_icon("click"), do: "hero-cursor-arrow-rays"
  defp event_icon("fail"), do: "hero-x-mark"
  defp event_icon(_), do: "hero-clock"

  # Event title formatting
  defp format_title("queued"), do: "Email Queued"
  defp format_title("send"), do: "Email Sent"
  defp format_title("delivery"), do: "Email Delivered"
  defp format_title("bounce"), do: "Email Bounced"
  defp format_title("reject"), do: "Email Rejected"
  defp format_title("delay"), do: "Delivery Delayed"
  defp format_title("complaint"), do: "Spam Complaint"
  defp format_title("open"), do: "Email Opened"
  defp format_title("click"), do: "Link Clicked"
  defp format_title("fail"), do: "Send Failed"
  defp format_title(type), do: String.capitalize(type)

  # Render event-specific details
  defp render_details(%{event_type: "queued"} = event) do
    assigns = %{event: event}

    ~H"""
    <div class="text-xs text-base-content/60">
      <div>Email queued for sending</div>
      <%= if get_in(@event.event_data, ["timestamp"]) do %>
        <div class="text-xs opacity-70">{get_in(@event.event_data, ["timestamp"])}</div>
      <% end %>
    </div>
    """
  end

  defp render_details(%{event_type: "send"} = event) do
    assigns = %{event: event}

    ~H"""
    <div class="text-xs text-base-content/60">
      <%= if get_in(@event.event_data, ["provider"]) do %>
        <div>
          Provider: <span class="font-medium">{get_in(@event.event_data, ["provider"])}</span>
        </div>
      <% end %>
      <%= if get_in(@event.event_data, ["timestamp"]) do %>
        <div class="text-xs opacity-70">{get_in(@event.event_data, ["timestamp"])}</div>
      <% end %>
    </div>
    """
  end

  defp render_details(%{event_type: "delivery"} = event) do
    assigns = %{event: event}

    ~H"""
    <div class="text-xs text-base-content/60">
      <%= if get_in(@event.event_data, ["processingTimeMillis"]) do %>
        <div>
          Processing time:
          <span class="font-medium">{get_in(@event.event_data, ["processingTimeMillis"])} ms</span>
        </div>
      <% end %>
      <%= if get_in(@event.event_data, ["smtpResponse"]) do %>
        <div>
          SMTP:
          <span class="font-mono text-success">{get_in(@event.event_data, ["smtpResponse"])}</span>
        </div>
      <% end %>
      <%= if get_in(@event.event_data, ["reportingMTA"]) do %>
        <div>
          Server: <span class="font-mono">{get_in(@event.event_data, ["reportingMTA"])}</span>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_details(%{event_type: "bounce"} = event) do
    assigns = %{event: event}

    ~H"""
    <div class="text-xs text-base-content/60">
      <div>
        Type:
        <span class={[
          "font-medium",
          if(@event.bounce_type == "hard", do: "text-error", else: "text-warning")
        ]}>
          {@event.bounce_type || "unknown"}
        </span>
      </div>
      <%= if get_in(@event.event_data, ["reason"]) do %>
        <div>Reason: {get_in(@event.event_data, ["reason"])}</div>
      <% end %>
    </div>
    """
  end

  defp render_details(%{event_type: "reject"} = event) do
    assigns = %{event: event}

    ~H"""
    <div class="text-xs text-base-content/60">
      <%= if @event.reject_reason do %>
        <div>Reason: <span class="font-medium text-error">{@event.reject_reason}</span></div>
      <% end %>
      <%= if get_in(@event.event_data, ["diagnosticCode"]) do %>
        <div class="mt-1 font-mono text-xs">{get_in(@event.event_data, ["diagnosticCode"])}</div>
      <% end %>
    </div>
    """
  end

  defp render_details(%{event_type: "delay"} = event) do
    assigns = %{event: event}

    ~H"""
    <div class="text-xs text-base-content/60">
      <%= if @event.delay_type do %>
        <div>Type: <span class="font-medium">{@event.delay_type}</span></div>
      <% end %>
      <%= if get_in(@event.event_data, ["delayedUntil"]) do %>
        <div>Delayed until: {get_in(@event.event_data, ["delayedUntil"])}</div>
      <% end %>
    </div>
    """
  end

  defp render_details(%{event_type: "complaint"} = event) do
    assigns = %{event: event}

    ~H"""
    <div class="text-xs text-base-content/60">
      <div>Type: <span class="font-medium">{@event.complaint_type || "abuse"}</span></div>
      <%= if get_in(@event.event_data, ["feedback_id"]) do %>
        <div>Feedback ID: {get_in(@event.event_data, ["feedback_id"])}</div>
      <% end %>
    </div>
    """
  end

  defp render_details(%{event_type: "open"} = event) do
    assigns = %{event: event}

    ~H"""
    <div class="text-xs text-base-content/60">
      <%= if @event.ip_address do %>
        <div>IP: <span class="font-mono">{@event.ip_address}</span></div>
      <% end %>
      <%= if get_in(@event.geo_location, ["country"]) do %>
        <div>Location: {get_in(@event.geo_location, ["country"])}</div>
      <% end %>
    </div>
    """
  end

  defp render_details(%{event_type: "click"} = event) do
    assigns = %{event: event}

    ~H"""
    <div class="text-xs text-base-content/60">
      <%= if @event.link_url do %>
        <div class="mb-1">
          Link:
          <a href={@event.link_url} target="_blank" class="text-blue-600 hover:underline break-all">
            {String.slice(@event.link_url, 0, 50)}{if String.length(@event.link_url) > 50, do: "..."}
          </a>
        </div>
      <% end %>
      <%= if @event.ip_address do %>
        <div>IP: <span class="font-mono">{@event.ip_address}</span></div>
      <% end %>
    </div>
    """
  end

  defp render_details(%{event_type: "fail"} = event) do
    assigns = %{event: event}

    ~H"""
    <div class="text-xs text-base-content/60">
      <%= if @event.failure_reason do %>
        <div>Reason: <span class="font-medium text-error">{@event.failure_reason}</span></div>
      <% end %>
      <%= if get_in(@event.event_data, ["error"]) do %>
        <div class="mt-1">Error: {get_in(@event.event_data, ["error"])}</div>
      <% end %>
    </div>
    """
  end

  defp render_details(event) do
    assigns = %{event: event}

    ~H"""
    <%= if map_size(@event.event_data) > 0 do %>
      <div class="text-xs text-base-content/60">Additional data available</div>
    <% end %>
    """
  end
end
