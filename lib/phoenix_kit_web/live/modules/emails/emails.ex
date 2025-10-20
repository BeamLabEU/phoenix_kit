defmodule PhoenixKitWeb.Live.Modules.Emails.Emails do
  @moduledoc """
  LiveView for displaying and managing emails in PhoenixKit admin panel.

  Provides comprehensive email interface with filtering, searching,
  and detailed analytics for sent emails.

  ## Features

  - **Real-time Log List**: Live updates of emails
  - **Advanced Filtering**: By status, date range, recipient, campaign, template
  - **Search Functionality**: Search across recipients, subjects, campaigns
  - **Pagination**: Handle large volumes of emails
  - **Export**: CSV export functionality
  - **Quick Actions**: Resend, view details, mark as reviewed
  - **Statistics Summary**: Key metrics at the top of the page

  ## Route

  This LiveView is mounted at `{prefix}/admin/emails` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Usage

      # In your Phoenix router
      live "/admin/emails", PhoenixKitWeb.Live.Modules.Emails.Emails, :index

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Emails
  alias PhoenixKit.Emails.TableColumns
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  @default_per_page 25
  @max_per_page 100

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    # Check if email tracking is enabled
    if Emails.enabled?() do
      # Get project title from settings
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      # Load table columns configuration
      selected_columns = TableColumns.get_user_table_columns()
      available_columns = TableColumns.get_available_columns()

      socket =
        socket
        |> assign(:page_title, "Emails")
        |> assign(:project_title, project_title)
        |> assign(:logs, [])
        |> assign(:total_count, 0)
        |> assign(:stats, %{})
        |> assign(:loading, true)
        |> assign(:show_test_email_modal, false)
        |> assign(:test_email_sending, false)
        |> assign(:test_email_form, %{recipient: "", errors: %{}})
        |> assign(:selected_columns, selected_columns)
        |> assign(:available_columns, available_columns)
        |> assign(:show_column_modal, false)
        |> assign_filter_defaults()
        |> assign_pagination_defaults()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Email management is not enabled")
       |> push_navigate(to: Routes.path("/admin/dashboard"))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> apply_params(params)
      |> load_email_logs()
      |> load_stats()

    {:noreply, socket}
  end

  ## --- Event Handlers ---

  @impl true
  def handle_event("filter", params, socket) do
    # Handle both search and filter parameters
    combined_params = %{}

    # Extract search parameters
    combined_params =
      case Map.get(params, "search") do
        %{"query" => query} -> Map.put(combined_params, "search", String.trim(query || ""))
        _ -> combined_params
      end

    # Extract filter parameters
    combined_params =
      case Map.get(params, "filter") do
        filter_params when is_map(filter_params) -> Map.merge(combined_params, filter_params)
        _ -> combined_params
      end

    # Reset to first page when filtering
    combined_params = Map.put(combined_params, "page", "1")

    # Build new URL parameters
    new_params = build_url_params(socket.assigns, combined_params)

    {:noreply,
     socket
     |> push_patch(to: Routes.path("/admin/emails?#{new_params}"))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> push_patch(to: Routes.path("/admin/emails"))}
  end

  @impl true
  def handle_event("view_details", %{"id" => log_id}, socket) do
    {:noreply,
     socket
     |> push_navigate(to: Routes.path("/admin/emails/email/#{log_id}"))}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_email_logs()
     |> load_stats()}
  end

  @impl true
  def handle_event("show_test_email_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_test_email_modal, true)
     |> assign(:test_email_form, %{recipient: "", errors: %{}})}
  end

  @impl true
  def handle_event("hide_test_email_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_test_email_modal, false)
     |> assign(:test_email_sending, false)
     |> assign(:test_email_form, %{recipient: "", errors: %{}})}
  end

  @impl true
  def handle_event("validate_test_email", %{"test_email" => %{"recipient" => recipient}}, socket) do
    errors = validate_test_email_form(recipient)

    form = %{
      recipient: recipient,
      errors: errors
    }

    {:noreply, assign(socket, :test_email_form, form)}
  end

  @impl true
  def handle_event("send_test_email", %{"test_email" => %{"recipient" => recipient}}, socket) do
    errors = validate_test_email_form(recipient)

    if map_size(errors) == 0 do
      # Start sending process
      socket = assign(socket, :test_email_sending, true)

      # Send the test email asynchronously
      send(self(), {:send_test_email, String.trim(recipient)})

      {:noreply, socket}
    else
      # Show validation errors
      form = %{
        recipient: recipient,
        errors: errors
      }

      {:noreply, assign(socket, :test_email_form, form)}
    end
  end

  @impl true
  def handle_event("show_column_modal", _params, socket) do
    {:noreply, assign(socket, :show_column_modal, true)}
  end

  @impl true
  def handle_event("hide_column_modal", _params, socket) do
    {:noreply, assign(socket, :show_column_modal, false)}
  end

  @impl true
  def handle_event("toggle_column", %{"field" => field}, socket) do
    current_columns = socket.assigns.selected_columns
    available_columns = socket.assigns.available_columns

    # Check if column is required
    column_meta = Enum.find(available_columns, fn col -> col.field == field end)

    if column_meta && column_meta.required do
      # Cannot toggle required columns
      {:noreply, socket}
    else
      # Toggle column visibility
      updated_columns =
        if field in current_columns do
          List.delete(current_columns, field)
        else
          # Add column at the end
          current_columns ++ [field]
        end

      # Save to settings
      case TableColumns.update_user_table_columns(updated_columns) do
        {:ok, _} ->
          {:noreply, assign(socket, :selected_columns, updated_columns)}

        {:error, _} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to save column preferences")}
      end
    end
  end

  @impl true
  def handle_event("reorder_columns", params, socket) do
    current_columns = socket.assigns.selected_columns
    reordered = TableColumns.reorder_columns(current_columns, params)

    # Save to settings
    case TableColumns.update_user_table_columns(reordered) do
      {:ok, _} ->
        {:noreply, assign(socket, :selected_columns, reordered)}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save column order")}
    end
  end

  @impl true
  def handle_event("reset_columns", _params, socket) do
    default_columns = TableColumns.reset_columns()

    # Save to settings
    case TableColumns.update_user_table_columns(default_columns) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:selected_columns, default_columns)
         |> put_flash(:info, "Columns reset to default")}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to reset columns")}
    end
  end

  ## --- Info Handlers ---

  @impl true
  def handle_info({:send_test_email, recipient}, socket) do
    case PhoenixKit.Mailer.send_test_tracking_email(recipient) do
      {:ok, _email} ->
        Logger.info("Test email sent successfully", %{
          recipient: recipient,
          module: __MODULE__
        })

        {:noreply,
         socket
         |> assign(:test_email_sending, false)
         |> assign(:show_test_email_modal, false)
         |> put_flash(
           :info,
           "Test email sent successfully to #{recipient}! Check your emails to see the management data."
         )
         |> load_email_logs()
         |> load_stats()}

      {:error, reason} ->
        Logger.error("Failed to send test email", %{
          recipient: recipient,
          reason: inspect(reason),
          module: __MODULE__
        })

        {:noreply,
         socket
         |> assign(:test_email_sending, false)
         |> put_flash(:error, "Failed to send test email: #{inspect(reason)}")}
    end
  rescue
    error ->
      Logger.error("Exception while sending test email", %{
        recipient: recipient,
        error_message: Exception.message(error),
        error_type: error.__struct__,
        stacktrace: Exception.format_stacktrace(__STACKTRACE__),
        module: __MODULE__
      })

      {:noreply,
       socket
       |> assign(:test_email_sending, false)
       |> put_flash(:error, "Error sending test email: #{Exception.message(error)}")}
  end

  ## --- Private Helper Functions ---

  # Apply default filter values
  defp assign_filter_defaults(socket) do
    filters = %{
      search: "",
      status: "",
      message_tag: "",
      campaign_id: "",
      from_date: "",
      to_date: ""
    }

    assign(socket, :filters, filters)
  end

  # Apply default pagination values
  defp assign_pagination_defaults(socket) do
    socket
    |> assign(:page, 1)
    |> assign(:per_page, @default_per_page)
    |> assign(:total_pages, 0)
  end

  # Apply URL parameters to socket assigns
  defp apply_params(socket, params) do
    filters = %{
      search: params["search"] || "",
      status: params["status"] || "",
      message_tag: params["message_tag"] || "",
      campaign_id: params["campaign_id"] || "",
      from_date: params["from_date"] || "",
      to_date: params["to_date"] || ""
    }

    page = String.to_integer(params["page"] || "1")
    per_page = min(String.to_integer(params["per_page"] || "#{@default_per_page}"), @max_per_page)

    socket
    |> assign(:filters, filters)
    |> assign(:page, page)
    |> assign(:per_page, per_page)
  end

  # Load emails based on current filters and pagination
  defp load_email_logs(socket) do
    %{filters: filters, page: page, per_page: per_page} = socket.assigns

    # Build filters for EmailLog query
    query_filters = build_query_filters(filters, page, per_page)

    logs = Emails.list_logs(query_filters)

    # Get total count for pagination (efficient count without loading all records)
    total_count =
      Emails.count_logs(build_query_filters(filters, 1, 1) |> Map.drop([:limit, :offset]))

    total_pages = ceil(total_count / per_page)

    socket
    |> assign(:logs, logs)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:loading, false)
  end

  # Load summary statistics
  defp load_stats(socket) do
    stats = Emails.get_system_stats(:last_30_days)

    assign(socket, :stats, stats)
  end

  # Build query filters from form filters
  defp build_query_filters(filters, page, per_page) do
    query_filters = %{
      limit: per_page,
      offset: (page - 1) * per_page
    }

    # Add non-empty filters
    query_filters =
      filters
      |> Enum.reduce(query_filters, fn
        {:search, search}, acc when search != "" ->
          # Search in recipient, subject, and campaign fields
          Map.put(acc, :search, search)

        {:status, status}, acc when status != "" ->
          Map.put(acc, :status, status)

        {:message_tag, message_tag}, acc when message_tag != "" ->
          Map.put(acc, :message_tag, message_tag)

        {:campaign_id, campaign_id}, acc when campaign_id != "" ->
          Map.put(acc, :campaign_id, campaign_id)

        {:from_date, from_date}, acc when from_date != "" ->
          case Date.from_iso8601(from_date) do
            {:ok, date} -> Map.put(acc, :from_date, DateTime.new!(date, ~T[00:00:00]))
            _ -> acc
          end

        {:to_date, to_date}, acc when to_date != "" ->
          case Date.from_iso8601(to_date) do
            {:ok, date} -> Map.put(acc, :to_date, DateTime.new!(date, ~T[23:59:59]))
            _ -> acc
          end

        _, acc ->
          acc
      end)

    query_filters
  end

  # Build URL parameters from current state
  defp build_url_params(assigns, additional_params) do
    base_params = %{
      "search" => assigns.filters.search,
      "status" => assigns.filters.status,
      "message_tag" => assigns.filters.message_tag,
      "campaign_id" => assigns.filters.campaign_id,
      "from_date" => assigns.filters.from_date,
      "to_date" => assigns.filters.to_date,
      "page" => assigns.page,
      "per_page" => assigns.per_page
    }

    Map.merge(base_params, additional_params)
    |> Enum.reject(fn {_key, value} -> value == "" or is_nil(value) end)
    |> Map.new()
    |> URI.encode_query()
  end

  # Build export URL with current filters
  defp build_export_url(filters) do
    # Convert filters to query parameters
    params =
      filters
      |> Enum.reject(fn {_key, value} -> value == "" or is_nil(value) end)
      |> Enum.into(%{})
      |> URI.encode_query()

    base_url = Routes.path("/admin/emails/export")

    if params != "" do
      "#{base_url}?#{params}"
    else
      base_url
    end
  end

  # Helper functions for template
  defp status_badge_class(status) do
    case status do
      "sent" -> "badge badge-info badge-sm"
      "delivered" -> "badge badge-success badge-sm"
      "bounced" -> "badge badge-error badge-sm"
      "opened" -> "badge badge-warning badge-sm"
      "clicked" -> "badge badge-secondary badge-sm"
      "failed" -> "badge badge-error badge-sm"
      _ -> "badge badge-ghost badge-sm"
    end
  end

  defp pagination_pages(current_page, total_pages) do
    start_page = max(1, current_page - 2)
    end_page = min(total_pages, current_page + 2)

    start_page..end_page
  end

  defp build_page_url(page, assigns) do
    params = build_url_params(assigns, %{"page" => page})
    Routes.path("/admin/emails?#{params}")
  end

  # Extract email_type from message_tags
  defp get_message_tag(message_tags) when is_map(message_tags) do
    Map.get(message_tags, "email_type")
  end

  defp get_message_tag(_), do: nil

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
  defp get_fallback_time(log, "delivery"), do: log.delivered_at
  defp get_fallback_time(log, "open"), do: log.opened_at
  defp get_fallback_time(log, "click"), do: log.clicked_at
  defp get_fallback_time(log, "bounce"), do: log.bounced_at
  defp get_fallback_time(log, "complaint"), do: log.complained_at
  defp get_fallback_time(_log, _type), do: nil

  # Builds activity badges list with smart date display
  # Each badge shows date only when it differs from previous event
  # Returns list of {badge_class, formatted_text, event_type} tuples
  defp get_activity_badges(log) do
    # Get all event times in chronological order
    events = [
      {"delivery", get_event_time(log, "delivery"), "badge-success"},
      {"open", get_event_time(log, "open"), "badge-warning"},
      {"click", get_event_time(log, "click"), "badge-secondary"},
      {"bounce", get_event_time(log, "bounce"), "badge-error"},
      {"complaint", get_event_time(log, "complaint"), "badge-accent"}
    ]

    # Filter out events that don't exist
    existing_events = Enum.filter(events, fn {_type, time, _class} -> time != nil end)

    # Start with sent_at date as the reference
    initial_date = if log.sent_at, do: DateTime.to_date(log.sent_at), else: nil

    # Build badges with smart date display using reduce
    {badges, _} =
      Enum.reduce(existing_events, {[], initial_date}, fn {type, time, badge_class},
                                                          {acc, last_date} ->
        formatted_text = format_activity_badge(last_date, time)
        new_date = DateTime.to_date(time)
        {acc ++ [{badge_class, formatted_text, type}], new_date}
      end)

    badges
  end

  # Smart format for activity badges: shows date only if different from previous event
  # Compares event with previous shown event in the chain
  # If event happened same day as previous -> shows only time (09:14)
  # If event happened different day -> shows date+time (21.10 09:14)
  defp format_activity_badge(_previous_date, nil), do: ""

  defp format_activity_badge(previous_date, event_time) do
    time_format = Settings.get_setting("time_format", "H:i")
    time_str = UtilsDate.format_time(event_time, time_format)

    # Compare event date with previous event date
    event_date = DateTime.to_date(event_time)

    if Date.compare(previous_date, event_date) == :eq do
      # Same day as previous event - show only time
      time_str
    else
      # Different day from previous event - show date + time
      date_str = UtilsDate.format_date(event_date, "d.m")
      "#{date_str} #{time_str}"
    end
  end

  # Format datetime for compact sent badge (DD.MM HH:MM format)
  defp format_sent_badge(nil), do: ""

  defp format_sent_badge(datetime) do
    time_format = Settings.get_setting("time_format", "H:i")

    # Short date format: d.m (day.month)
    date_str = UtilsDate.format_date(datetime, "d.m")
    time_str = UtilsDate.format_time(datetime, time_format)

    "#{date_str} #{time_str}"
  end

  # Validate test email form
  defp validate_test_email_form(recipient) do
    errors = %{}

    # Validate recipient email
    errors =
      case String.trim(recipient || "") do
        "" ->
          Map.put(errors, :recipient, "Email address is required")

        email ->
          if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email) do
            errors
          else
            Map.put(errors, :recipient, "Please enter a valid email address")
          end
      end

    errors
  end
end
