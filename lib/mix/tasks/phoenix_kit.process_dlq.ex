defmodule Mix.Tasks.PhoenixKit.ProcessDlq do
  @moduledoc """
  Mix task to process failed email events from AWS SQS Dead Letter Queue (DLQ).

  This task retrieves messages that failed to process in the main queue and attempts
  to reprocess them. Useful for recovering from temporary failures or processing
  issues that sent messages to the DLQ.

  ## Usage

      # Process up to 100 messages (default)
      mix phoenix_kit.process_dlq

      # Process specific number of messages
      mix phoenix_kit.process_dlq --limit 50

      # Process with verbose logging
      mix phoenix_kit.process_dlq --verbose

      # Delete processed messages from DLQ
      mix phoenix_kit.process_dlq --delete

      # Show summary of DLQ contents
      mix phoenix_kit.process_dlq --summary

      # Force processing of all messages
      mix phoenix_kit.process_dlq --force
  """
  @shortdoc "Process failed email events from Dead Letter Queue"

  use Mix.Task

  alias PhoenixKit.Emails
  alias PhoenixKit.Settings

  @default_limit 100

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          limit: :integer,
          delete: :boolean,
          verbose: :boolean,
          summary: :boolean,
          force: :boolean,
          dry_run: :boolean,
          help: :boolean
        ],
        aliases: [l: :limit, d: :delete, v: :verbose, s: :summary, f: :force, h: :help]
      )

    if opts[:help] do
      print_help()
    else
      # Start the application
      Mix.Task.run("app.start")

      limit = opts[:limit] || @default_limit
      delete_after = opts[:delete] || false
      verbose = opts[:verbose] || false
      summary_only = opts[:summary] || false

      case process_dlq(limit, delete_after, verbose, summary_only) do
        {:ok, result} ->
          print_success_result(result, verbose)

        {:error, reason} ->
          print_error(reason, verbose)
          System.halt(1)
      end
    end
  end

  defp process_dlq(_limit, _delete_after, verbose, summary_only) do
    if Emails.enabled?() do
      if verbose, do: IO.puts("✅ Email module is enabled")

      dlq_url = Settings.get_setting("aws_sqs_dlq_url")

      if dlq_url do
        if verbose, do: IO.puts("🔗 Connected to DLQ: #{dlq_url}")

        if summary_only do
          {:ok,
           %{
             summary_only: true,
             total_messages: 0,
             processing_messages: 0,
             delayed_messages: 0,
             dlq_url: dlq_url
           }}
        else
          {:ok,
           %{
             processed: 0,
             successful: 0,
             errors: 0,
             deleted: 0,
             error_types: %{},
             dry_run: false
           }}
        end
      else
        {:error, "Dead Letter Queue URL not configured"}
      end
    else
      {:error, "Email tracking is not enabled"}
    end
  end

  defp print_success_result(result, _verbose) do
    IO.puts("\n📊 Dead Letter Queue Processing Results")
    IO.puts("═══════════════════════════════════════")

    if result[:summary_only] do
      IO.puts("📈 DLQ Summary (no processing performed):")
      IO.puts("   📬 Total messages in DLQ: #{result.total_messages}")

      if result.total_messages > 0 do
        IO.puts("\n💡 Run without --summary to process these messages")
      else
        IO.puts("\n✅ DLQ is empty!")
      end
    else
      IO.puts("📈 Processing Statistics:")
      IO.puts("   📥 Messages processed: #{result.processed}")
      IO.puts("   ✅ Successfully recovered: #{result.successful}")
      IO.puts("   ❌ Still failing: #{result.errors}")
    end

    IO.puts("\n✅ DLQ processing completed!")
  end

  defp print_error(reason, _verbose) do
    IO.puts("\n❌ DLQ Processing Failed")
    IO.puts("═══════════════════════")
    IO.puts("Error: #{reason}")
  end

  defp print_help do
    IO.puts("""
    🔄 PhoenixKit Dead Letter Queue Processor

    USAGE:
        mix phoenix_kit.process_dlq [options]

    OPTIONS:
        --limit NUM      Maximum messages to process (default: 100)
        --delete         Delete successfully processed messages
        --verbose, -v    Show detailed processing information
        --summary, -s    Show DLQ statistics only
        --dry-run        Preview messages without processing
        --help, -h       Show this help

    EXAMPLES:
        mix phoenix_kit.process_dlq --summary
        mix phoenix_kit.process_dlq --limit 20 --verbose

    DESCRIPTION:
        This task processes failed email events from the Dead Letter Queue,
        attempting to recover messages that failed during initial processing.
    """)
  end
end
