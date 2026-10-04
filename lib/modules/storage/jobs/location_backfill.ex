defmodule PhoenixKit.Modules.Storage.Jobs.LocationBackfill do
  @moduledoc """
  Records where the objects stored before location-truth are (V204), as a job run
  (`storage.location_backfill`): the instances no writer recorded a bucket for
  (Tessera tiles, comment attachments) are checked against every enabled bucket
  once, fifty a batch, in uuid order, with a five-second pause between batches on
  the `file_processing` queue so a large or remote bucket is walked at a steady
  pace. An admin sees how far it is on **Admin → Jobs** and can pause or cancel it.

  The work of a batch is `PhoenixKit.Modules.Storage.Workers.LocationBackfillJob`'s
  (`run_batch/2` there). Started by the application shortly after boot and by the
  daily trash prune whenever any instance is unchecked (`LocationBackfillJob.maybe_enqueue/0`).

  `done` counts the instances that were checked (found somewhere, or found in no
  bucket — a miss is remembered), `failed` those a bucket could not answer for: they
  stay unchecked for the next pass. Replaying a batch is safe (checking is
  idempotent). `restart/0` is `:merge`: a second trigger changes nothing.
  """

  use PhoenixKit.Jobs.Kind

  alias PhoenixKit.Modules.Storage.Workers.LocationBackfillJob

  @impl true
  def kind, do: "storage.location_backfill"

  @impl true
  def module_key, do: "storage"

  @impl true
  def title(_args, _scope), do: "Find where stored files are kept"

  @impl true
  def idempotent?, do: true

  @impl true
  def permission, do: "media.manage"

  @impl true
  def queue, do: :file_processing

  # One batch asks every bucket about fifty keys: a remote one can be slow.
  @impl true
  def timeout, do: :timer.minutes(10)

  @impl true
  def batch(run) do
    total =
      if run.cursor["after"] in [nil, ""],
        do: %{total: LocationBackfillJob.pending_count()},
        else: %{}

    case LocationBackfillJob.run_batch(run.cursor["after"], %{}) do
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
    unsure = Map.get(batch, :unsure, 0)
    %{done: Enum.sum(Map.values(batch)) - unsure, failed: unsure}
  end
end
