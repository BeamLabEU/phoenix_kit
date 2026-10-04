defmodule PhoenixKit.Modules.Storage.Jobs.ChecksumBackfill do
  @moduledoc """
  Recomputes the MD5 checksums the upload API used to record (G12), as a job run
  (`storage.checksum_backfill`): a file stored with a 32-hex-character checksum has
  its original read and its SHA-256 and matching `user_file_checksum` recorded, twenty
  a batch, in uuid order, five seconds apart on the `file_processing` queue.

  The work of a batch is `PhoenixKit.Modules.Storage.Workers.ChecksumBackfillJob`'s
  (`run_batch/2`). Started after boot and by the daily trash prune while any MD5 row
  is left (`ChecksumBackfillJob.maybe_enqueue/0`).

  `done` counts the files handled (updated, left because their uploader has the bytes
  already, or edited meanwhile — all final), `failed` those whose original could not
  be read (marked, so a later pass does not download them again). Replaying a batch is
  safe: the update is guarded on the old checksum. `restart/0` is `:merge`.
  """

  use PhoenixKit.Jobs.Kind

  alias PhoenixKit.Modules.Storage.Workers.ChecksumBackfillJob

  @impl true
  def kind, do: "storage.checksum_backfill"

  @impl true
  def module_key, do: "storage"

  @impl true
  def title(_args, _scope), do: "Recompute old upload checksums"

  @impl true
  def idempotent?, do: true

  @impl true
  def permission, do: "media.manage"

  @impl true
  def queue, do: :file_processing

  # A batch reads twenty originals, a remote bucket's included.
  @impl true
  def timeout, do: :timer.minutes(10)

  @impl true
  def batch(run) do
    total =
      if run.cursor["after"] in [nil, ""],
        do: %{total: ChecksumBackfillJob.pending_count()},
        else: %{}

    case ChecksumBackfillJob.run_batch(run.cursor["after"], %{}) do
      {:more, last_uuid, batch} ->
        cursor = %{"after" => last_uuid, "outcomes" => outcomes(run, batch)}
        {:more, total |> Map.merge(counts(batch)) |> Map.put(:cursor, cursor), schedule_in: 5}

      {:done, batch} ->
        {:done, %{"outcomes" => outcomes(run, batch)}, Map.merge(total, counts(batch))}
    end
  end

  defp outcomes(run, batch) do
    Enum.reduce(batch, run.cursor["outcomes"] || %{}, fn {outcome, n}, acc ->
      Map.update(acc, Atom.to_string(outcome), n, &(&1 + n))
    end)
  end

  defp counts(batch) do
    unreadable = Map.get(batch, :unreadable, 0)
    %{done: Enum.sum(Map.values(batch)) - unreadable, failed: unreadable}
  end
end
