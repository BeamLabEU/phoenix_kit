defmodule PhoenixKitWeb.Controllers.EmailExportController do
  @moduledoc """
  Controller for exporting email tracking data to CSV format.

  Provides server-side CSV export functionality for email logs, metrics,
  and blocklist data. Supports filtered exports based on query parameters.

  ## Features

  - **Email Logs Export**: Export filtered email logs to CSV
  - **Metrics Export**: Export email analytics and performance data
  - **Blocklist Export**: Export blocked email addresses
  - **Single Email Export**: Export individual email details
  - **Filter Support**: Respects all filtering parameters from LiveViews
  - **Large Dataset Streaming**: Efficient handling of large exports

  ## Security

  Access is restricted to users with admin or owner roles in PhoenixKit.
  All exports require proper authentication and authorization.
  """

  use PhoenixKitWeb, :controller

  alias PhoenixKit.Emails

  ## --- Email Logs Export ---

  @doc """
  Export email logs to CSV based on filter parameters.

  ## Parameters

  - `search` - Search query for recipient, subject, or campaign
  - `status` - Filter by email status (sent, delivered, bounced, etc.)
  - `message_tag` - Filter by message type (authentication, marketing, etc.)
  - `campaign_id` - Filter by campaign ID
  - `from_date` - Start date filter (YYYY-MM-DD)
  - `to_date` - End date filter (YYYY-MM-DD)

  ## Response

  Returns CSV file with appropriate headers for browser download.
  """
  def export_logs(conn, params) do
    if Emails.enabled?() do
      # Build filters from query parameters
      filters = build_export_filters(params)

      # Generate filename with timestamp
      filename = "email_logs_#{Date.utc_today()}.csv"

      # Get logs data
      logs = Emails.list_logs(filters)

      # Generate CSV content
      csv_content = generate_logs_csv(logs)

      # Send CSV file
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
      |> send_resp(200, csv_content)
    else
      conn
      |> put_flash(:error, "Email management is not enabled")
      |> redirect(to: "/phoenix_kit/admin/dashboard")
    end
  end

  @doc """
  Export email metrics data to CSV.

  ## Parameters

  - `period` - Time period (last_7_days, last_30_days, last_90_days, etc.)
  - `group_by` - Grouping option (day, week, month, campaign, provider)

  ## Response

  Returns CSV file with email metrics and analytics data.
  """
  def export_metrics(conn, params) do
    if Emails.enabled?() do
      # Get metrics based on parameters
      period = params["period"] || "last_30_days"
      group_by = params["group_by"] || "day"

      filename = "email_metrics_#{period}_#{Date.utc_today()}.csv"

      # Get metrics data
      metrics = Emails.get_engagement_metrics(String.to_atom(period))

      # Generate CSV content
      csv_content = generate_metrics_csv(metrics, group_by)

      # Send CSV file
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
      |> send_resp(200, csv_content)
    else
      conn
      |> put_flash(:error, "Email management is not enabled")
      |> redirect(to: "/phoenix_kit/admin/dashboard")
    end
  end

  @doc """
  Export email blocklist to CSV.

  ## Parameters

  - `reason` - Filter by block reason (rate_limit, manual, bounce, etc.)

  ## Response

  Returns CSV file with blocked email addresses and metadata.
  """
  def export_blocklist(conn, _params) do
    if Emails.enabled?() do
      # For now, return empty CSV as blocklist API is not fully implemented
      filename = "email_blocklist_#{Date.utc_today()}.csv"
      csv_content = "Email,Reason,Blocked At,Block Count,Last Attempt,Notes\n"

      # Send CSV file
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
      |> send_resp(200, csv_content)
    else
      conn
      |> put_flash(:error, "Email management is not enabled")
      |> redirect(to: "/phoenix_kit/admin/dashboard")
    end
  end

  @doc """
  Export single email details to CSV.

  ## Parameters

  - `id` - Email log ID

  ## Response

  Returns CSV file with detailed email information and events.
  """
  def export_email_details(conn, %{"id" => email_id}) do
    if Emails.enabled?() do
      try do
        # Convert string ID to integer
        email_id = String.to_integer(email_id)
        log = Emails.get_log!(email_id)
        # Get events for this email
        events = Emails.list_events_for_log(email_id)

        filename = "email_#{email_id}_details_#{Date.utc_today()}.csv"

        # Generate CSV content
        csv_content = generate_email_details_csv(log, events)

        # Send CSV file
        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
        |> send_resp(200, csv_content)
      rescue
        Ecto.NoResultsError ->
          conn
          |> put_flash(:error, "Email not found")
          |> redirect(to: "/phoenix_kit/admin/emails")

        ArgumentError ->
          conn
          |> put_flash(:error, "Invalid email ID")
          |> redirect(to: "/phoenix_kit/admin/emails")
      end
    else
      conn
      |> put_flash(:error, "Email management is not enabled")
      |> redirect(to: "/phoenix_kit/admin/dashboard")
    end
  end

  ## --- Private Helper Functions ---

  # Build query filters from request parameters for email logs
  defp build_export_filters(params) do
    %{}
    |> add_string_filter(params, "search", :search, &String.trim/1)
    |> add_string_filter(params, "status", :status)
    |> add_string_filter(params, "message_tag", :message_tag)
    |> add_string_filter(params, "campaign_id", :campaign_id)
    |> add_date_filter(params, "from_date", :from_date, ~T[00:00:00])
    |> add_date_filter(params, "to_date", :to_date, ~T[23:59:59])
  end

  # Helper to add string filter
  defp add_string_filter(
         filters,
         params,
         param_key,
         filter_key,
         transform_fn \\ &Function.identity/1
       ) do
    case params[param_key] do
      value when is_binary(value) and value != "" ->
        Map.put(filters, filter_key, transform_fn.(value))

      _ ->
        filters
    end
  end

  # Helper to add date filter
  defp add_date_filter(filters, params, param_key, filter_key, time) do
    case params[param_key] do
      date_str when is_binary(date_str) and date_str != "" ->
        case Date.from_iso8601(date_str) do
          {:ok, date} -> Map.put(filters, filter_key, DateTime.new!(date, time))
          _ -> filters
        end

      _ ->
        filters
    end
  end

  # Generate CSV content for email logs
  defp generate_logs_csv(logs) do
    headers = get_logs_csv_headers()
    rows = Enum.map(logs, &log_to_csv_row/1)
    format_csv_output(headers, rows)
  end

  # Get CSV headers for email logs
  defp get_logs_csv_headers do
    [
      "ID",
      "Message ID",
      "To",
      "From",
      "Subject",
      "Status",
      "Message Type",
      "Provider",
      "Sent At",
      "Delivered At",
      "Campaign",
      "Template",
      "Size (bytes)",
      "Retry Count",
      "Error Message"
    ]
  end

  # Convert email log to CSV row
  defp log_to_csv_row(log) do
    basic_fields = get_log_basic_fields(log)
    datetime_fields = get_log_datetime_fields(log)
    metadata_fields = get_log_metadata_fields(log)

    basic_fields ++ datetime_fields ++ metadata_fields
  end

  # Get basic log fields
  defp get_log_basic_fields(log) do
    [
      log.id,
      log.message_id || "",
      log.to || "",
      log.from || "",
      escape_csv_field(log.subject || ""),
      log.status || "",
      get_message_tag(log.message_tags) || "",
      log.provider || ""
    ]
  end

  # Get datetime fields
  defp get_log_datetime_fields(log) do
    [
      format_datetime_for_csv(log.sent_at),
      format_datetime_for_csv(log.delivered_at)
    ]
  end

  # Get metadata fields
  defp get_log_metadata_fields(log) do
    [
      log.campaign_id || "",
      log.template_name || "",
      log.size_bytes || "",
      log.retry_count || 0,
      escape_csv_field(log.error_message || "")
    ]
  end

  # Generate CSV content for metrics
  defp generate_metrics_csv(metrics, group_by) do
    headers = get_metrics_csv_headers(group_by)
    rows = Enum.map(metrics, &metric_to_csv_row/1)
    format_csv_output(headers, rows)
  end

  # Get CSV headers for metrics based on grouping
  defp get_metrics_csv_headers("campaign") do
    ["Campaign" | get_base_metrics_headers()]
  end

  defp get_metrics_csv_headers("provider") do
    ["Provider" | get_base_metrics_headers()]
  end

  defp get_metrics_csv_headers(_) do
    ["Date" | get_base_metrics_headers()]
  end

  # Base metrics headers
  defp get_base_metrics_headers do
    [
      "Total Sent",
      "Delivered",
      "Bounced",
      "Opened",
      "Clicked",
      "Delivery Rate",
      "Open Rate",
      "Click Rate"
    ]
  end

  # Convert metric to CSV row
  defp metric_to_csv_row(metric) do
    [
      metric[:label] || metric[:date] || "",
      metric[:total_sent] || 0,
      metric[:delivered] || 0,
      metric[:bounced] || 0,
      metric[:opened] || 0,
      metric[:clicked] || 0,
      "#{metric[:delivery_rate] || 0}%",
      "#{metric[:open_rate] || 0}%",
      "#{metric[:click_rate] || 0}%"
    ]
  end

  # Generate CSV content for email details
  defp generate_email_details_csv(log, events) do
    email_section = build_email_details_section(log)
    events_section = build_events_section(events)
    combine_csv_sections(email_section, events_section)
  end

  # Build email details section
  defp build_email_details_section(log) do
    headers = ["Field", "Value"]
    rows = get_email_detail_rows(log)
    [headers | rows]
  end

  # Get email detail rows
  defp get_email_detail_rows(log) do
    [
      ["ID", log.id],
      ["Message ID", log.message_id || ""],
      ["To", log.to || ""],
      ["From", log.from || ""],
      ["Subject", escape_csv_field(log.subject || "")],
      ["Status", log.status || ""],
      ["Provider", log.provider || ""],
      ["Sent At", format_datetime_for_csv(log.sent_at)],
      ["Delivered At", format_datetime_for_csv(log.delivered_at)],
      ["Campaign", log.campaign_id || ""],
      ["Template", log.template_name || ""],
      ["Size (bytes)", log.size_bytes || ""],
      ["Retry Count", log.retry_count || 0]
    ]
  end

  # Build events section
  defp build_events_section([]), do: []

  defp build_events_section(events) do
    headers = ["Event Type", "Occurred At", "Details"]
    rows = Enum.map(events, &event_to_csv_row/1)
    [[], ["EVENTS"], headers | rows]
  end

  # Convert event to CSV row
  defp event_to_csv_row(event) do
    [
      event.event_type || "",
      format_datetime_for_csv(event.occurred_at),
      escape_csv_field(event.event_data || "")
    ]
  end

  # Combine CSV sections
  defp combine_csv_sections(email_section, events_section) do
    (email_section ++ events_section)
    |> Enum.map_join("\n", fn row ->
      Enum.map_join(row, ",", &to_string/1)
    end)
  end

  # Format CSV output from headers and rows
  defp format_csv_output(headers, rows) do
    [headers | rows]
    |> Enum.map_join("\n", fn row ->
      Enum.map_join(row, ",", &to_string/1)
    end)
  end

  # Format datetime for CSV export
  defp format_datetime_for_csv(nil), do: ""

  defp format_datetime_for_csv(datetime) do
    DateTime.to_iso8601(datetime)
  end

  # Escape CSV field value
  defp escape_csv_field(nil), do: ""

  defp escape_csv_field(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"#{String.replace(value, "\"", "\"\"")}\""
    else
      value
    end
  end

  defp escape_csv_field(value), do: to_string(value)

  # Extract message tag from message_tags map
  defp get_message_tag(message_tags) when is_map(message_tags) do
    Map.get(message_tags, "email_type")
  end

  defp get_message_tag(_), do: nil
end
