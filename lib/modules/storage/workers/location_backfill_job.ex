defmodule PhoenixKit.Modules.Storage.Workers.LocationBackfillJob do
  @moduledoc """
  Records where the objects stored before location-truth are (V204).

  Every writer records a `phoenix_kit_file_locations` row for each bucket it
  stores an object in, and marks its instances checked. Instances stored
  earlier by writers that did not (Tessera tiles, comment attachments) are
  unchecked. This job walks them in `@batch_size` batches, in uuid order,
  checks each enabled bucket for the instance's key once, records every
  bucket that has it (`Storage.Locations.record/2`), and marks the instance
  checked with how many held it (`Locations.mark_checked/2`) — a miss too,
  so it is not work again and the Health count reaches zero.

  "Unchecked", not "has no location row": a read that finds a key in a
  bucket records that one bucket, which must not retire the instance from
  this walk while its other copies are unrecorded.

  **Throttled.** One batch per run, and the next run is scheduled
  `@pause_seconds` later, on the `file_processing` queue, so a large or
  remote bucket is walked at a steady pace instead of all at once.

  **Queued by itself** (the maintainer's decision, plan §"Next: V204"):
  `PhoenixKit.Supervisor` calls `maybe_enqueue/0` shortly after boot, and
  the daily trash prune does too, whenever any instance has no row. Only one
  pending run exists at a time (`unique` over `[:worker, :queue]`, ignoring
  the cursor). Reads keep working meanwhile: the manager checks the other
  buckets for a key with no rows, and records what it finds.

  `run_pass/1` runs a whole pass in the calling process.
  """

  use Oban.Worker,
    queue: :file_processing,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue], states: [:available, :scheduled]]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Jobs.System, as: JobsSystem
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Jobs.LocationBackfill
  alias PhoenixKit.Modules.Storage.{Locations, ProviderRegistry}

  @batch_size 50

  @doc """
  Starts a pass as a job run (`Storage.Jobs.LocationBackfill`) when any instance is
  unchecked, unless one is already active. Never raises.
  """
  @spec maybe_enqueue() :: :queued | :nothing_to_do | :unavailable
  def maybe_enqueue do
    if pending?() do
      case JobsSystem.start(LocationBackfill, :site, source: "backfill") do
        {:ok, _run, _how} -> :queued
        _ -> :unavailable
      end
    else
      :nothing_to_do
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  @doc "Whether any instance is unchecked."
  @spec pending?() :: boolean()
  def pending? do
    repo().exists?(missing_query(nil))
  end

  @doc "How many instances are unchecked (for the Health page)."
  @spec pending_count() :: non_neg_integer()
  def pending_count, do: Locations.missing_count()

  # The pass is a job run now. A job queued by an earlier release (this worker used
  # to chain itself with a cursor) starts that run and ends: its old cursor is
  # dropped, which is safe — checking an instance twice does no harm. This clause
  # stays until `mix phoenix_kit.doctor` finds no job left for it.
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case JobsSystem.start(LocationBackfill, :site, source: "backfill") do
      {:error, reason} -> {:error, reason}
      _started_or_existing -> :ok
    end
  end

  @doc """
  Runs a whole pass in the calling process, batch after batch, and returns
  how many instances were `:recorded`, how many were `:missing` (in no
  enabled bucket) and how many `:unsure` (a bucket could not answer; left
  unchecked for the next pass). `progress` is called with the running totals.
  """
  @spec run_pass((map() -> any())) :: %{atom() => non_neg_integer()}
  def run_pass(progress \\ fn _totals -> :ok end), do: run_pass(nil, %{}, progress)

  defp run_pass(cursor, totals, progress) do
    case run_batch(cursor, totals) do
      {:more, last_uuid, totals} ->
        progress.(totals)
        run_pass(last_uuid, totals, progress)

      {:done, totals} ->
        progress.(totals)
        totals
    end
  end

  # One batch after `cursor`: `{:more, last_uuid, totals}` while a full batch
  # was read, `{:done, totals}` once the walk has passed the last instance. What
  # `Storage.Jobs.LocationBackfill` calls for each batch.
  @doc false
  def run_batch(cursor, totals) do
    buckets = Storage.list_enabled_buckets()

    batch =
      cursor
      |> missing_query()
      |> then(&from(i in &1, order_by: i.uuid, limit: @batch_size, select: {i.uuid, i.file_name}))
      |> repo().all()

    totals =
      Enum.reduce(batch, totals, fn {uuid, key}, acc ->
        outcome =
          case locate(key, buckets) do
            # A bucket could not answer: nothing is concluded, and the
            # instance stays unchecked for the next pass. Marking it would
            # turn a broken connection into "found nowhere", which reads
            # then take as the object being gone (#882).
            {:unsure, _found} ->
              :unsure

            # Checked, found or not: a miss is remembered, so it is not
            # work again.
            {:ok, found} ->
              Locations.mark_checked([uuid], found)
              if found > 0, do: :recorded, else: :missing
          end

        Map.update(acc, outcome, 1, &(&1 + 1))
      end)

    case batch do
      [] -> {:done, totals}
      _ when length(batch) < @batch_size -> {:done, totals}
      _ -> {:more, batch |> List.last() |> elem(0) |> to_string(), totals}
    end
  end

  # Checks every enabled bucket for `key` once and records each that holds
  # it: `{:ok, count}`, or `{:unsure, count}` when a bucket could not
  # answer (the ones that did are still recorded).
  defp locate(key, buckets) when is_binary(key) do
    answers =
      Enum.map(buckets, fn bucket ->
        case ProviderRegistry.get_provider(bucket.provider) do
          {:ok, provider} -> {bucket, safe_exists?(provider, bucket, key)}
          _ -> {bucket, :error}
        end
      end)

    found =
      for {bucket, true} <- answers do
        Locations.record(key, bucket.uuid)
        bucket
      end

    if Enum.any?(answers, &match?({_, :error}, &1)),
      do: {:unsure, length(found)},
      else: {:ok, length(found)}
  end

  defp locate(_key, _buckets), do: {:ok, 0}

  defp safe_exists?(provider, bucket, key) do
    provider.file_exists?(bucket, key)
  rescue
    error ->
      Logger.warning(
        "LocationBackfillJob: could not check #{key} on #{bucket.name}: #{Exception.message(error)}"
      )

      :error
  end

  defp missing_query(nil), do: Locations.unchecked_query()

  defp missing_query(after_uuid),
    do: from(i in Locations.unchecked_query(), where: i.uuid > ^after_uuid)

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
