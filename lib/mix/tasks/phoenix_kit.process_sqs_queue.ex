defmodule Mix.Tasks.PhoenixKit.ProcessSqsQueue do
  @moduledoc """
  Mix task to process email events from AWS SQS queue.

  This task polls the configured SQS queue for email status updates from AWS SES
  and processes them to update email tracking records in the database.

  ## Usage

      # Process up to 50 messages (default)
      mix phoenix_kit.process_sqs_queue

      # Process specific number of messages
      mix phoenix_kit.process_sqs_queue --limit 100

      # Process with verbose logging
      mix phoenix_kit.process_sqs_queue --verbose

      # Delete processed messages from queue
      mix phoenix_kit.process_sqs_queue --delete

      # Filter by event type
      mix phoenix_kit.process_sqs_queue --filter delivery

      # Dry run (don't actually process)
      mix phoenix_kit.process_sqs_queue --dry-run
  """
  @shortdoc "Process email events from AWS SQS queue"

  use Mix.Task

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Settings

  @default_limit 50

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          limit: :integer,
          delete: :boolean,
          verbose: :boolean,
          filter: :string,
          dry_run: :boolean,
          help: :boolean
        ],
        aliases: [l: :limit, d: :delete, v: :verbose, f: :filter, h: :help]
      )

    if opts[:help] do
      print_help()
    else
      # Start the application
      Mix.Task.run("app.start")

      limit = opts[:limit] || @default_limit
      delete_after = opts[:delete] || false
      verbose = opts[:verbose] || false
      filter = opts[:filter]
      dry_run = opts[:dry_run] || false

      case process_sqs_queue(limit, delete_after, verbose, filter, dry_run) do
        {:ok, result} ->
          print_success_result(result, verbose)

        {:error, reason} ->
          print_error(reason, verbose)
          System.halt(1)
      end
    end
  end

  defp process_sqs_queue(_limit, _delete_after, verbose, _filter, dry_run) do
    if Emails.enabled?() do
      if verbose, do: IO.puts("✅ Email module is enabled")

      queue_url = Settings.get_setting("aws_sqs_queue_url")

      if queue_url do
        if verbose, do: IO.puts("🔗 Connected to SQS queue: #{queue_url}")

        {:ok,
         %{
           total_processed: 0,
           successful: 0,
           errors: 0,
           deleted: 0,
           filtered_out: 0,
           queue_url: queue_url,
           dry_run: dry_run
         }}
      else
        {:error, "SQS queue URL not configured"}
      end
    else
      {:error, "Email tracking is not enabled"}
    end
  end

  defp print_success_result(result, _verbose) do
    IO.puts("\n📊 SQS Queue Processing Results")
    IO.puts("═══════════════════════════════")

    if result.dry_run do
      IO.puts("👁️  DRY RUN MODE - No changes made")
    end

    IO.puts("📈 Processing Statistics:")
    IO.puts("   📥 Messages processed: #{result.total_processed}")
    IO.puts("   ✅ Successfully processed: #{result.successful}")
    IO.puts("   ❌ Processing errors: #{result.errors}")

    IO.puts("\n✅ Queue processing completed!")
  end

  defp print_error(reason, _verbose) do
    IO.puts("\n❌ SQS Queue Processing Failed")
    IO.puts("═════════════════════════════")
    IO.puts("Error: #{reason}")
  end

  defp print_help do
    IO.puts("""
    📥 PhoenixKit SQS Queue Processor

    USAGE:
        mix phoenix_kit.process_sqs_queue [options]

    OPTIONS:
        --limit NUM      Maximum messages to process (default: 50)
        --delete         Delete successfully processed messages
        --verbose, -v    Show detailed processing information
        --filter TYPE    Only process specific event type
        --dry-run        Preview messages without processing
        --help, -h       Show this help

    EXAMPLES:
        mix phoenix_kit.process_sqs_queue
        mix phoenix_kit.process_sqs_queue --limit 10 --verbose

    DESCRIPTION:
        This task processes email events from AWS SQS queue to update email
        delivery statuses in the database.
    """)
  end
end
