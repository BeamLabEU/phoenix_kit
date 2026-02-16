defmodule Mix.Tasks.PhoenixKit.Email.Export do
  @shortdoc "Export email tracking data to CSV or JSON"

  @moduledoc """
  Mix task to export email tracking data to various formats.

  ## Usage

      # Export all logs to CSV
      mix phoenix_kit.email.export --format csv

      # Export specific campaign to JSON
      mix phoenix_kit.email.export --format json --campaign newsletter

      # Export logs from date range
      mix phoenix_kit.email.export --from 2025-01-01 --to 2025-01-31

      # Export with custom filters
      mix phoenix_kit.email.export --status delivered --tag authentication --provider aws_ses

  ## Options

      --format FORMAT       Export format: csv, json (default: csv)
      --output FILE         Output file path (default: stdout)
      --from DATE           Start date (YYYY-MM-DD)
      --to DATE             End date (YYYY-MM-DD)
      --campaign ID         Filter by campaign ID
      --status STATUS       Filter by status (sent, delivered, bounced, etc.)
      --tag TAG             Filter by message tag/type (authentication, marketing, etc.)
      --provider PROVIDER   Filter by email provider (aws_ses, smtp, local, etc.)
      --limit NUMBER        Limit number of records (default: no limit)
      --include-events      Include email events (opens, clicks) in export

  ## Output Formats

  ### CSV Format
  Exports logs with columns: id, message_id, to, from, subject, status, sent_at, delivered_at, provider, campaign_id

  ### JSON Format  
  Exports complete log objects with all fields and optional events array

  ## Examples

      # Basic CSV export
      mix phoenix_kit.email.export --format csv > email_logs.csv

      # Campaign analysis with events
      mix phoenix_kit.email.export --campaign welcome-series --include-events --format json > campaign_analysis.json

      # Recent bounced emails for investigation
      mix phoenix_kit.email.export --status bounced --from $(date -d '7 days ago' '+%Y-%m-%d') --format csv > recent_bounces.csv

      # Authentication emails analysis
      mix phoenix_kit.email.export --tag authentication --from 2025-01-01 --include-events > auth_emails.csv

      # Provider performance comparison
      mix phoenix_kit.email.export --provider aws_ses --from 2025-01-01 --include-events > ses_performance.csv
  """

  use Mix.Task
  alias PhoenixKit.Modules.Emails

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {options, _remaining} = parse_options(args)

    unless Emails.enabled?() do
      Mix.shell().error("Email is not enabled.")
      exit({:shutdown, 1})
    end

    # Build filters from options
    filters = build_filters(options)

    # Get data
    logs = fetch_logs(filters, options)

    # Export in requested format
    case options[:format] do
      "json" -> export_json(logs, options)
      _ -> export_csv(logs, options)
    end

    log_export_summary(logs, options)
  end

  defp parse_options(args) do
    {options, remaining, _errors} =
      OptionParser.parse(args,
        strict: [
          format: :string,
          output: :string,
          from: :string,
          to: :string,
          campaign: :string,
          status: :string,
          tag: :string,
          provider: :string,
          limit: :integer,
          include_events: :boolean
        ]
      )

    # Set defaults
    options =
      options
      |> Keyword.put_new(:format, "csv")
      |> Keyword.put_new(:include_events, false)

    {options, remaining}
  end

  defp build_filters(options) do
    filters = %{}

    filters =
      if options[:from] do
        Map.put(filters, :sent_after, Date.from_iso8601!(options[:from]))
      else
        filters
      end

    filters =
      if options[:to] do
        Map.put(filters, :sent_before, Date.from_iso8601!(options[:to]))
      else
        filters
      end

    filters =
      if options[:campaign] do
        Map.put(filters, :campaign_id, options[:campaign])
      else
        filters
      end

    filters =
      if options[:status] do
        Map.put(filters, :status, options[:status])
      else
        filters
      end

    filters =
      if options[:tag] do
        Map.put(filters, :message_tag, options[:tag])
      else
        filters
      end

    filters =
      if options[:provider] do
        Map.put(filters, :provider, options[:provider])
      else
        filters
      end

    filters =
      if options[:limit] do
        Map.put(filters, :limit, options[:limit])
      else
        filters
      end

    filters
  end

  defp fetch_logs(filters, options) do
    logs = Emails.list_logs(filters)

    if options[:include_events] do
      # Load events for each log
      Enum.map(logs, fn log ->
        events = Emails.list_events_for_log(log.uuid)
        Map.put(log, :events, events)
      end)
    else
      logs
    end
  end

  defp export_csv(logs, options) do
    output_stream = get_output_stream(options[:output])

    # CSV Header
    header = build_csv_header(options)
    IO.puts(output_stream, header)

    # CSV Rows
    Enum.each(logs, fn log ->
      row = build_csv_row(log, options)
      IO.puts(output_stream, row)
    end)

    if options[:output] do
      File.close(output_stream)
    end
  end

  defp export_json(logs, options) do
    json_data = %{
      exported_at: DateTime.utc_now(),
      total_records: length(logs),
      filters: build_filters(options),
      logs: logs
    }

    json_output = Jason.encode!(json_data, pretty: true)

    if options[:output] do
      File.write!(options[:output], json_output)
    else
      Mix.shell().info(json_output)
    end
  end

  defp get_output_stream(nil), do: :stdio

  defp get_output_stream(file_path) do
    {:ok, file} = File.open(file_path, [:write])
    file
  end

  defp build_csv_header(options) do
    base_headers = [
      "id",
      "message_id",
      "to",
      "from",
      "subject",
      "status",
      "sent_at",
      "delivered_at",
      "provider",
      "campaign_id",
      "template_name",
      "size_bytes",
      "retry_count"
    ]

    if options[:include_events] do
      base_headers ++ ["events_count", "last_opened", "total_clicks"]
    else
      base_headers
    end
    |> Enum.join(",")
  end

  defp build_csv_row(log, options) do
    base_values = [
      log.uuid,
      escape_csv(log.message_id),
      escape_csv(log.to),
      escape_csv(log.from),
      escape_csv(log.subject),
      escape_csv(log.status),
      format_datetime(log.sent_at),
      format_datetime(log.delivered_at),
      escape_csv(log.provider),
      escape_csv(log.campaign_id),
      escape_csv(log.template_name),
      log.size_bytes || 0,
      log.retry_count || 0
    ]

    values =
      if options[:include_events] && Map.has_key?(log, :events) do
        events = log.events || []
        opens = Enum.filter(events, &(&1.event_type == "open"))
        clicks = Enum.filter(events, &(&1.event_type == "click"))

        last_opened =
          opens
          |> Enum.map(& &1.occurred_at)
          |> Enum.max(DateTime, fn -> nil end)

        base_values ++
          [
            length(events),
            format_datetime(last_opened),
            length(clicks)
          ]
      else
        base_values
      end

    values
    |> Enum.map_join(",", &to_string/1)
  end

  defp escape_csv(nil), do: ""

  defp escape_csv(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"#{String.replace(value, "\"", "\"\"")}\""
    else
      value
    end
  end

  defp escape_csv(value), do: to_string(value)

  defp format_datetime(nil), do: ""

  defp format_datetime(datetime) do
    DateTime.to_iso8601(datetime)
  end

  defp log_export_summary(logs, options) do
    count = length(logs)
    format = options[:format] || "csv"

    Mix.shell().error("✅ Exported #{count} emails to #{format} format")

    if options[:output] do
      Mix.shell().error("📄 Output saved to: #{options[:output]}")
    end

    # Basic stats summary
    if count > 0 do
      status_counts =
        logs
        |> Enum.group_by(& &1.status)
        |> Enum.map(fn {status, logs} -> {status, length(logs)} end)
        |> Enum.sort_by(fn {_status, count} -> count end, :desc)

      Mix.shell().error("📊 Status breakdown:")

      for {status, status_count} <- status_counts do
        percentage = Float.round(status_count / count * 100, 1)

        Mix.shell().error("  #{String.pad_trailing(status, 12)} #{status_count} (#{percentage}%)")
      end
    end
  end
end
