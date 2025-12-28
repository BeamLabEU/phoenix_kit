defmodule PhoenixKitWeb.Live.Modules.Jobs.Index do
  @moduledoc """
  LiveView for viewing jobs.

  Provides a simple read-only view of all Oban jobs with filtering by queue and state.
  """

  use PhoenixKitWeb, :live_view

  import Ecto.Query

  alias PhoenixKit.Jobs, as: JobsModule
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @per_page 25
  @refresh_interval 30_000

  @impl true
  def mount(_params, _session, socket) do
    # Check if module is enabled
    unless JobsModule.enabled?() do
      {:ok,
       socket
       |> put_flash(:error, "Jobs module is not enabled. Enable it from the Modules page.")
       |> redirect(to: Routes.path("/admin/modules"))}
    else
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      if connected?(socket) do
        Process.send_after(self(), :refresh, @refresh_interval)
      end

      socket =
        socket
        |> assign(:page_title, "Jobs")
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/jobs"))
        |> assign(:filter_queue, "all")
        |> assign(:filter_state, "all")
        |> assign(:filter_worker, "all")
        |> assign(:hidden_workers, load_hidden_workers())
        |> assign(:current_page, 1)
        |> assign(:per_page, @per_page)
        |> load_stats()
        |> load_jobs()

      {:ok, socket}
    end
  end

  @impl true
  def handle_event("filter_queue", %{"queue" => queue}, socket) do
    socket =
      socket
      |> assign(:filter_queue, queue)
      |> assign(:current_page, 1)
      |> load_jobs()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_state", %{"state" => state}, socket) do
    socket =
      socket
      |> assign(:filter_state, state)
      |> assign(:current_page, 1)
      |> load_jobs()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_worker", %{"worker" => worker}, socket) do
    socket =
      socket
      |> assign(:filter_worker, worker)
      |> assign(:current_page, 1)
      |> load_jobs()

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_hide_worker", %{"worker" => worker}, socket) do
    hidden = socket.assigns.hidden_workers

    new_hidden =
      if worker in hidden do
        List.delete(hidden, worker)
      else
        [worker | hidden]
      end

    save_hidden_workers(new_hidden)

    socket =
      socket
      |> assign(:hidden_workers, new_hidden)
      |> assign(:current_page, 1)
      |> load_jobs()

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_hidden_workers", _params, socket) do
    save_hidden_workers([])

    socket =
      socket
      |> assign(:hidden_workers, [])
      |> assign(:current_page, 1)
      |> load_jobs()

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    page = String.to_integer(page)

    socket =
      socket
      |> assign(:current_page, page)
      |> load_jobs()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)

    socket =
      socket
      |> load_jobs()
      |> load_stats()

    {:noreply, socket}
  end

  defp load_jobs(socket) do
    repo = PhoenixKit.Config.get_repo()
    filter_queue = socket.assigns.filter_queue
    filter_state = socket.assigns.filter_state
    filter_worker = socket.assigns.filter_worker
    hidden_workers = socket.assigns.hidden_workers
    page = socket.assigns.current_page
    per_page = socket.assigns.per_page

    base_query =
      from(j in "oban_jobs",
        select: %{
          id: j.id,
          queue: j.queue,
          worker: j.worker,
          state: j.state,
          attempt: j.attempt,
          max_attempts: j.max_attempts,
          inserted_at: j.inserted_at,
          scheduled_at: j.scheduled_at,
          attempted_at: j.attempted_at,
          completed_at: j.completed_at
        }
      )

    query =
      base_query
      |> maybe_filter_queue(filter_queue)
      |> maybe_filter_state(filter_state)
      |> maybe_filter_worker(filter_worker)
      |> maybe_exclude_hidden_workers(hidden_workers, filter_worker)

    total_count = repo.aggregate(query, :count, :id)
    total_pages = max(1, ceil(total_count / per_page))

    jobs =
      query
      |> order_by([j], desc: j.inserted_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> repo.all()

    socket
    |> assign(:jobs, jobs)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
  end

  defp load_stats(socket) do
    repo = PhoenixKit.Config.get_repo()

    stats_query =
      from(j in "oban_jobs",
        group_by: [j.state],
        select: {j.state, count(j.id)}
      )

    stats =
      stats_query
      |> repo.all()
      |> Enum.into(%{})

    queue_query =
      from(j in "oban_jobs",
        group_by: [j.queue],
        select: {j.queue, count(j.id)}
      )

    queues =
      queue_query
      |> repo.all()
      |> Enum.into(%{})

    worker_query =
      from(j in "oban_jobs",
        group_by: [j.worker],
        select: {j.worker, count(j.id)}
      )

    workers =
      worker_query
      |> repo.all()
      |> Enum.sort_by(fn {name, _} -> name end)

    socket
    |> assign(:stats, stats)
    |> assign(:queue_stats, queues)
    |> assign(:worker_stats, workers)
  end

  defp maybe_filter_queue(query, "all"), do: query
  defp maybe_filter_queue(query, queue), do: where(query, [j], j.queue == ^queue)

  defp maybe_filter_state(query, "all"), do: query
  defp maybe_filter_state(query, state), do: where(query, [j], j.state == ^state)

  defp maybe_filter_worker(query, "all"), do: query
  defp maybe_filter_worker(query, worker), do: where(query, [j], j.worker == ^worker)

  # Only exclude hidden workers when viewing "all" workers
  defp maybe_exclude_hidden_workers(query, [], _filter_worker), do: query

  defp maybe_exclude_hidden_workers(query, _hidden, filter_worker) when filter_worker != "all",
    do: query

  defp maybe_exclude_hidden_workers(query, hidden_workers, "all") do
    where(query, [j], j.worker not in ^hidden_workers)
  end

  defp load_hidden_workers do
    Settings.get_setting("jobs_hidden_workers", "")
    |> String.split(",", trim: true)
  end

  defp save_hidden_workers(workers) do
    Settings.update_setting("jobs_hidden_workers", Enum.join(workers, ","))
  end

  defp state_badge_class(state) do
    case state do
      "completed" -> "badge-success"
      "available" -> "badge-info"
      "scheduled" -> "badge-warning"
      "executing" -> "badge-primary"
      "retryable" -> "badge-warning"
      "discarded" -> "badge-error"
      "cancelled" -> "badge-ghost"
      _ -> "badge-ghost"
    end
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp short_worker_name(worker) when is_binary(worker) do
    worker
    |> String.split(".")
    |> List.last()
  end

  defp short_worker_name(_), do: "-"
end
