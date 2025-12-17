defmodule Mix.Tasks.PhoenixKit.SyncEmailStatus do
  @shortdoc "Sync email status by AWS SES message ID"

  @moduledoc """
  Mix task to manually sync email status by AWS SES message ID.

  This task searches for a specific email by message ID and synchronizes
  its delivery status by fetching events from AWS SQS queues.

  ## Usage

      # Sync status for specific message ID
      mix phoenix_kit.sync_email_status MESSAGE_ID

      # With verbose output
      mix phoenix_kit.sync_email_status MESSAGE_ID --verbose

  ## Examples

      # Sync email with AWS SES message ID
      mix phoenix_kit.sync_email_status "01000189971abc123-fed456-4e89-b012-defg345678hi"

      # With detailed logging
      mix phoenix_kit.sync_email_status "01000189971abc123-fed456-4e89-b012-defg345678hi" --verbose

  ## What this task does:

  1. **Find Email Log**: Searches for email log by message_id
  2. **Check SQS Queue**: Looks for events in main SQS queue
  3. **Check DLQ**: Looks for events in Dead Letter Queue
  4. **Process Events**: Updates email status based on found events
  5. **Report Results**: Shows summary of synchronization

  ## Output

  The task will show:
  - Email log found/not found status
  - Number of events found in SQS
  - Number of events found in DLQ
  - Processing results
  - Final email status

  ## Requirements

  - Email system must be enabled
  - AWS SES integration must be configured
  - SQS queue configuration must be set up
  """

  use Mix.Task

  alias PhoenixKit.Emails
  alias PhoenixKit.Emails.{Log, SQSProcessor}

  @impl Mix.Task
  def run(args) do
    {opts, args_list, _} =
      OptionParser.parse(args,
        strict: [verbose: :boolean, help: :boolean],
        aliases: [v: :verbose, h: :help]
      )

    case args_list do
      [] ->
        print_help()

      [message_id | _] ->
        if opts[:help] do
          print_help()
        else
          # Start the application
          Mix.Task.run("app.start")

          verbose = opts[:verbose] || false

          if verbose do
            IO.puts("🔍 Starting email status sync for message ID: #{message_id}")
          end

          case sync_email_status(message_id, verbose) do
            {:ok, result} ->
              print_success_result(result, verbose)

            {:error, reason} ->
              print_error(reason, verbose)
              System.halt(1)
          end
        end
    end
  end

  ## --- Private Functions ---

  defp sync_email_status(message_id, verbose) do
    # Check if tracking is enabled
    if Emails.enabled?() do
      if verbose, do: IO.puts("✅ Email system is enabled")

      # Step 1: Find existing email log
      {existing_log, log_status} = find_existing_log(message_id, verbose)

      # Step 2: Search for events in SQS and DLQ
      {sqs_events, dlq_events} = fetch_events_from_queues(message_id, verbose)

      total_events = length(sqs_events) + length(dlq_events)

      if verbose do
        IO.puts(
          "📊 Found #{length(sqs_events)} events in SQS, #{length(dlq_events)} events in DLQ"
        )
      end

      if total_events == 0 do
        {:ok,
         %{
           log_found: existing_log != nil,
           log_status: log_status,
           events_found: 0,
           events_processed: 0,
           message: "No events found for this message ID",
           final_status: existing_log && existing_log.status
         }}
      else
        # Step 3: Process all events
        process_results = process_events(sqs_events ++ dlq_events, verbose)

        # Step 4: Get final status
        final_log_status =
          case find_existing_log(message_id, false) do
            {log, _} when not is_nil(log) -> log.status
            _ -> nil
          end

        {:ok,
         %{
           log_found: existing_log != nil,
           log_status: log_status,
           events_found: total_events,
           events_processed: length(process_results[:successful]),
           failed_events: length(process_results[:failed]),
           message: "Synchronization completed",
           final_status: final_log_status,
           process_details: process_results
         }}
      end
    else
      {:error, "Email system is not enabled"}
    end
  end

  defp find_existing_log(message_id, verbose) do
    case Log.get_log_by_message_id(message_id) do
      %PhoenixKit.Emails.Log{} = log ->
        if verbose do
          IO.puts("📧 Found existing email log: ID=#{log.id}, Status=#{log.status}")
        end

        {log, log.status}

      nil ->
        if verbose, do: IO.puts("❌ No existing email log found")
        {nil, nil}
    end
  end

  defp fetch_events_from_queues(message_id, verbose) do
    if verbose, do: IO.puts("🔍 Searching for events in SQS queues...")

    sqs_events = Emails.fetch_sqs_events_for_message(message_id)
    dlq_events = Emails.fetch_dlq_events_for_message(message_id)

    {sqs_events, dlq_events}
  end

  defp process_events(events, verbose) do
    if verbose, do: IO.puts("⚡ Processing #{length(events)} events...")

    results = %{successful: [], failed: []}

    Enum.reduce(events, results, fn event, acc ->
      case SQSProcessor.process_email_event(event) do
        {:ok, result} ->
          if verbose do
            IO.puts("  ✅ Processed #{event["eventType"]} event successfully")
          end

          %{acc | successful: [result | acc.successful]}

        {:error, reason} ->
          if verbose do
            IO.puts("  ❌ Failed to process #{event["eventType"]} event: #{inspect(reason)}")
          end

          %{acc | failed: [{event, reason} | acc.failed]}
      end
    end)
  end

  defp print_success_result(result, verbose) do
    IO.puts("\n📊 Email Status Sync Results")
    IO.puts("════════════════════════════")

    IO.puts("📧 Message ID Status:")

    if result.log_found do
      IO.puts("   ✅ Email log found")
      IO.puts("   📍 Initial status: #{result.log_status || "unknown"}")
      IO.puts("   📍 Final status: #{result.final_status || "unknown"}")
    else
      IO.puts("   ❌ No email log found")
    end

    IO.puts("\n📈 Event Processing:")
    IO.puts("   🔍 Events found: #{result.events_found}")
    IO.puts("   ✅ Events processed: #{result.events_processed}")

    if result[:failed_events] && result.failed_events > 0 do
      IO.puts("   ❌ Failed events: #{result.failed_events}")
    end

    IO.puts("\n💬 Result: #{result.message}")

    if verbose && result[:process_details] do
      print_process_details(result.process_details)
    end

    IO.puts("\n✅ Synchronization completed successfully!")
  end

  defp print_process_details(details) do
    IO.puts("\n🔍 Processing Details:")

    if not Enum.empty?(details.successful) do
      IO.puts("   ✅ Successful events:")

      Enum.each(details.successful, fn result ->
        IO.puts("      • #{result[:type]} (Log ID: #{result[:log_id]})")
      end)
    end

    if not Enum.empty?(details.failed) do
      IO.puts("   ❌ Failed events:")

      Enum.each(details.failed, fn {event, reason} ->
        IO.puts("      • #{event["eventType"]}: #{inspect(reason)}")
      end)
    end
  end

  defp print_error(reason, verbose) do
    IO.puts("\n❌ Email Status Sync Failed")
    IO.puts("══════════════════════════")
    IO.puts("Error: #{reason}")

    if verbose do
      IO.puts("\n🔍 Troubleshooting:")
      IO.puts("• Check if email system is enabled")
      IO.puts("• Verify AWS SES and SQS configuration")
      IO.puts("• Ensure message ID is correct")
      IO.puts("• Check AWS credentials and permissions")
    end
  end

  defp print_help do
    IO.puts("""
    📧 PhoenixKit Email Status Sync

    USAGE:
        mix phoenix_kit.sync_email_status MESSAGE_ID [options]

    ARGUMENTS:
        MESSAGE_ID    AWS SES message ID to sync

    OPTIONS:
        --verbose, -v    Show detailed output
        --help, -h       Show this help

    EXAMPLES:
        mix phoenix_kit.sync_email_status "01000189971abc123-fed456-4e89-b012-defg345678hi"
        mix phoenix_kit.sync_email_status "01000189971abc123-fed456-4e89-b012-defg345678hi" --verbose

    DESCRIPTION:
        This task synchronizes email delivery status by fetching events from AWS SQS
        queues and updating the corresponding email log in the database.
    """)
  end
end
