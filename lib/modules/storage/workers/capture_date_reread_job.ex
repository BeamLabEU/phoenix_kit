defmodule PhoenixKit.Modules.Storage.Workers.CaptureDateRereadJob do
  @moduledoc """
  Reads the capture date in the bytes of files whose date a person gave back to them
  (`PhoenixKit.Modules.Storage.ManualDate.reset/2`). The reset dated them from their
  name or upload time at once; this reads each original (EXIF, a video's container)
  through `CaptureDateBackfillJob.record/1`, whose guard lets a date from the bytes
  replace those and never a date a person set again in the meantime.

  Files whose date changed are announced on the file-changes topic, so a timeline
  showing them moves them.
  """

  use Oban.Worker, queue: :file_processing, max_attempts: 3

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Workers.CaptureDateBackfillJob

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"file_uuids" => file_uuids}}) when is_list(file_uuids) do
    file_uuids
    |> Enum.filter(&(record(&1) == :ok))
    |> Storage.broadcast_files_changed()

    :ok
  end

  def perform(_job), do: :ok

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  # One file that cannot be read must not stop the rest.
  defp record(uuid) do
    CaptureDateBackfillJob.record(uuid)
  rescue
    error ->
      Logger.warning("CaptureDateRereadJob: #{uuid}: #{Exception.message(error)}")
      :error
  end
end
