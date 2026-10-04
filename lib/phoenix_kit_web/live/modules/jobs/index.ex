defmodule PhoenixKitWeb.Live.Modules.Jobs.Index do
  @moduledoc """
  The Jobs page: three tabs.

    * **Runs** (the default) — job runs (`PhoenixKit.Jobs`): long background work
      with its state, progress and history, and the controls to pause, resume,
      cancel and retry it for those who may (`jobs.manage`). Live over PubSub.
    * **Queue** — Oban's own jobs, for debugging, with filtering by queue, state
      and worker.
    * **Scheduled** — one-shot tasks to run at a time.

  The tab, the Runs filters, the opened run and the page live in the query
  string, so any view is a link.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Jobs.Run

  # Filter (queue, state, worker) and page live in the query string — a
  # filtered list is a real URL: shareable, reload-proof, and Back returns to
  # the previous query instead of leaving the page. `filter_queue`,
  # `filter_state`, and `filter_worker` default to "all", which is therefore
  # what gets omitted from the URL.
  use PhoenixKitWeb.Live.UrlState,
    params: [
      active_tab: [default: "runs", url_key: "tab", in: ~w(runs queue scheduled)],
      run_state: [
        default: "all",
        url_key: "run_state",
        in: ~w(all active) ++ Run.states()
      ],
      run_module: [default: "all", url_key: "run_module"],
      selected_run_uuid: [default: "", url_key: "run"],
      filter_queue: [default: "all", url_key: "queue"],
      filter_state: [default: "all", url_key: "state"],
      filter_worker: [default: "all", url_key: "worker"],
      current_page: [default: 1, cast: :integer, min: 1, url_key: "page"]
    ],
    page_param: :current_page

  import Ecto.Query

  import PhoenixKitWeb.Live.Modules.Jobs.RunsComponents,
    only: [run_modal: 1, runs_table: 1, state_label: 1]

  alias PhoenixKit.Jobs
  alias PhoenixKit.Jobs.{Events, ObanStore, SweepWorker}
  alias PhoenixKit.ScheduledJobs.ScheduledJob
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Json
  alias PhoenixKit.Utils.Pagination
  alias PhoenixKit.Utils.Routes

  @per_page 25
  @refresh_interval 30_000

  def mount(_params, _session, socket) do
    project_title = Settings.get_project_title()

    if connected?(socket) do
      Process.send_after(self(), :refresh, @refresh_interval)
      Events.subscribe()
    end

    # :filter_queue, :filter_state, :filter_worker, and :current_page are
    # assigned from the query string by UrlState before mount/3 runs —
    # re-assigning them here would overwrite a shared link's state with the
    # defaults.
    socket =
      socket
      |> assign(:page_title, "Jobs")
      |> assign(:project_title, project_title)
      |> assign(:url_path, Routes.path("/admin/jobs"))
      |> assign(:hidden_workers, load_hidden_workers())
      |> assign(:per_page, @per_page)
      |> assign(:selected_job, nil)
      |> assign(:selected_scheduled_job, nil)
      |> assign(:runs, [])
      |> assign(:run_controls, %{})
      |> assign(:run_actors, %{})
      |> assign(:run_total, 0)
      |> assign(:selected_run, nil)
      |> assign(:selected_run_controls, [])
      |> assign(:run_history, [])
      |> assign(:run_modules, run_modules())
      |> assign(:sweeper_seen?, true)
      |> assign(:oban_available?, true)
      |> assign(:stalled_queues, [])
      |> load_stats()
      |> load_scheduled_jobs()

    {:ok, socket}
  end

  # The list is loaded here rather than in mount/3: UrlState calls this after
  # mount and on every change to the query string, so one code path serves the
  # first render, a shared link, and the Back button alike.
  #
  # Deliberately not annotated with @impl — a single @impl anywhere in a module
  # makes Elixir demand it on every other callback too, and this LiveView's
  # mount/handle_event/handle_info carry none.
  def handle_url_state(_state, socket) do
    socket |> load_jobs() |> load_runs() |> load_selected_run()
  end

  def handle_event("filter_queue", %{"queue" => queue}, socket) do
    {:noreply, push_url_state(socket, filter_queue: queue)}
  end

  def handle_event("filter_state", %{"state" => state}, socket) do
    {:noreply, push_url_state(socket, filter_state: state)}
  end

  def handle_event("filter_worker", %{"worker" => worker}, socket) do
    {:noreply, push_url_state(socket, filter_worker: worker)}
  end

  def handle_event("toggle_hide_worker", %{"worker" => worker}, socket) do
    hidden = socket.assigns.hidden_workers

    new_hidden =
      if worker in hidden do
        List.delete(hidden, worker)
      else
        [worker | hidden]
      end

    save_hidden_workers(new_hidden)

    # hidden_workers is settings-backed (not a URL param), so we reload the
    # list directly rather than routing through push_url_state.
    socket =
      socket
      |> assign(:hidden_workers, new_hidden)
      |> load_jobs()

    {:noreply, socket}
  end

  def handle_event("clear_hidden_workers", _params, socket) do
    save_hidden_workers([])

    socket =
      socket
      |> assign(:hidden_workers, [])
      |> load_jobs()

    {:noreply, socket}
  end

  def handle_event("change_page", %{"page" => page}, socket) do
    case Integer.parse(page) do
      {page, ""} when page > 0 -> {:noreply, push_url_state(socket, current_page: page)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("show_job", %{"id" => id}, socket) do
    job = load_job(String.to_integer(id))
    {:noreply, assign(socket, :selected_job, job)}
  end

  def handle_event("close_job", _params, socket) do
    {:noreply, assign(socket, :selected_job, nil)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_url_state(socket, active_tab: tab, selected_run_uuid: "")}
  end

  def handle_event("filter_run_state", %{"run_state" => state}, socket) do
    {:noreply, push_url_state(socket, run_state: state)}
  end

  def handle_event("filter_run_module", %{"run_module" => module}, socket) do
    {:noreply, push_url_state(socket, run_module: module)}
  end

  def handle_event("show_run", %{"uuid" => uuid}, socket) do
    {:noreply, push_url_state(socket, [selected_run_uuid: uuid], replace: true)}
  end

  def handle_event("close_run", _params, socket) do
    {:noreply, push_url_state(socket, [selected_run_uuid: ""], replace: true)}
  end

  # A control on a run. The check is `PhoenixKit.Jobs`'s, against this scope's
  # active role: the buttons are only shown to those who may, and a hand-made
  # event is refused all the same.
  def handle_event("run_control", %{"action" => action, "uuid" => uuid}, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    result =
      case action do
        "pause" -> Jobs.pause(scope, uuid)
        "resume" -> Jobs.resume(scope, uuid)
        "cancel" -> Jobs.cancel(scope, uuid)
        "retry" -> Jobs.retry(scope, uuid)
        _ -> {:error, :unknown_action}
      end

    socket =
      case result do
        {:error, reason} -> put_flash(socket, :error, control_error(reason))
        _ok -> socket
      end

    {:noreply, socket |> load_runs() |> load_selected_run()}
  end

  def handle_event("show_scheduled_job", %{"id" => id}, socket) do
    job = load_scheduled_job(id)
    {:noreply, assign(socket, :selected_scheduled_job, job)}
  end

  def handle_event("close_scheduled_job", _params, socket) do
    {:noreply, assign(socket, :selected_scheduled_job, nil)}
  end

  # A run moved (PhoenixKit.Jobs.Events, after its transaction committed).
  def handle_info({:job_run, _action, _run}, socket) do
    {:noreply, socket |> load_runs() |> load_selected_run()}
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)

    socket =
      socket
      |> load_jobs()
      |> load_runs()
      |> load_selected_run()
      |> load_stats()
      |> load_scheduled_jobs()

    {:noreply, socket}
  end

  defp load_runs(socket) do
    filters =
      [
        state: run_state_filter(socket.assigns.run_state),
        module: if(socket.assigns.run_module != "all", do: socket.assigns.run_module),
        limit: socket.assigns.per_page,
        offset: (socket.assigns.current_page - 1) * socket.assigns.per_page
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    runs = Jobs.list_runs(filters)
    scope = socket.assigns[:phoenix_kit_current_scope]

    socket
    |> assign(:runs, runs)
    |> assign(:run_total, Jobs.count_runs(Keyword.take(filters, [:state, :module])))
    |> assign(:run_controls, Map.new(runs, &{&1.uuid, Jobs.controls_for(scope, &1)}))
    |> assign(:run_actors, actors(runs))
    |> assign(:active_run_count, Jobs.count_runs(state: :active))
    |> assign(:sweeper_seen?, sweeper_seen?())
    |> assign(:stalled_queues, ObanStore.stalled_queues())
  end

  # The run the URL names, with its history and the people in it; nil when there
  # is none or it is gone.
  defp load_selected_run(socket) do
    run =
      case socket.assigns.selected_run_uuid do
        "" -> nil
        uuid -> Jobs.get_run(uuid)
      end

    history = if run, do: Jobs.history(run), else: []
    scope = socket.assigns[:phoenix_kit_current_scope]

    socket
    |> assign(:selected_run, run)
    |> assign(:run_history, history)
    |> assign(:selected_run_controls, if(run, do: Jobs.controls_for(scope, run), else: []))
    |> assign(:run_actors, Map.merge(socket.assigns.run_actors, actors(List.wrap(run), history)))
  end

  defp run_state_filter("all"), do: nil
  defp run_state_filter("active"), do: :active
  defp run_state_filter(state), do: state

  defp run_modules do
    Jobs.kinds() |> Enum.map(& &1.module_key()) |> Enum.uniq() |> Enum.sort()
  end

  # Who started and who acted, by email, in one query.
  defp actors(runs, history \\ []) do
    uuids =
      (Enum.flat_map(runs, &[&1.started_by_uuid, &1.paused_by_uuid, &1.cancelled_by_uuid]) ++
         Enum.map(history, & &1.actor_uuid))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if uuids == [] do
      %{}
    else
      repo = PhoenixKit.Config.get_repo()

      from(u in User, where: u.uuid in ^uuids, select: {u.uuid, u.email})
      |> repo.all()
      |> Map.new(fn {uuid, email} -> {to_string(uuid), email} end)
    end
  end

  # No pass of the sweeper for a while, while runs are waiting on it: the page says
  # so, because an orphaned run would otherwise sit looking alive. Judged over ALL
  # the runs the sweeper services (not this page of a filtered list, and not paused
  # runs, which it leaves alone), so no filter or page can hide the warning.
  @serviced_states ~w(queued running pausing cancelling)

  defp sweeper_seen? do
    if Jobs.count_runs(state: @serviced_states) > 0 do
      case DateTime.from_iso8601(Settings.get_setting(SweepWorker.last_sweep_setting(), "")) do
        {:ok, at, _} -> DateTime.diff(DateTime.utc_now(), at, :second) < 900
        _ -> false
      end
    else
      true
    end
  end

  defp control_error(:unauthorized), do: gettext("You may not do that.")

  defp control_error(:draining),
    do: gettext("The current batch is still finishing; try again in a moment.")

  defp control_error(:control_not_offered), do: gettext("This kind of job does not offer that.")
  defp control_error(:not_found), do: gettext("That job is gone.")

  defp control_error(reason)
       when reason in [
              :finished,
              :not_paused,
              :already_paused,
              :already_pausing,
              :already_cancelling,
              :cancelling,
              :not_retryable
            ],
       do: gettext("The job's state no longer allows that.")

  defp control_error(_reason), do: gettext("That did not work.")

  defp load_jobs(socket) do
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

    total_count = ObanStore.aggregate(query, :count)
    total_pages = Pagination.total_pages(total_count, per_page)

    jobs =
      query
      |> order_by([j], desc: j.inserted_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> ObanStore.all()

    socket
    |> assign(:jobs, jobs)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
  end

  defp load_job(id) do
    from(j in "oban_jobs",
      where: j.id == ^id,
      select: %{
        id: j.id,
        queue: j.queue,
        worker: j.worker,
        state: j.state,
        args: j.args,
        meta: j.meta,
        tags: j.tags,
        errors: j.errors,
        attempt: j.attempt,
        max_attempts: j.max_attempts,
        priority: j.priority,
        inserted_at: j.inserted_at,
        scheduled_at: j.scheduled_at,
        attempted_at: j.attempted_at,
        completed_at: j.completed_at,
        discarded_at: j.discarded_at,
        cancelled_at: j.cancelled_at
      }
    )
    |> ObanStore.one()
  end

  defp load_scheduled_jobs(socket) do
    repo = PhoenixKit.Config.get_repo()

    scheduled_jobs =
      from(j in ScheduledJob,
        order_by: [desc: j.inserted_at],
        limit: 50
      )
      |> repo.all()

    assign(socket, :scheduled_jobs, scheduled_jobs)
  end

  defp load_scheduled_job(id) do
    repo = PhoenixKit.Config.get_repo()
    repo.get(ScheduledJob, id)
  end

  defp load_stats(socket) do
    stats_query =
      from(j in "oban_jobs",
        group_by: [j.state],
        select: {j.state, count(j.id)}
      )

    stats =
      stats_query
      |> ObanStore.all()
      |> Enum.into(%{})

    queue_query =
      from(j in "oban_jobs",
        group_by: [j.queue],
        select: {j.queue, count(j.id)}
      )

    queues =
      queue_query
      |> ObanStore.all()
      |> Enum.into(%{})

    worker_query =
      from(j in "oban_jobs",
        group_by: [j.worker],
        select: {j.worker, count(j.id)}
      )

    workers =
      worker_query
      |> ObanStore.all()
      |> Enum.sort_by(fn {name, _} -> name end)

    socket
    |> assign(:oban_available?, ObanStore.available?())
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

  defp scheduled_job_badge_class(status) do
    case status do
      "pending" -> "badge-warning"
      # Claimed by a sweep and currently executing — same colour as Oban's
      # "executing" above, because it is the same phase of life.
      "processing" -> "badge-primary"
      "executed" -> "badge-success"
      "failed" -> "badge-error"
      "cancelled" -> "badge-ghost"
      _ -> "badge-ghost"
    end
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_json(nil), do: "-"

  defp format_json(data) when is_map(data) or is_list(data) do
    Json.encode_pretty!(data)
  end

  defp format_json(data), do: inspect(data)

  defp short_worker_name(worker) when is_binary(worker) do
    worker
    |> String.split(".")
    |> List.last()
  end

  defp short_worker_name(_), do: "-"
end
