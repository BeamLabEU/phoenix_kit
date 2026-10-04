defmodule PhoenixKit.Modules.Storage.Workers.PurgeLibraryJob do
  @moduledoc """
  The Oban job that starts the purge of one trashed storage library
  (`Storage.Jobs.PurgeLibrary`, a job run): its files (bytes included, through the
  normal delete path), its folders, then the library
  (`PhoenixKit.Modules.Storage.Libraries.purge_library/1`).

  Queued when a user's libraries are trashed because the user is deleted — inside
  that transaction, which is why this is a job and not a direct start (the engine
  refuses to start a run inside a caller's transaction) — and by the daily trash
  prune for libraries trashed longer ago than the retention period. A library that is
  gone, or no longer trashed, ends the run with nothing done. One that could not be
  fully deleted from a user's own bucket is retried by the run.
  """

  use Oban.Worker, queue: :file_processing, max_attempts: 5, unique: [period: 3600]

  alias PhoenixKit.Jobs.System, as: JobsSystem
  alias PhoenixKit.Modules.Storage.Jobs.PurgeLibrary

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"library_uuid" => uuid}}) do
    case JobsSystem.start(PurgeLibrary, {"library", uuid}, source: "trash") do
      {:error, reason} -> {:error, reason}
      _started_or_existing -> :ok
    end
  end
end
