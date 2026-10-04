defmodule Mix.Tasks.PhoenixKit.Storage.BackfillCaptureDates do
  @moduledoc """
  Dates the images and videos stored before capture dates existed (V200).

  New uploads are dated as they are processed. Files stored earlier have no
  `taken_at`; this task walks every one of them, reads its bytes, and records
  when it was taken — from EXIF or the video container, else the date in its
  file name, else its upload time. See `PhoenixKit.Modules.Storage.CaptureDate`.

  Runs the pass in this process, batch by batch, printing progress, and is
  safe to re-run: a file that already has a date from an equal or stronger
  source keeps it, and a date set by hand is never touched. To run the same
  pass in the background instead, call
  `PhoenixKit.Modules.Storage.Workers.CaptureDateBackfillJob.enqueue/0`.

  ## Usage

      $ mix phoenix_kit.storage.backfill_capture_dates

  The task boots the host application. If it serves HTTP on boot and the
  server is already running, give it an unused port (`PORT=4021 mix …`).

  Exits `1` when any file could not be recorded.

  The counts are what the run recorded at its batch boundaries. If this process is
  killed mid-batch, the files that batch had already dated are not counted by
  anyone (the next run only sees the files still undated); the files themselves
  are dated correctly.
  """

  use Mix.Task

  alias PhoenixKit.Modules.Storage.Jobs.CaptureDateBackfill
  alias PhoenixKit.Modules.Storage.Workers.CaptureDateBackfillJob

  @shortdoc "Record when the already-stored images and videos were taken"

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: []) do
      {[], [], []} ->
        Mix.Task.run("app.start")
        backfill()

      {_opts, _args, _invalid} ->
        Mix.shell().error("mix phoenix_kit.storage.backfill_capture_dates takes no arguments")
        exit({:shutdown, 1})
    end
  end

  # A batch cut off earlier (a crash, a timeout) was run again; the files it had
  # already dated are in nobody's tally.
  defp interrupted_note(%{interruptions: n}) when n > 0 do
    Mix.shell().info(
      "Note: #{n} batch(es) of this run were interrupted and run again; the counts above " <>
        "may not include the files they had already dated. The files themselves are dated."
    )
  end

  defp interrupted_note(_run), do: :ok

  defp backfill do
    pending = CaptureDateBackfillJob.pending_count()
    Mix.shell().info("#{pending} image(s) and video(s) without a capture date")

    if pending > 0 do
      # A run in this process (mode "script"): it shows on Admin → Jobs with its
      # history like any other, and goes through the same claim and checkpoint
      # rules as a queued one.
      case PhoenixKit.Jobs.run_inline(CaptureDateBackfill, :site, on_progress: &report/1) do
        {:ok, %{state: "completed"} = run} ->
          totals = outcomes(run)
          Mix.shell().info("Done: " <> summary(totals))
          interrupted_note(run)
          if Map.get(totals, :error, 0) > 0, do: exit({:shutdown, 1})

        {:ok, run} ->
          Mix.shell().error(
            "The run ended #{run.state}: #{run.error || "stopped by someone else"}"
          )

          exit({:shutdown, 1})

        {:error, reason} ->
          Mix.shell().error("Could not run: #{inspect(reason)}")
          exit({:shutdown, 1})
      end
    end
  end

  defp report(run), do: Mix.shell().info("  #{run.done} dated, #{run.failed_count} failed")

  defp outcomes(run) do
    run.result
    |> Map.get("outcomes", %{})
    |> Map.new(fn {outcome, n} -> {String.to_existing_atom(outcome), n} end)
  end

  defp summary(totals) do
    [ok: "dated", kept: "kept", changed: "changed meanwhile", gone: "gone", error: "failed"]
    |> Enum.map_join(", ", fn {outcome, label} -> "#{Map.get(totals, outcome, 0)} #{label}" end)
  end
end
