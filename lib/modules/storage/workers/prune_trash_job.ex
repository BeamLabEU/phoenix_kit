defmodule PhoenixKit.Modules.Storage.Workers.PruneTrashJob do
  @moduledoc """
  Oban worker that permanently deletes trashed files older than the configured retention period.

  Runs daily via cron. Retention is configured via the `trash_retention_days` setting (default: 30).
  """

  use Oban.Worker, queue: :file_processing, max_attempts: 3

  require Logger

  alias PhoenixKit.Modules.Storage

  @impl Oban.Worker
  def perform(_job) do
    days = Storage.trash_retention_days()

    case Storage.prune_trash(days) do
      {:ok, 0} ->
        Logger.debug("PruneTrashJob: no expired trashed files to clean up")
        :ok

      {:ok, count} ->
        Logger.info("PruneTrashJob: permanently deleted #{count} expired trashed files")
        :ok
    end
  end
end
