defmodule PhoenixKit.Modules.Storage.Workers.CaptureDateBackfillJob do
  @moduledoc """
  Dates the images and videos stored before capture dates existed (V200).

  New uploads get their date from `ProcessFileJob`. Files already stored have
  none, so this job walks them in `@batch_size` batches, in uuid order, reads
  each one's bytes and records a date through the same
  `CaptureDate.replace?/2` guard. Every visited file ends up with a date: when
  its bytes cannot be read, the file name or the upload time is used.

  **Chaining.** Each run handles one batch and enqueues the next with a
  cursor (`"after"`, the last uuid it visited), so a file is visited once per
  pass even when it cannot be dated — a stuck row cannot loop the chain. Only
  one pending run exists at a time (`unique` over `[:worker, :queue]`,
  ignoring the cursor); a run that is executing does not count, so it can
  enqueue its own successor.

  **An edited image** is dated from its unedited backup
  (`original_file_uuid`) when it has one: an edit keeps only the ICC profile,
  so the edited bytes carry no EXIF.

  Start a pass in the background with `enqueue/0`, or run one to completion
  in the calling process with `run_pass/1` — which is what
  `mix phoenix_kit.storage.backfill_capture_dates` does.
  """

  use Oban.Worker,
    queue: :file_processing,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue], states: [:available, :scheduled]]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Jobs.System, as: JobsSystem
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.CaptureDate
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Jobs.CaptureDateBackfill

  @batch_size 50

  @doc """
  Starts a backfill pass as a job run (`PhoenixKit.Modules.Storage.Jobs.CaptureDateBackfill`),
  unless one is already active. Returns `{:ok, run, :started | :existing}`.
  """
  @spec enqueue() :: {:ok, PhoenixKit.Jobs.Run.t(), :started | :existing} | {:error, term()}
  def enqueue do
    JobsSystem.start(CaptureDateBackfill, :site, source: "backfill")
  end

  @doc "How many images and videos still have no capture date."
  @spec pending_count() :: non_neg_integer()
  def pending_count do
    repo().aggregate(pending_query(), :count)
  end

  # The pass is a job run now. A job queued by an earlier release (this worker used
  # to chain itself with a cursor) starts that run and ends: its old cursor is
  # dropped, which is safe — a file already dated is not a candidate any more.
  # This clause stays until `mix phoenix_kit.doctor` finds no job left for it.
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case enqueue() do
      {:error, reason} -> {:error, reason}
      _started_or_existing -> :ok
    end
  end

  @doc """
  Runs a whole pass in the calling process, batch after batch, and returns
  how many files ended in each outcome of `record/1` (plus `:error`).
  `progress` is called with the running totals after every batch.
  """
  @spec run_pass((map() -> any())) :: %{atom() => pos_integer()}
  def run_pass(progress \\ fn _totals -> :ok end), do: run_pass(nil, %{}, progress)

  defp run_pass(after_uuid, totals, progress) do
    case run_batch(after_uuid, totals) do
      {:more, last_uuid, totals} ->
        progress.(totals)
        run_pass(last_uuid, totals, progress)

      {:done, totals} ->
        progress.(totals)
        totals
    end
  end

  # One batch after `after_uuid`: `{:more, last_uuid, totals}` while a full
  # batch came back, `{:done, totals}` once the pass has reached the end. What
  # `PhoenixKit.Modules.Storage.Jobs.CaptureDateBackfill` calls for each batch.
  @doc false
  def run_batch(after_uuid, totals) do
    uuids = next_batch(after_uuid)

    totals =
      Enum.reduce(uuids, totals, fn uuid, acc ->
        Map.update(acc, record_safely(uuid), 1, &(&1 + 1))
      end)

    if length(uuids) == @batch_size,
      do: {:more, List.last(uuids), totals},
      else: {:done, totals}
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @doc """
  Reads and records the capture date of one file. Returns `:ok` when a date
  was written, `:kept` when a stronger one was already there, `:changed` when
  the file's bytes changed while they were being read, and `:gone` when the
  file no longer exists.
  """
  @spec record(String.t()) :: :ok | :kept | :changed | :gone | {:error, term()}
  def record(file_uuid) do
    case Storage.get_file(file_uuid) do
      %StorageFile{} = file ->
        source_uuid = file.original_file_uuid || file.uuid
        {attrs, key} = read(source_uuid, file)
        write(file, source_uuid, key, attrs)

      nil ->
        :gone
    end
  end

  # One bad file must not fail the batch and stall the pass behind it.
  defp record_safely(uuid) do
    case record(uuid) do
      {:error, reason} ->
        Logger.warning("CaptureDateBackfillJob: #{uuid}: #{inspect(reason)}")
        :error

      outcome ->
        outcome
    end
  rescue
    error ->
      Logger.warning("CaptureDateBackfillJob: #{uuid}: #{Exception.message(error)}")
      :error
  end

  # The date from the bytes when they can be fetched (with the key they were
  # read from, for the write-time check), else from the name and upload time.
  defp read(source_uuid, file) do
    case Storage.retrieve_original(source_uuid) do
      {:ok, temp_path, _source_file, instance} ->
        try do
          {CaptureDate.resolve(temp_path, file), instance.file_name}
        after
          Elixir.File.rm(temp_path)
        end

      _error ->
        {CaptureDate.resolve(nil, file), nil}
    end
  end

  @doc false
  def write(file, source_uuid, key, attrs) do
    repo().transaction(fn ->
      current =
        repo().one(from(f in StorageFile, where: f.uuid == ^file.uuid, lock: "FOR UPDATE"))

      cond do
        is_nil(current) -> :gone
        wrong_bytes?(current, source_uuid, key) -> :changed
        not CaptureDate.replace?(current.taken_at_source, attrs.taken_at_source) -> :kept
        true -> current |> StorageFile.changeset(attrs) |> repo().update()
      end
    end)
    |> case do
      {:ok, {:ok, _file}} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, outcome} -> outcome
      {:error, reason} -> {:error, reason}
    end
  end

  # A date derived from bytes is recorded only while those bytes are still
  # what the file should be dated from.
  #
  # A backup that appeared while the bytes were being read (an image edit
  # mid-pass) means we either failed the download or read the edited
  # original, which has no EXIF. Writing the filename then would stick:
  # `pending_query` skips a row that has a date, and `ProcessFileJob` skips
  # a file that has a backup. Leave `taken_at` nil (`:changed`) so the next
  # pass reads the backup.
  #
  # A nil key is a download that failed and no backup is in play — the name
  # or the upload time is the date, and there is nothing to re-check.
  defp wrong_bytes?(current, source_uuid, key) do
    cond do
      is_binary(current.original_file_uuid) and current.original_file_uuid != source_uuid ->
        true

      is_nil(key) ->
        false

      source_uuid == current.uuid ->
        not Storage.original_key?(current.uuid, key)

      true ->
        not Storage.original_key?(source_uuid, key)
    end
  end

  defp next_batch(after_uuid) do
    query = from(f in pending_query(), order_by: f.uuid, limit: @batch_size, select: f.uuid)

    query = if after_uuid, do: from(f in query, where: f.uuid > ^after_uuid), else: query

    repo().all(query)
  end

  defp pending_query do
    from(f in StorageFile,
      where:
        is_nil(f.taken_at) and f.file_type in ["image", "video"] and f.system_managed == false
    )
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
