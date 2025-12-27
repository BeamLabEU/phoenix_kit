defmodule PhoenixKitWeb.Live.Modules.Jobs.Index do
  @moduledoc """
  LiveView for viewing background jobs.

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
       |> put_flash(:error, "Background Jobs module is not enabled. Enable it from the Modules page.")
       |> redirect(to: Routes.path("/admin/modules"))}
    else
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      if connected?(socket) do
        Process.send_after(self(), :refresh, @refresh_interval)
      end

      socket =
        socket
        |> assign(:page_title, "Background Jobs")
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/jobs"))
        |> assign(:filter_queue, "all")
        |> assign(:filter_state, "all")
        |> assign(:current_page, 1)
        |> assign(:per_page, @per_page)
        |> load_jobs()
        |> load_stats()

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
    page = socket.assigns.current_page
    per_page = socket.assigns.per_page

    base_query = from(j in "oban_jobs", select: %{
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
    })

    query =
      base_query
      |> maybe_filter_queue(filter_queue)
      |> maybe_filter_state(filter_state)

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

    stats_query = from(j in "oban_jobs",
      group_by: [j.state],
      select: {j.state, count(j.id)}
    )

    stats =
      stats_query
      |> repo.all()
      |> Enum.into(%{})

    queue_query = from(j in "oban_jobs",
      group_by: [j.queue],
      select: {j.queue, count(j.id)}
    )

    queues =
      queue_query
      |> repo.all()
      |> Enum.into(%{})

    socket
    |> assign(:stats, stats)
    |> assign(:queue_stats, queues)
  end

  defp maybe_filter_queue(query, "all"), do: query
  defp maybe_filter_queue(query, queue), do: where(query, [j], j.queue == ^queue)

  defp maybe_filter_state(query, "all"), do: query
  defp maybe_filter_state(query, state), do: where(query, [j], j.state == ^state)

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
