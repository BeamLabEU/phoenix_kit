defmodule Mix.Tasks.PhoenixKit.Email.DebugSqs do
  @shortdoc "Debug SQS queue messages and analyze message ID matching"

  @moduledoc """
  Mix task to debug SQS queue messages and analyze message ID matching issues.

  This task helps diagnose problems with email status updates by:
  - Retrieving all messages from the SQS queue
  - Analyzing message IDs from AWS SES events
  - Comparing with existing EmailLog records in the database
  - Identifying mismatches and providing recommendations

  ## Usage

      # Basic debug - analyze all messages in queue
      mix phoenix_kit.email.debug_sqs

      # Retrieve and analyze specific number of messages
      mix phoenix_kit.email.debug_sqs --max-messages 20

      # Include DLQ analysis
      mix phoenix_kit.email.debug_sqs --include-dlq

      # Process and delete messages after analysis
      mix phoenix_kit.email.debug_sqs --process --delete

      # Verbose output with full message details
      mix phoenix_kit.email.debug_sqs --verbose

  ## Options

      --max-messages N      Maximum number of messages to retrieve (default: 50)
      --include-dlq        Also analyze Dead Letter Queue
      --process            Process messages through SQSProcessor
      --delete             Delete messages after processing (requires --process)
      --verbose            Show detailed message content
      --message-id ID      Focus on specific message ID

  ## Output

  The task provides detailed analysis including:
  - Total messages found in queue
  - Message ID format analysis
  - EmailLog matching statistics
  - Specific mismatch details
  - Recommendations for fixing issues

  ## Examples

      # Quick analysis
      mix phoenix_kit.email.debug_sqs

      # Full analysis with DLQ
      mix phoenix_kit.email.debug_sqs --include-dlq --verbose

      # Process and clean up queue
      mix phoenix_kit.email.debug_sqs --process --delete --max-messages 10
  """

  use Mix.Task
  require Logger

  alias PhoenixKit.Emails
  alias PhoenixKit.Emails.SQSProcessor

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {options, _remaining} = parse_options(args)

    unless Emails.enabled?() do
      Mix.shell().error("Email system is not enabled.")
      exit({:shutdown, 1})
    end

    Mix.shell().info(IO.ANSI.cyan() <> "\n🔍 SQS Queue Debug Analysis" <> IO.ANSI.reset())
    Mix.shell().info(String.duplicate("=", 50))

    sqs_config = Emails.get_sqs_config()

    unless sqs_config.queue_url do
      Mix.shell().error("SQS queue URL is not configured.")
      exit({:shutdown, 1})
    end

    analyze_sqs_queue(sqs_config, options)

    if options[:include_dlq] do
      analyze_dlq_queue(options)
    end
  end

  defp parse_options(args) do
    {options, remaining, _errors} =
      OptionParser.parse(args,
        strict: [
          max_messages: :integer,
          include_dlq: :boolean,
          process: :boolean,
          delete: :boolean,
          verbose: :boolean,
          message_id: :string
        ]
      )

    # Set defaults
    options =
      options
      |> Keyword.put_new(:max_messages, 50)
      |> Keyword.put_new(:include_dlq, false)
      |> Keyword.put_new(:process, false)
      |> Keyword.put_new(:delete, false)
      |> Keyword.put_new(:verbose, false)

    {options, remaining}
  end

  defp analyze_sqs_queue(sqs_config, options) do
    Mix.shell().info("📥 Analyzing main SQS queue:")
    Mix.shell().info("   Queue URL: #{sqs_config.queue_url}")
    Mix.shell().info("   Max messages: #{options[:max_messages]}")
    Mix.shell().info("")

    messages = retrieve_messages(sqs_config.queue_url, options[:max_messages])

    if Enum.empty?(messages) do
      Mix.shell().info("✅ No messages found in the main queue")
    else
      Mix.shell().info("📨 Found #{length(messages)} messages")

      analysis = analyze_messages(messages, options)
      display_analysis(analysis, options)

      if options[:process] do
        process_messages(messages, options)
      end
    end
  end

  defp analyze_dlq_queue(options) do
    dlq_url = PhoenixKit.Settings.get_setting("aws_sqs_dlq_url")

    if dlq_url do
      Mix.shell().info("\n💀 Analyzing Dead Letter Queue:")
      Mix.shell().info("   DLQ URL: #{dlq_url}")

      dlq_messages = retrieve_messages(dlq_url, options[:max_messages])

      if Enum.empty?(dlq_messages) do
        Mix.shell().info("✅ No messages found in the DLQ")
      else
        Mix.shell().info("📨 Found #{length(dlq_messages)} messages in DLQ")
        dlq_analysis = analyze_messages(dlq_messages, options)
        display_analysis(dlq_analysis, options, "DLQ")
      end
    else
      Mix.shell().info("\n💀 DLQ URL not configured, skipping DLQ analysis")
    end
  end

  defp retrieve_messages(queue_url, max_messages) do
    Mix.shell().info("🔄 Retrieving messages from queue...")

    # Retrieve messages in batches to get up to max_messages
    retrieve_messages_recursive(queue_url, max_messages, [])
  end

  defp retrieve_messages_recursive(_queue_url, remaining, acc) when remaining <= 0 do
    acc
  end

  defp retrieve_messages_recursive(queue_url, remaining, acc) do
    # AWS SQS max is 10 per request
    batch_size = min(remaining, 10)

    request =
      ExAws.SQS.receive_message(queue_url,
        max_number_of_messages: batch_size,
        # Short polling for debug
        wait_time_seconds: 1,
        visibility_timeout: 30,
        message_attribute_names: [:all],
        attribute_names: [:all]
      )

    case ExAws.request(request) do
      {:ok, %{body: %{messages: messages}}} when is_list(messages) and messages != [] ->
        new_acc = acc ++ messages
        new_remaining = remaining - length(messages)

        Mix.shell().info("   Retrieved #{length(messages)} messages (#{length(new_acc)} total)")

        # Continue retrieving if we haven't reached the limit and there might be more
        if new_remaining > 0 do
          retrieve_messages_recursive(queue_url, new_remaining, new_acc)
        else
          new_acc
        end

      {:ok, _} ->
        # No more messages
        acc

      {:error, error} ->
        Mix.shell().error("❌ Error retrieving messages: #{inspect(error)}")
        acc
    end
  end

  defp analyze_messages(messages, options) do
    Mix.shell().info("🔍 Analyzing message content...")

    results =
      Enum.map(messages, fn message ->
        analyze_single_message(message, options)
      end)

    compile_analysis(results)
  end

  defp analyze_single_message(message, options) do
    message_id = message["MessageId"]

    # Parse the SNS message
    case SQSProcessor.parse_sns_message(message) do
      {:ok, event_data} ->
        aws_message_id = get_in(event_data, ["mail", "messageId"])
        event_type = event_data["eventType"]
        timestamp = get_in(event_data, ["mail", "timestamp"])

        # Check if we can find matching email log
        log_match =
          if is_binary(aws_message_id),
            do: check_email_log_match(aws_message_id),
            else: :invalid_message_id

        if options[:verbose] do
          display_verbose_message(message, event_data, log_match)
        end

        %{
          sqs_message_id: message_id,
          aws_message_id: aws_message_id,
          event_type: event_type,
          timestamp: timestamp,
          log_match: log_match,
          parsed: true,
          error: nil
        }

      {:error, reason} ->
        if options[:verbose] do
          Mix.shell().info("❌ Failed to parse message #{message_id}: #{inspect(reason)}")
        end

        %{
          sqs_message_id: message_id,
          aws_message_id: nil,
          event_type: nil,
          timestamp: nil,
          log_match: :invalid_message_id,
          parsed: false,
          error: reason
        }
    end
  end

  defp check_email_log_match(aws_message_id) when is_binary(aws_message_id) do
    # Try to find by AWS message ID
    case Emails.get_log_by_message_id(aws_message_id) do
      {:ok, log} ->
        {:found_by_aws_id, log}

      {:error, :not_found} ->
        # Try to find by internal message ID pattern (if AWS ID was stored as internal)
        case Emails.Log.find_by_aws_message_id(aws_message_id) do
          {:ok, log} ->
            {:found_by_aws_field, log}

          {:error, :not_found} ->
            # Try partial matches or similar IDs
            find_similar_logs(aws_message_id)
        end
    end
  end

  defp check_email_log_match(_), do: :invalid_message_id

  defp find_similar_logs(_aws_message_id) do
    # Look for logs created around the same time or with similar patterns
    # This is a simplified implementation
    :not_found
  end

  defp display_verbose_message(message, event_data, log_match) do
    Mix.shell().info("\n📋 Message Details:")
    Mix.shell().info("   SQS Message ID: #{message["MessageId"]}")
    Mix.shell().info("   AWS Message ID: #{get_in(event_data, ["mail", "messageId"])}")
    Mix.shell().info("   Event Type: #{event_data["eventType"]}")
    Mix.shell().info("   Timestamp: #{get_in(event_data, ["mail", "timestamp"])}")

    case log_match do
      {:found_by_aws_id, log} ->
        Mix.shell().info("   ✅ Match: Found by AWS ID in database (ID: #{log.id})")

      {:found_by_aws_field, log} ->
        Mix.shell().info("   ✅ Match: Found by AWS field (ID: #{log.id})")

      :not_found ->
        Mix.shell().info("   ❌ Match: No matching email log found")

      :invalid_message_id ->
        Mix.shell().info("   ❌ Match: Invalid message ID format")
    end
  end

  defp compile_analysis(results) do
    total_messages = length(results)
    parsed_messages = Enum.count(results, & &1.parsed)
    parse_errors = total_messages - parsed_messages

    match_stats =
      Enum.frequencies_by(results, fn result ->
        case result.log_match do
          {:found_by_aws_id, _} -> :found_by_aws_id
          {:found_by_aws_field, _} -> :found_by_aws_field
          :not_found -> :not_found
          :invalid_message_id -> :invalid_message_id
        end
      end)

    event_types =
      results
      |> Enum.filter(& &1.parsed)
      |> Enum.frequencies_by(& &1.event_type)

    aws_message_ids =
      results
      |> Enum.filter(& &1.aws_message_id)
      |> Enum.map(& &1.aws_message_id)

    %{
      total_messages: total_messages,
      parsed_messages: parsed_messages,
      parse_errors: parse_errors,
      match_stats: match_stats,
      event_types: event_types,
      aws_message_ids: aws_message_ids,
      results: results
    }
  end

  defp display_analysis(analysis, options, prefix \\ "Main Queue") do
    Mix.shell().info("\n📊 #{prefix} Analysis Results:")
    Mix.shell().info("   Total messages: #{analysis.total_messages}")
    Mix.shell().info("   Successfully parsed: #{analysis.parsed_messages}")
    Mix.shell().info("   Parse errors: #{analysis.parse_errors}")

    if analysis.total_messages > 0 do
      Mix.shell().info("\n🎯 Match Statistics:")

      Enum.each(analysis.match_stats, fn {match_type, count} ->
        percentage = Float.round(count / analysis.total_messages * 100, 1)
        icon = match_icon(match_type)
        description = match_description(match_type)
        Mix.shell().info("   #{icon} #{description}: #{count} (#{percentage}%)")
      end)

      if not Enum.empty?(analysis.event_types) do
        Mix.shell().info("\n📧 Event Types:")

        Enum.each(analysis.event_types, fn {event_type, count} ->
          Mix.shell().info("   📨 #{event_type || "unknown"}: #{count}")
        end)
      end

      # Show sample AWS message IDs for investigation
      if not Enum.empty?(analysis.aws_message_ids) and options[:verbose] do
        Mix.shell().info("\n🔍 Sample AWS Message IDs:")

        analysis.aws_message_ids
        |> Enum.take(5)
        |> Enum.each(fn aws_id ->
          Mix.shell().info("   • #{aws_id}")
        end)
      end

      display_recommendations(analysis)
    end
  end

  defp match_icon(:found_by_aws_id), do: "✅"
  defp match_icon(:found_by_aws_field), do: "✅"
  defp match_icon(:not_found), do: "❌"
  defp match_icon(:invalid_message_id), do: "🔧"

  defp match_description(:found_by_aws_id), do: "Found by AWS Message ID"
  defp match_description(:found_by_aws_field), do: "Found by AWS field lookup"
  defp match_description(:not_found), do: "No matching email log"
  defp match_description(:invalid_message_id), do: "Invalid message ID format"

  defp display_recommendations(analysis) do
    Mix.shell().info("\n💡 Recommendations:")

    not_found_count = Map.get(analysis.match_stats, :not_found, 0)
    total_parsed = analysis.parsed_messages

    cond do
      not_found_count == 0 and total_parsed > 0 ->
        Mix.shell().info("   ✅ All messages have matching emails. System is working correctly.")

      not_found_count > 0 and total_parsed > 0 ->
        percentage = Float.round(not_found_count / total_parsed * 100, 1)
        Mix.shell().info("   ⚠️  #{percentage}% of events cannot find matching emails.")
        Mix.shell().info("   🔧 Check if message_id is being updated after email send.")

        Mix.shell().info(
          "   🔧 Verify AWS SES message ID is stored in email_log.message_id field."
        )

        Mix.shell().info(
          "   🔧 Consider running: mix phoenix_kit.email.debug_sqs --process --delete"
        )

      analysis.parse_errors > 0 ->
        Mix.shell().info("   🔧 Some messages failed to parse. Check SQS message format.")
        Mix.shell().info("   🔧 Verify SNS topic is correctly configured.")

      true ->
        Mix.shell().info("   ℹ️  No specific recommendations at this time.")
    end
  end

  defp process_messages(messages, options) do
    Mix.shell().info("\n🔄 Processing messages through SQSProcessor...")

    results =
      Enum.map(messages, fn message ->
        case SQSProcessor.parse_sns_message(message) do
          {:ok, event_data} ->
            case SQSProcessor.process_email_event(event_data) do
              {:ok, result} ->
                {:ok, result}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end)

    successful =
      Enum.count(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    Mix.shell().info("   ✅ Successfully processed: #{successful}/#{length(messages)}")

    if options[:delete] do
      delete_processed_messages(messages, results, options)
    end
  end

  defp delete_processed_messages(messages, results, _options) do
    Mix.shell().info("\n🗑️  Deleting processed messages...")

    successful_messages =
      Enum.zip(messages, results)
      |> Enum.filter(fn {_message, result} ->
        case result do
          {:ok, _} -> true
          _ -> false
        end
      end)
      |> Enum.map(fn {message, _result} -> message end)

    if Enum.empty?(successful_messages) do
      Mix.shell().info("   ℹ️  No successfully processed messages to delete.")
    else
      sqs_config = Emails.get_sqs_config()

      deleted_count =
        Enum.count(successful_messages, fn message ->
          receipt_handle = message["ReceiptHandle"]

          case ExAws.SQS.delete_message(sqs_config.queue_url, receipt_handle)
               |> ExAws.request() do
            {:ok, _} ->
              true

            {:error, error} ->
              Mix.shell().error("   ❌ Failed to delete message: #{inspect(error)}")
              false
          end
        end)

      Mix.shell().info("   🗑️  Deleted #{deleted_count}/#{length(successful_messages)} messages")
    end
  end
end
