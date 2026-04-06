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
  @sync_paused_key :phoenix_kit_media_sync_paused
  @sync_stopped_key :phoenix_kit_media_sync_stopped

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    redundancy_target =
      Settings.get_setting("storage_redundancy_copies", "1")
      |> String.to_integer()

    clear_paused()
    clear_stopped()
    put_sync_state(%{done: 0, total: 0, synced: 0, failed: 0, status: :starting})

    Storage.sync_under_replicated_with_progress(
      redundancy_target,
      fn progress ->
        wait_while_paused()
        put_sync_state(progress)
        PubSubManager.broadcast(@sync_topic, {:sync_progress, progress})
      end,
      check_cancelled: &stopped?/0
    )

    if stopped?() do
      Logger.info("Media sync stopped by admin")
      state = get_sync_state() || %{done: 0, total: 0, synced: 0, failed: 0}
      PubSubManager.broadcast(@sync_topic, {:sync_progress, Map.put(state, :status, :stopped)})
    end

    clear_sync_state()
    clear_paused()
    clear_stopped()
    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  def pause, do: :persistent_term.put(@sync_paused_key, true)
  def resume, do: :persistent_term.erase(@sync_paused_key)
  def paused?, do: :persistent_term.get(@sync_paused_key, false) == true

  def stop, do: :persistent_term.put(@sync_stopped_key, true)
  def stopped?, do: :persistent_term.get(@sync_stopped_key, false) == true

  defp wait_while_paused do
    if paused?() and not stopped?() do
      Process.sleep(500)
      wait_while_paused()
    end
  end

  defp put_sync_state(state) do
    :persistent_term.put(@sync_state_key, state)
  end

  defp clear_sync_state do
    :persistent_term.erase(@sync_state_key)
  rescue
    ArgumentError -> :ok
  end

  defp clear_paused do
    :persistent_term.erase(@sync_paused_key)
  rescue
    ArgumentError -> :ok
  end

  defp clear_stopped do
    :persistent_term.erase(@sync_stopped_key)
  rescue
    ArgumentError -> :ok
  end

  defp get_sync_state do
    :persistent_term.get(@sync_state_key, nil)
  rescue
    ArgumentError -> nil
  end
end
