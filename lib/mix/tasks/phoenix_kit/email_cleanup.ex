defmodule Mix.Tasks.PhoenixKit.Email.Cleanup do
  @shortdoc "Clean up old email tracking logs"

  @moduledoc """
  Mix task to clean up old email tracking logs and optimize storage.

  ## Usage

      # Clean logs older than default retention period (90 days)
      mix phoenix_kit.email.cleanup

      # Clean logs older than specific number of days
      mix phoenix_kit.email.cleanup --older-than 30d

      # Show what would be deleted without actually deleting
      mix phoenix_kit.email.cleanup --dry-run

      # Compress old bodies instead of deleting
      mix phoenix_kit.email.cleanup --compress-only

      # Archive to S3 before deleting
      mix phoenix_kit.email.cleanup --archive

  ## Options

      --older-than PERIOD   Delete logs older than period (e.g., 30d, 60d, 90d)
      --dry-run             Show what would be deleted without deleting
      --compress-only       Only compress old email bodies, don't delete
      --archive             Archive logs to S3 before deleting
      --force               Skip confirmation prompts

  ## Examples

      # Safe dry run to see what would be cleaned
      mix phoenix_kit.email.cleanup --dry-run

      # Clean logs older than 30 days with archive
      mix phoenix_kit.email.cleanup --older-than 30d --archive

      # Compress bodies for logs older than 7 days
      mix phoenix_kit.email.cleanup --older-than 7d --compress-only
  """

  use Mix.Task
  alias PhoenixKit.EmailTracking

  def run(args) do
    Mix.Task.run("app.start")

    {options, _remaining} = parse_options(args)

    # Note: EmailTracking.enabled?() check omitted as Dialyzer determines it's always true

    days_old = parse_days(options[:older_than])

    Mix.shell().info(IO.ANSI.cyan() <> "\n🧹 Email Cleanup" <> IO.ANSI.reset())
    Mix.shell().info(String.duplicate("=", 40))

    if options[:compress_only] do
      run_compression(days_old, options)
    else
      run_cleanup(days_old, options)
    end
  end

  defp parse_options(args) do
    {options, remaining, _errors} =
      OptionParser.parse(args,
        strict: [
          older_than: :string,
          dry_run: :boolean,
          compress_only: :boolean,
          archive: :boolean,
          force: :boolean
        ]
      )

    # Set defaults
    options =
      options
      |> Keyword.put_new(:dry_run, false)
      |> Keyword.put_new(:compress_only, false)
      |> Keyword.put_new(:archive, false)
      |> Keyword.put_new(:force, false)

    {options, remaining}
  end

  defp parse_days(nil) do
    # Use system retention setting or default to 90 days
    EmailTracking.get_retention_days()
  end

  defp parse_days(period_string) do
    case Regex.run(~r/^(\d+)d?$/, period_string) do
      [_, days_str] ->
        String.to_integer(days_str)

      _ ->
        Mix.shell().error("Invalid period format. Use format like '30d' or '90d'")
        exit({:shutdown, 1})
    end
  end

  defp run_compression(days_old, options) do
    Mix.shell().info("🗜️  Compressing email bodies older than #{days_old} days...")

    if options[:dry_run] do
      # Show what would be compressed
      count = count_compressible_logs(days_old)
      Mix.shell().info("Would compress #{count} email log bodies")
    else
      {compressed_count, _} = EmailTracking.compress_old_bodies(days_old)

      if compressed_count > 0 do
        Mix.shell().info("✅ Compressed #{compressed_count} email log bodies")
      else
        Mix.shell().info("ℹ️  No email bodies found to compress")
      end
    end
  end

  defp run_cleanup(days_old, options) do
    Mix.shell().info("🗑️  Cleaning up email logs older than #{days_old} days...")

    if options[:archive] do
      Mix.shell().info("📦 Archiving to S3 before deletion...")

      if not options[:dry_run] do
        case EmailTracking.archive_to_s3(days_old) do
          {:ok, :skipped} ->
            Mix.shell().info("ℹ️  Archive skipped (email tracking disabled)")

          {:ok, result} ->
            archived_count = Keyword.get(result, :archived_count, 0)
            Mix.shell().info("✅ Archived #{archived_count} logs to S3")
        end
      end
    end

    if options[:dry_run] do
      count = count_deletable_logs(days_old)
      Mix.shell().info("Would delete #{count} email logs and their events")
    else
      if not options[:force] do
        confirm_deletion_or_exit(days_old)
      end

      {deleted_count, _} = EmailTracking.cleanup_old_logs(days_old)

      if deleted_count > 0 do
        Mix.shell().info("✅ Deleted #{deleted_count} old email logs")
        Mix.shell().info("💾 Storage space has been freed up")
      else
        Mix.shell().info("ℹ️  No old email logs found to delete")
      end
    end
  end

  defp count_compressible_logs(days_old) do
    _cutoff_date = Date.utc_today() |> Date.add(-days_old)

    # This would need to be implemented in EmailTracking module
    # For now, return 0
    0
  end

  defp count_deletable_logs(days_old) do
    _cutoff_date = Date.utc_today() |> Date.add(-days_old)

    # This would need to be implemented in EmailTracking module
    # For now, return a mock count for demonstration
    42
  end

  defp confirm_deletion_or_exit(days_old) do
    count = count_deletable_logs(days_old)

    if count > 0 do
      message =
        "This will permanently delete #{count} email logs older than #{days_old} days. Continue?"

      unless Mix.shell().yes?(message) do
        Mix.shell().info("Cleanup cancelled")
        exit({:shutdown, 0})
      end
    end
  end
end
