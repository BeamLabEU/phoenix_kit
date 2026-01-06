defmodule Mix.Tasks.PhoenixKit.ProcessSqs do
  @moduledoc """
  Processes pending messages from AWS SQS queue for email events.

  ## Usage

      # Process all messages in queue
      mix phoenix_kit.process_sqs

      # Process specific number of messages
      mix phoenix_kit.process_sqs --count 10

      # Show status without processing
      mix phoenix_kit.process_sqs --status

  ## Options

    * `--count` - Number of messages to process (default: all)
    * `--status` - Show queue status without processing
    * `--help` - Show this help

  ## Examples

      # Process all pending messages
      mix phoenix_kit.process_sqs

      # Process up to 10 messages
      mix phoenix_kit.process_sqs --count 10

      # Check queue status
      mix phoenix_kit.process_sqs --status

  """

  use Mix.Task

  alias PhoenixKit.Modules.Emails.SQSProcessor
  alias PhoenixKit.Settings

  @shortdoc "Process AWS SQS email event messages"

  @switches [
    count: :integer,
    status: :boolean,
    help: :boolean
  ]

  @aliases [
    c: :count,
    s: :status,
    h: :help
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        show_help()

      opts[:status] ->
        show_status()

      true ->
        count = opts[:count]
        process_messages(count)
    end
  end

  defp show_help do
    Mix.shell().info(@moduledoc)
  end

  defp show_status do
    Mix.Task.run("app.start")

    queue_url = get_queue_url()

    if queue_url do
      Mix.shell().info("\n=== SQS Queue Status ===\n")

      case get_queue_attributes(queue_url) do
        {:ok, attrs} ->
          available = attrs["ApproximateNumberOfMessages"] || "0"
          in_flight = attrs["ApproximateNumberOfMessagesNotVisible"] || "0"

          Mix.shell().info("Queue URL: #{queue_url}")
          Mix.shell().info("Available messages: #{available}")
          Mix.shell().info("In-flight messages: #{in_flight}")
          Mix.shell().info("")

        {:error, reason} ->
          Mix.shell().error("Failed to get queue status: #{inspect(reason)}")
      end
    else
      Mix.shell().error("AWS SQS configuration not found in Settings")
    end
  end

  defp process_messages(count) do
    Mix.Task.run("app.start")

    queue_url = get_queue_url()

    if queue_url do
      Mix.shell().info("\n=== Processing SQS Messages ===\n")

      max_count = count || 999_999
      process_loop(queue_url, 0, max_count)
    else
      Mix.shell().error("AWS SQS configuration not found in Settings")
    end
  end

  defp process_loop(_queue_url, processed, max_count) when processed >= max_count do
    Mix.shell().info("\n✅ Processed #{processed} messages (limit reached)")
  end

  defp process_loop(queue_url, processed, max_count) do
    case receive_message(queue_url) do
      {:ok, nil} ->
        if processed == 0 do
          Mix.shell().info("No messages in queue")
        else
          Mix.shell().info("\n✅ Processed #{processed} messages total")
        end

      {:ok, message} ->
        process_single_message(message, queue_url)
        process_loop(queue_url, processed + 1, max_count)

      {:error, reason} ->
        Mix.shell().error("Failed to receive message: #{inspect(reason)}")
    end
  end

  defp process_single_message(message, queue_url) do
    body = message["Body"]
    receipt_handle = message["ReceiptHandle"]

    # Parse SNS message
    case Jason.decode(body) do
      {:ok, sns_body} ->
        sns_message = Jason.decode!(sns_body["Message"])
        event_type = sns_message["eventType"]
        message_id = get_in(sns_message, ["mail", "messageId"])

        Mix.shell().info("Processing: #{event_type} for #{message_id}")

        # Process event
        with {:ok, sns_data} <- SQSProcessor.parse_sns_message(%{"Body" => body}),
             {:ok, result} <- SQSProcessor.process_email_event(sns_data) do
          Mix.shell().info("  ✅ #{inspect(result)}")

          # Delete message from queue
          delete_message(queue_url, receipt_handle)
        else
          {:error, reason} ->
            Mix.shell().error("  ❌ Failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.shell().error("  ❌ Failed to parse: #{inspect(reason)}")
    end
  end

  defp get_queue_url do
    region = Settings.get_setting("aws_region", "eu-north-1")
    account_id = Settings.get_setting("aws_account_id")
    queue_name = Settings.get_setting("aws_sqs_queue_name", "phoenixkit-email-queue")

    if account_id do
      "https://sqs.#{region}.amazonaws.com/#{account_id}/#{queue_name}"
    else
      nil
    end
  end

  defp get_queue_attributes(queue_url) do
    region = Settings.get_setting("aws_region", "eu-north-1")

    case System.cmd(
           "aws",
           [
             "sqs",
             "get-queue-attributes",
             "--queue-url",
             queue_url,
             "--attribute-names",
             "ApproximateNumberOfMessages",
             "ApproximateNumberOfMessagesNotVisible",
             "--region",
             region
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"Attributes" => attrs}} -> {:ok, attrs}
          {:error, reason} -> {:error, reason}
        end

      {output, _code} ->
        {:error, output}
    end
  end

  defp receive_message(queue_url) do
    region = Settings.get_setting("aws_region", "eu-north-1")

    case System.cmd(
           "aws",
           [
             "sqs",
             "receive-message",
             "--queue-url",
             queue_url,
             "--max-number-of-messages",
             "1",
             "--region",
             region
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"Messages" => [message | _]}} -> {:ok, message}
          {:ok, _} -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end

      {output, _code} ->
        {:error, output}
    end
  end

  defp delete_message(queue_url, receipt_handle) do
    region = Settings.get_setting("aws_region", "eu-north-1")

    System.cmd(
      "aws",
      [
        "sqs",
        "delete-message",
        "--queue-url",
        queue_url,
        "--receipt-handle",
        receipt_handle,
        "--region",
        region
      ],
      stderr_to_stdout: true
    )
  end
end
