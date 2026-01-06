defmodule Mix.Tasks.PhoenixKit.Email.ProcessDlq do
  @moduledoc """
  Process accumulated messages from AWS SQS Dead Letter Queue (DLQ).

  This task retrieves all messages from the DLQ, processes them through
  the SQS processor to update email statuses, and optionally deletes
  successfully processed messages.

  ## Usage

      mix phoenix_kit.email.process_dlq [--batch-size 10] [--delete-after] [--dry-run]

  ## Options

    * `--batch-size` - Number of messages to process in each batch (default: 10)
    * `--delete-after` - Delete successfully processed messages from DLQ (default: false)
    * `--dry-run` - Show what would be processed without making changes (default: false)

  ## Examples

      # Process all DLQ messages without deleting them
      mix phoenix_kit.email.process_dlq

      # Process in small batches and delete successful ones
      mix phoenix_kit.email.process_dlq --batch-size 5 --delete-after

      # See what would be processed (no changes)
      mix phoenix_kit.email.process_dlq --dry-run

  ## Requirements

  - Email system must be enabled
  - AWS credentials must be configured
  - DLQ URL must be set in settings
  """

  use Mix.Task

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQSProcessor
  alias PhoenixKit.Settings

  @shortdoc "Process accumulated DLQ messages"

  @impl Mix.Task
  def run(args) do
    # Start the application to ensure repo and settings are available
    Mix.Task.run("app.start")

    {options, [], []} =
      OptionParser.parse(args,
        strict: [
          batch_size: :integer,
          delete_after: :boolean,
          dry_run: :boolean
        ],
        aliases: [
          b: :batch_size,
          d: :delete_after,
          n: :dry_run
        ]
      )

    batch_size = Keyword.get(options, :batch_size, 10)
    delete_after = Keyword.get(options, :delete_after, false)
    dry_run = Keyword.get(options, :dry_run, false)

    if not Emails.enabled?() do
      Mix.shell().error("❌ Email system is not enabled")
      exit(:shutdown)
    end

    dlq_url = Settings.get_setting("aws_sqs_dlq_url")

    unless is_binary(dlq_url) and dlq_url != "" do
      Mix.shell().error("❌ DLQ URL not configured")
      exit(:shutdown)
    end

    Mix.shell().info("🔄 Processing DLQ messages...")
    Mix.shell().info("📋 Configuration:")
    Mix.shell().info("   • DLQ URL: #{dlq_url}")
    Mix.shell().info("   • Batch size: #{batch_size}")
    Mix.shell().info("   • Delete after: #{delete_after}")
    Mix.shell().info("   • Dry run: #{dry_run}")
    Mix.shell().info("")

    total_processed = 0
    total_successful = 0
    total_errors = 0

    {final_processed, final_successful, final_errors} =
      process_dlq_batches(
        dlq_url,
        batch_size,
        delete_after,
        dry_run,
        total_processed,
        total_successful,
        total_errors
      )

    Mix.shell().info("")
    Mix.shell().info("✅ DLQ processing completed!")
    Mix.shell().info("📊 Summary:")
    Mix.shell().info("   • Total messages processed: #{final_processed}")
    Mix.shell().info("   • Successful: #{final_successful}")
    Mix.shell().info("   • Errors: #{final_errors}")

    if dry_run do
      Mix.shell().info("ℹ️  This was a dry run - no changes were made")
    end
  end

  # Recursively process message batches from DLQ
  defp process_dlq_batches(
         dlq_url,
         batch_size,
         delete_after,
         dry_run,
         total_processed,
         total_successful,
         total_errors
       ) do
    messages =
      ExAws.SQS.receive_message(dlq_url,
        max_number_of_messages: batch_size,
        wait_time_seconds: 1
      )
      |> ExAws.request()
      |> case do
        {:ok, %{body: %{messages: messages}}} -> messages
        _ -> []
      end

    if Enum.empty?(messages) do
      Mix.shell().info("📦 No more messages in DLQ")
      {total_processed, total_successful, total_errors}
    else
      Mix.shell().info("📦 Processing batch of #{length(messages)} messages...")

      {batch_successful, batch_errors, processed_receipts} =
        process_message_batch(messages, dry_run)

      new_processed = total_processed + length(messages)
      new_successful = total_successful + batch_successful
      new_errors = total_errors + batch_errors

      Mix.shell().info("✅ Batch completed: #{batch_successful}/#{length(messages)} successful")

      # Delete successfully processed messages if required
      if delete_after and not dry_run and not Enum.empty?(processed_receipts) do
        delete_processed_messages(dlq_url, processed_receipts)
      end

      # Continue processing next batch
      process_dlq_batches(
        dlq_url,
        batch_size,
        delete_after,
        dry_run,
        new_processed,
        new_successful,
        new_errors
      )
    end
  rescue
    error ->
      Mix.shell().error("❌ Error processing DLQ batch: #{inspect(error)}")
      {total_processed, total_successful, total_errors + 1}
  end

  # Process one message batch
  defp process_message_batch(messages, dry_run) do
    results =
      Enum.map(messages, fn message ->
        if dry_run do
          case analyze_message(message) do
            {:ok, info} ->
              Mix.shell().info("   Would process: #{info.event_type} for #{info.message_id}")
              {:ok, message["ReceiptHandle"]}

            {:error, reason} ->
              Mix.shell().info("   Would skip: #{reason}")
              {:error, reason}
          end
        else
          process_single_message(message)
        end
      end)

    successful_results =
      Enum.filter(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    error_results =
      Enum.filter(results, fn
        {:error, _} -> true
        _ -> false
      end)

    processed_receipts = Enum.map(successful_results, fn {:ok, receipt} -> receipt end)

    {length(successful_results), length(error_results), processed_receipts}
  end

  # Analyze message without processing it (for dry-run)
  defp analyze_message(message) do
    case SQSProcessor.parse_sns_message(message) do
      {:ok, event_data} ->
        message_id = get_in(event_data, ["mail", "messageId"])
        event_type = event_data["eventType"]
        {:ok, %{message_id: message_id, event_type: event_type}}

      {:error, reason} ->
        {:error, "Invalid message format: #{reason}"}
    end
  end

  # Process single message
  defp process_single_message(message) do
    case SQSProcessor.parse_sns_message(message) do
      {:ok, event_data} ->
        message_id = get_in(event_data, ["mail", "messageId"])
        event_type = event_data["eventType"]

        case SQSProcessor.process_email_event(event_data) do
          {:ok, result} ->
            Mix.shell().info("   ✅ #{event_type} for #{message_id}: #{inspect(result)}")
            {:ok, message["ReceiptHandle"]}

          {:error, reason} ->
            Mix.shell().info("   ❌ Failed #{event_type} for #{message_id}: #{reason}")
            {:error, reason}
        end

      {:error, reason} ->
        Mix.shell().info("   ❌ Failed to parse message: #{reason}")
        {:error, reason}
    end
  end

  # Delete successfully processed messages from DLQ
  defp delete_processed_messages(dlq_url, receipt_handles) do
    Mix.shell().info("🗑️  Deleting #{length(receipt_handles)} processed messages from DLQ...")

    Enum.each(receipt_handles, fn receipt_handle ->
      try do
        ExAws.SQS.delete_message(dlq_url, receipt_handle)
        |> ExAws.request()
      rescue
        error ->
          Mix.shell().error("   ❌ Failed to delete message: #{inspect(error)}")
      end
    end)

    Mix.shell().info("   ✅ Deleted #{length(receipt_handles)} messages")
  end
end
