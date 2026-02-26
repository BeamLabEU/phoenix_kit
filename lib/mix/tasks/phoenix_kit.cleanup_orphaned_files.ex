defmodule Mix.Tasks.PhoenixKit.CleanupOrphanedFiles do
  @moduledoc """
  Finds and optionally deletes orphaned media files in PhoenixKit Storage.

  An orphaned file is one not referenced by any known entity (products, posts,
  categories, users, publishing content, etc.).

  By default this task runs in dry-run mode and only reports what would be deleted.
  Use `--delete` to queue the actual deletion via Oban.

  ## Usage

      $ mix phoenix_kit.cleanup_orphaned_files
      $ mix phoenix_kit.cleanup_orphaned_files --delete

  ## Options

    * `--delete` - Queue orphaned files for deletion (default: dry-run)

  ## Examples

      # Dry-run: show orphaned files without deleting
      mix phoenix_kit.cleanup_orphaned_files

      # Queue all orphaned files for deletion
      mix phoenix_kit.cleanup_orphaned_files --delete

  """

  use Mix.Task

  alias PhoenixKit.Modules.Storage

  @shortdoc "Find and optionally delete orphaned media files"

  @switches [delete: :boolean]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches)
    do_delete = opts[:delete] || false

    Mix.shell().info("\nPhoenixKit Storage — Orphaned Files Cleanup")
    Mix.shell().info(String.duplicate("─", 50))

    count = Storage.count_orphaned_files()

    if count == 0 do
      Mix.shell().info("✓ No orphaned files found.")
      :ok
    else
      orphans = Storage.find_orphaned_files()

      if do_delete do
        Mix.shell().info("Found #{count} orphaned file(s). Queuing for deletion...\n")
      else
        Mix.shell().info("Found #{count} orphaned file(s) (dry-run — use --delete to remove):\n")
      end

      Enum.each(orphans, fn file ->
        size = format_size(file.size || 0)
        name = file.original_file_name || file.file_name || "unknown"
        Mix.shell().info("  #{file.uuid}  #{name}  (#{size})")
      end)

      if do_delete do
        uuids = Enum.map(orphans, & &1.uuid)
        Storage.queue_file_cleanup(uuids)
        Mix.shell().info("\n✓ #{count} file(s) queued for deletion (60s delay).")
      else
        Mix.shell().info("\nRun with --delete to queue these files for deletion.")
      end

      :ok
    end
  end

  defp format_size(bytes) when bytes >= 1_000_000,
    do: "#{Float.round(bytes / 1_000_000, 2)} MB"

  defp format_size(bytes) when bytes >= 1_000,
    do: "#{Float.round(bytes / 1_000, 2)} KB"

  defp format_size(bytes), do: "#{bytes} B"
end
