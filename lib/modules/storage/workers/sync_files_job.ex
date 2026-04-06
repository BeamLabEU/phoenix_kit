defmodule PhoenixKit.Modules.Storage.Workers.SyncFilesJob do
  @moduledoc """
  Oban worker that syncs under-replicated files to meet the redundancy target.

  Broadcasts progress via PubSub so the Health LiveView can display real-time
  updates. Stores sync state in persistent_term so the UI survives page refreshes.
  """
  use Oban.Worker, queue: :file_processing, max_attempts: 1

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings

  @sync_topic "media:sync_progress"
  @sync_state_key :phoenix_kit_media_sync_state

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    redundancy_target =
      Settings.get_setting("storage_redundancy_copies", "1")
      |> String.to_integer()

    put_sync_state(%{done: 0, total: 0, synced: 0, failed: 0, status: :starting})

    Storage.sync_under_replicated_with_progress(redundancy_target, fn progress ->
      put_sync_state(progress)
      PubSubManager.broadcast(@sync_topic, {:sync_progress, progress})
    end)

    clear_sync_state()
    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  defp put_sync_state(state) do
    :persistent_term.put(@sync_state_key, state)
  end

  defp clear_sync_state do
    :persistent_term.erase(@sync_state_key)
  rescue
    ArgumentError -> :ok
  end
end
