defmodule PhoenixKit.Modules.Storage.Workers.DeleteOrphanedFileJob do
  @moduledoc """
  Oban job for deleting a single orphaned file.

  Verifies the file is still orphaned before deletion to protect against
  race conditions where a file may be referenced again after being queued.
  """

  use Oban.Worker, queue: :file_processing, max_attempts: 3

  require Logger

  alias PhoenixKit.Modules.Storage

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"file_uuid" => file_uuid}}) do
    case Storage.get_file(file_uuid) do
      nil ->
        # Already deleted
        :ok

      file ->
        if Storage.file_orphaned?(file_uuid) do
          case Storage.delete_file_completely(file) do
            {:ok, _} ->
              Logger.info("DeleteOrphanedFileJob: deleted file #{file_uuid}")
              :ok

            {:error, reason} ->
              Logger.warning(
                "DeleteOrphanedFileJob: failed to delete file #{file_uuid}: #{inspect(reason)}"
              )

              {:error, reason}
          end
        else
          Logger.info("DeleteOrphanedFileJob: file #{file_uuid} is still referenced, skipping")
          :ok
        end
    end
  end
end
