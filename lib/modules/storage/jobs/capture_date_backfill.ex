defmodule PhoenixKit.Modules.Storage.Jobs.CaptureDateBackfill do
  @moduledoc """
  The capture-date backfill as a job run (`storage.capture_date_backfill`): dates
  the images and videos stored before capture dates existed (V200), a batch at a
  time, in uuid order, so an admin sees how far it is and can pause or cancel it
  on **Admin → Jobs**.

  The work is `PhoenixKit.Modules.Storage.Workers.CaptureDateBackfillJob`'s
  (`run_batch/2` there is what every batch calls); this is the shape the Jobs
  engine drives. It is the first kind built on the engine and the simplest: a
  site-wide pass with a cursor. Replaying a batch is safe — a file that already
  has a date is not a candidate any more, and the write itself is guarded.

  **Counts after a crash are approximate.** The pass selects files that still have
  no date, so a batch that dies after dating some files and before its checkpoint
  leaves those files correctly dated but counted by no one — the replay never sees
  them. The run still completes; its `done` (and, when it was the first batch,
  `total`) can be lower than the number of files that ended up dated.

  `restart/0` is `:merge`: a second trigger while a pass runs changes nothing (the
  files it would date are dated by the running pass, or by the next one).
  """

  use PhoenixKit.Jobs.Kind

  alias PhoenixKit.Modules.Storage.Workers.CaptureDateBackfillJob

  @impl true
  def kind, do: "storage.capture_date_backfill"

  @impl true
  def module_key, do: "storage"

  @impl true
  def title(_args, _scope), do: "Date images and videos by when they were taken"

  @impl true
  def idempotent?, do: true

  @impl true
  def permission, do: "media.manage"

  @impl true
  def queue, do: :file_processing

  # One batch reads up to 50 files' bytes (a remote bucket, or a video).
  @impl true
  def timeout, do: :timer.minutes(10)

  @impl true
  def batch(run) do
    # The first batch of a pass says how many files it has to get through.
    total =
      if run.cursor["after"] in [nil, ""],
        do: %{total: CaptureDateBackfillJob.pending_count()},
        else: %{}

    case CaptureDateBackfillJob.run_batch(run.cursor["after"], %{}) do
      {:more, last_uuid, batch} ->
        cursor = %{"after" => last_uuid, "outcomes" => outcomes(run, batch)}
        {:more, total |> Map.merge(counts(batch)) |> Map.put(:cursor, cursor), []}

      {:done, batch} ->
        {:done, %{"outcomes" => outcomes(run, batch)}, Map.merge(total, counts(batch))}
    end
  end

  # What every batch of the pass did so far, kept in the cursor so the last one can
  # report the whole pass (the Mix task prints it).
  defp outcomes(run, batch) do
    Enum.reduce(batch, run.cursor["outcomes"] || %{}, fn {outcome, n}, acc ->
      Map.update(acc, Atom.to_string(outcome), n, &(&1 + n))
    end)
  end

  # A file that ended up dated, kept, changed meanwhile or gone is done; one that
  # could not be read is failed.
  defp counts(batch) do
    failed = Map.get(batch, :error, 0)
    %{done: Enum.sum(Map.values(batch)) - failed, failed: failed}
  end
end
