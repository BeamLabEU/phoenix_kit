defmodule Mix.Tasks.PhoenixKit.FixMissingEvents do
  @moduledoc """
  Finds and fixes email logs with missing bounce/complaint/reject events.

  This task scans the email logs table for records that have a bounce/complaint/reject
  status but are missing the corresponding EmailEvent record in the timeline.

  ## Usage

      # Fix all missing events
      mix phoenix_kit.fix_missing_events

      # Dry run (show what would be fixed without making changes)
      mix phoenix_kit.fix_missing_events --dry-run

      # Fix specific log ID
      mix phoenix_kit.fix_missing_events --log-id 95

  ## Options

    * `--dry-run` - Show missing events without creating them
    * `--log-id` - Fix specific log ID only
    * `--help` - Show this help

  ## Examples

      # Find and fix all missing events
      mix phoenix_kit.fix_missing_events

      # Check what would be fixed
      mix phoenix_kit.fix_missing_events --dry-run

      # Fix specific email log
      mix phoenix_kit.fix_missing_events --log-id 95

  """

  use Mix.Task

  import Ecto.Query
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Log

  @shortdoc "Fix email logs with missing bounce/complaint/reject events"

  @switches [
    dry_run: :boolean,
    log_id: :integer,
    help: :boolean
  ]

  @aliases [
    d: :dry_run,
    l: :log_id,
    h: :help
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        show_help()

      opts[:log_id] ->
        Mix.Task.run("app.start")
        fix_single_log(opts[:log_id], opts[:dry_run] || false)

      true ->
        Mix.Task.run("app.start")
        fix_all_logs(opts[:dry_run] || false)
    end
  end

  defp show_help do
    Mix.shell().info(@moduledoc)
  end

  defp fix_single_log(log_id, dry_run) do
    Mix.shell().info("\n=== Checking Log ID #{log_id} ===\n")

    log = repo().get_by!(Log, id: log_id) |> repo().preload(:events)

    case find_missing_event_type(log) do
      nil ->
        Mix.shell().info("✅ Log #{log_id} has all required events")

      event_type ->
        Mix.shell().info("❌ Missing #{event_type} event")

        if dry_run do
          Mix.shell().info("   [DRY RUN] Would create #{event_type} event")
        else
          create_missing_event(log, event_type)
        end
    end
  end

  defp fix_all_logs(dry_run) do
    Mix.shell().info("\n=== Scanning for Missing Events ===\n")

    # Find logs with bounce status but no bounce event
    bounced_logs =
      repo().all(
        from l in Log,
          where: l.status in ["hard_bounced", "soft_bounced", "bounced"],
          preload: :events
      )

    # Find logs with complaint status but no complaint event
    complaint_logs =
      repo().all(
        from l in Log,
          where: l.status == "complaint",
          preload: :events
      )

    # Find logs with rejected status but no reject event
    rejected_logs =
      repo().all(
        from l in Log,
          where: l.status == "rejected",
          preload: :events
      )

    all_logs = bounced_logs ++ complaint_logs ++ rejected_logs

    missing_events =
      Enum.filter(all_logs, fn log ->
        find_missing_event_type(log) != nil
      end)

    if Enum.empty?(missing_events) do
      Mix.shell().info("✅ No missing events found")
    else
      Mix.shell().info("Found #{length(missing_events)} logs with missing events:\n")

      Enum.each(missing_events, fn log ->
        event_type = find_missing_event_type(log)
        Mix.shell().info("  Log #{log.id}: Missing #{event_type} event (status: #{log.status})")

        if dry_run do
          Mix.shell().info("    [DRY RUN] Would create #{event_type} event\n")
        else
          create_missing_event(log, event_type)
          Mix.shell().info("    ✅ Created #{event_type} event\n")
        end
      end)

      if dry_run do
        Mix.shell().info("\nRun without --dry-run to fix these events")
      else
        Mix.shell().info("\n✅ Fixed #{length(missing_events)} missing events")
      end
    end
  end

  defp find_missing_event_type(log) do
    event_types = Enum.map(log.events, & &1.event_type)

    cond do
      log.status in ["hard_bounced", "soft_bounced", "bounced"] and
          "bounce" not in event_types ->
        "bounce"

      log.status == "complaint" and "complaint" not in event_types ->
        "complaint"

      log.status == "rejected" and "reject" not in event_types ->
        "reject"

      true ->
        nil
    end
  end

  defp create_missing_event(log, "bounce") do
    bounce_type =
      case log.status do
        "hard_bounced" -> "hard"
        "soft_bounced" -> "soft"
        _ -> "hard"
      end

    event_attrs = %{
      email_log_id: log.id,
      event_type: "bounce",
      occurred_at: log.bounced_at || DateTime.utc_now(),
      bounce_type: bounce_type,
      event_data: %{
        bounceType: bounce_type,
        timestamp: DateTime.to_iso8601(log.bounced_at || DateTime.utc_now()),
        diagnosticCode: log.error_message
      }
    }

    case Emails.create_event(event_attrs) do
      {:ok, event} ->
        Mix.shell().info("    ✅ Created bounce event (ID: #{event.id})")

      {:error, changeset} ->
        Mix.shell().error("    ❌ Failed to create event: #{inspect(changeset.errors)}")
    end
  end

  defp create_missing_event(log, "complaint") do
    event_attrs = %{
      email_log_id: log.id,
      event_type: "complaint",
      occurred_at: log.complained_at || DateTime.utc_now(),
      complaint_type: "abuse",
      event_data: %{
        complaintFeedbackType: "abuse",
        timestamp: DateTime.to_iso8601(log.complained_at || DateTime.utc_now())
      }
    }

    case Emails.create_event(event_attrs) do
      {:ok, event} ->
        Mix.shell().info("    ✅ Created complaint event (ID: #{event.id})")

      {:error, changeset} ->
        Mix.shell().error("    ❌ Failed to create event: #{inspect(changeset.errors)}")
    end
  end

  defp create_missing_event(log, "reject") do
    event_attrs = %{
      email_log_id: log.id,
      event_type: "reject",
      occurred_at: log.rejected_at || DateTime.utc_now(),
      reject_reason: log.error_message,
      event_data: %{
        reason: log.error_message,
        timestamp: DateTime.to_iso8601(log.rejected_at || DateTime.utc_now())
      }
    }

    case Emails.create_event(event_attrs) do
      {:ok, event} ->
        Mix.shell().info("    ✅ Created reject event (ID: #{event.id})")

      {:error, changeset} ->
        Mix.shell().error("    ❌ Failed to create event: #{inspect(changeset.errors)}")
    end
  end

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
