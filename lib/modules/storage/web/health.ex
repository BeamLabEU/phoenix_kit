defmodule PhoenixKitWeb.Live.Modules.Storage.Health do
  @moduledoc """
  Media health check LiveView.

  Compares file instance location counts against the configured redundancy
  target and reports under-replicated files.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @sync_topic "media:sync_progress"
  @sync_state_key :phoenix_kit_media_sync_state

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale]
    project_title = Settings.get_project_title()

    if connected?(socket) do
      PubSubManager.subscribe(@sync_topic)
    end

    # Check if a sync is already running
    sync_state = get_sync_state()

    socket =
      socket
      |> assign(:current_path, Routes.path("/admin/settings/media/health"))
      |> assign(:page_title, gettext("Media Health"))
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:url_path, Routes.path("/admin/settings/media/health"))
      |> apply_sync_state(sync_state)
      |> load_health_report()

    {:ok, socket}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_health_report(socket)}
  end

  def handle_event("sync", _params, socket) do
    # Prevent double-sync
    if get_sync_state() != nil do
      {:noreply, put_flash(socket, :warning, gettext("Sync is already running"))}
    else
      redundancy_target = socket.assigns.report.redundancy_target

      # Start unlinked so it survives page refresh
      spawn(fn ->
        put_sync_state(%{done: 0, total: 0, synced: 0, failed: 0, status: :starting})

        Storage.sync_under_replicated_with_progress(redundancy_target, fn progress ->
          put_sync_state(progress)
          PubSubManager.broadcast(@sync_topic, {:sync_progress, progress})
        end)

        clear_sync_state()
      end)

      socket =
        socket
        |> assign(:syncing, true)
        |> assign(:sync_progress, 0)
        |> assign(:sync_total, 0)
        |> assign(:sync_synced, 0)
        |> assign(:sync_failed, 0)

      {:noreply, socket}
    end
  end

  def handle_info(
        {:sync_progress,
         %{done: done, total: total, synced: synced, failed: failed, status: :in_progress}},
        socket
      ) do
    # Update health stats live based on sync progress
    report = socket.assigns.report
    new_healthy = report.healthy + synced

    new_percentage =
      if report.total > 0,
        do: Float.round(new_healthy / report.total * 100, 1),
        else: 100.0

    updated_report = %{
      report
      | healthy: new_healthy,
        under_replicated: Enum.drop(report.under_replicated, synced),
        health_percentage: new_percentage
    }

    socket =
      socket
      |> assign(:syncing, true)
      |> assign(:sync_progress, done)
      |> assign(:sync_total, total)
      |> assign(:sync_synced, synced)
      |> assign(:sync_failed, failed)
      |> assign(:report, updated_report)

    {:noreply, socket}
  end

  def handle_info({:sync_progress, %{status: :complete} = result}, socket) do
    socket =
      socket
      |> assign(:syncing, false)
      |> assign(:sync_progress, result.total)
      |> assign(:sync_total, result.total)
      |> assign(:sync_synced, result.synced)
      |> assign(:sync_failed, result.failed)
      |> load_health_report()
      |> put_flash(
        :info,
        gettext("Sync complete: %{synced} synced, %{failed} failed",
          synced: result.synced,
          failed: result.failed
        )
      )

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_health_report(socket) do
    redundancy_target =
      Settings.get_setting_cached("storage_redundancy_copies", "1")
      |> String.to_integer()

    report = Storage.get_health_report(redundancy_target)

    assign(socket, :report, report)
  end

  defp apply_sync_state(socket, nil) do
    socket
    |> assign(:syncing, false)
    |> assign(:sync_progress, 0)
    |> assign(:sync_total, 0)
    |> assign(:sync_synced, 0)
    |> assign(:sync_failed, 0)
  end

  defp apply_sync_state(socket, state) do
    socket
    |> assign(:syncing, true)
    |> assign(:sync_progress, state[:done] || 0)
    |> assign(:sync_total, state[:total] || 0)
    |> assign(:sync_synced, state[:synced] || 0)
    |> assign(:sync_failed, state[:failed] || 0)
  end

  defp get_sync_state do
    :persistent_term.get(@sync_state_key, nil)
  rescue
    ArgumentError -> nil
  end

  defp put_sync_state(state) do
    :persistent_term.put(@sync_state_key, state)
  end

  defp clear_sync_state do
    :persistent_term.erase(@sync_state_key)
  rescue
    ArgumentError -> :ok
  end
end
