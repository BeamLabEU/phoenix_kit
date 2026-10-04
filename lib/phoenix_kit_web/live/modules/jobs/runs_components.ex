defmodule PhoenixKitWeb.Live.Modules.Jobs.RunsComponents do
  @moduledoc """
  The pieces of the Runs tab of the Jobs page: the state badge, the progress bar,
  the table of runs with the controls each may be offered, and the drawer of one
  run with its history (`dev_docs/plans/2026-10-03-job-runs.md`, §5).

  Stateless: the LiveView passes the runs, the controls the viewer may use
  (`PhoenixKit.Jobs.controls_for/2`) and the people behind them.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Jobs.Run
  alias PhoenixKit.Utils.Json

  @doc "The state of a run as a badge; a draining run says so."
  attr :run, :map, required: true

  def state_badge(assigns) do
    ~H"""
    <span
      class={["badge badge-sm gap-1", state_class(@run.state)]}
      title={state_hint(@run)}
    >
      <span :if={@run.state == "running"} class="loading loading-spinner loading-xs"></span>
      {state_label(@run.state)}
    </span>
    """
  end

  @doc "How far a run is: a bar when the total is known, an indeterminate one while it runs, the counts either way."
  attr :run, :map, required: true

  def progress(assigns) do
    assigns = assign(assigns, :percent, Run.percent(assigns.run))

    ~H"""
    <div class="min-w-32">
      <progress
        :if={@percent}
        class={["progress w-full", progress_class(@run.state)]}
        value={@percent}
        max="100"
      ></progress>
      <progress
        :if={is_nil(@percent) and @run.state in ~w(queued running pausing cancelling)}
        class={["progress w-full", progress_class(@run.state)]}
      ></progress>
      <div class="text-xs text-base-content/60 mt-0.5">
        {counts(@run)}
      </div>
    </div>
    """
  end

  @doc "The runs, newest first, each with the controls the viewer may use."
  attr :runs, :list, required: true
  attr :controls, :map, required: true, doc: "run uuid => the controls to offer"
  attr :actors, :map, required: true, doc: "user uuid => email"

  def runs_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>{gettext("Job")}</th>
            <th>{gettext("State")}</th>
            <th>{gettext("Progress")}</th>
            <th>{gettext("Started")}</th>
            <th class="text-right">{gettext("Actions")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@runs == []}>
            <td colspan="5" class="text-center text-base-content/50 py-8">
              {gettext("No runs match.")}
            </td>
          </tr>
          <tr :for={run <- @runs} id={"run-#{run.uuid}"} class="hover">
            <td>
              <button
                type="button"
                class="link link-hover text-left font-medium"
                phx-click="show_run"
                phx-value-uuid={run.uuid}
              >
                {run.title}
              </button>
              <div class="text-xs text-base-content/50 font-mono">
                {run.kind}<span :if={run.scope_type}> · {scope_label(run)}</span>
              </div>
            </td>
            <td>
              <.state_badge run={run} />
              <div
                :if={run.state == "failed" and run.error}
                class="text-xs text-error mt-1 max-w-xs truncate"
                title={run.error}
              >
                {run.error}
              </div>
            </td>
            <td><.progress run={run} /></td>
            <td class="text-sm">
              <div>{format_time(run.inserted_at)}</div>
              <div class="text-xs text-base-content/50">{started_by(run, @actors)}</div>
            </td>
            <td class="text-right whitespace-nowrap">
              <.controls run={run} available={Map.get(@controls, run.uuid, [])} />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc "The control buttons of a run: only those the viewer may use now."
  attr :run, :map, required: true
  attr :available, :list, required: true

  def controls(assigns) do
    ~H"""
    <span class="join">
      <button
        :if={:pause in @available}
        type="button"
        class="btn btn-xs join-item"
        phx-click="run_control"
        phx-value-action="pause"
        phx-value-uuid={@run.uuid}
      >
        <.icon name="hero-pause" class="w-3 h-3" /> {gettext("Pause")}
      </button>
      <button
        :if={:resume in @available}
        type="button"
        class="btn btn-xs btn-primary join-item"
        phx-click="run_control"
        phx-value-action="resume"
        phx-value-uuid={@run.uuid}
      >
        <.icon name="hero-play" class="w-3 h-3" /> {gettext("Resume")}
      </button>
      <button
        :if={:retry in @available}
        type="button"
        class="btn btn-xs btn-primary join-item"
        phx-click="run_control"
        phx-value-action="retry"
        phx-value-uuid={@run.uuid}
      >
        <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Retry")}
      </button>
      <button
        :if={:cancel in @available}
        type="button"
        class="btn btn-xs btn-ghost text-error join-item"
        phx-click="run_control"
        phx-value-action="cancel"
        phx-value-uuid={@run.uuid}
        data-confirm={
          gettext("Cancel this job? A batch that is working finishes first, and what it did is kept.")
        }
      >
        <.icon name="hero-x-mark" class="w-3 h-3" /> {gettext("Cancel")}
      </button>
      <span
        :if={@run.state in ~w(pausing cancelling)}
        class="text-xs text-base-content/60 px-2 self-center"
      >
        {gettext("The current batch is finishing…")}
      </span>
    </span>
    """
  end

  @doc "One run in full: its facts, its error, and its history."
  attr :run, :map, required: true
  attr :history, :list, required: true
  attr :controls, :list, required: true
  attr :actors, :map, required: true

  def run_modal(assigns) do
    ~H"""
    <div class="modal modal-open" phx-window-keydown="close_run" phx-key="Escape">
      <div class="modal-box max-w-3xl max-h-[90vh] overflow-y-auto">
        <button
          type="button"
          class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
          phx-click="close_run"
        >
          ✕
        </button>

        <h3 class="font-bold text-lg flex items-center gap-2 pr-8">
          <span>{@run.title}</span>
          <.state_badge run={@run} />
        </h3>
        <p class="text-xs text-base-content/50 font-mono mb-4">{@run.kind} · {@run.uuid}</p>

        <.progress run={@run} />

        <p :if={@run.interruptions > 0} class="text-xs text-base-content/60 mt-1">
          {gettext(
            "A batch of this run stopped without finishing and was recovered; the counts may not include the work it did before it stopped."
          )}
        </p>

        <div class="grid grid-cols-2 md:grid-cols-3 gap-3 mt-4 text-sm">
          <.fact label={gettext("Scope")} value={scope_label(@run)} />
          <.fact label={gettext("Started by")} value={started_by(@run, @actors)} />
          <.fact label={gettext("Created")} value={format_time(@run.inserted_at)} />
          <.fact label={gettext("Began")} value={format_time(@run.started_at)} />
          <.fact label={gettext("Finished")} value={format_time(@run.finished_at)} />
          <.fact label={gettext("Duration")} value={duration(@run)} />
          <.fact label={gettext("Batches dispatched")} value={to_string(@run.generation)} />
          <.fact label={gettext("Rescues")} value={to_string(@run.rescues)} />
          <.fact
            label={gettext("Last sign of life")}
            value={format_time(@run.heartbeat_at || @run.updated_at)}
          />
        </div>

        <div :if={@run.error} class="alert alert-error mt-4 text-sm items-start">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
          <span class="whitespace-pre-wrap break-words">{@run.error}</span>
        </div>

        <div :if={@run.result not in [nil, %{}]} class="collapse collapse-arrow bg-base-200 mt-4">
          <input type="checkbox" />
          <div class="collapse-title font-semibold text-sm">{gettext("Result")}</div>
          <div class="collapse-content">
            <pre class="text-xs bg-base-300 p-3 rounded overflow-x-auto"><code>{json(@run.result)}</code></pre>
          </div>
        </div>

        <div :if={@run.args not in [nil, %{}]} class="collapse collapse-arrow bg-base-200 mt-2">
          <input type="checkbox" />
          <div class="collapse-title font-semibold text-sm">{gettext("Arguments")}</div>
          <div class="collapse-content">
            <pre class="text-xs bg-base-300 p-3 rounded overflow-x-auto"><code>{json(@run.args)}</code></pre>
          </div>
        </div>

        <h4 class="font-semibold mt-6 mb-2">{gettext("History")}</h4>
        <ul class="timeline timeline-vertical timeline-compact timeline-snap-icon">
          <li :if={@history == []} class="text-sm text-base-content/50">
            {gettext("Nothing recorded yet.")}
          </li>
          <li :for={entry <- @history}>
            <div class="timeline-middle">
              <.icon name="hero-clock" class="w-4 h-4 text-base-content/40" />
            </div>
            <div class="timeline-end timeline-box text-sm">
              <span class="font-medium">{action_label(entry.action)}</span>
              <span class="text-base-content/60">
                · {format_time(entry.inserted_at)} · {entry_actor(entry, @actors)}
              </span>
            </div>
            <hr />
          </li>
        </ul>

        <div class="modal-action">
          <.controls run={@run} available={@controls} />
          <button type="button" class="btn" phx-click="close_run">{gettext("Close")}</button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_run"></div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp fact(assigns) do
    ~H"""
    <div>
      <div class="text-xs text-base-content/50">{@label}</div>
      <div class="font-medium break-words">{@value}</div>
    </div>
    """
  end

  # ---- words ---------------------------------------------------------------

  def state_label("queued"), do: gettext("Queued")
  def state_label("running"), do: gettext("Running")
  def state_label("pausing"), do: gettext("Pausing…")
  def state_label("paused"), do: gettext("Paused")
  def state_label("cancelling"), do: gettext("Cancelling…")
  def state_label("completed"), do: gettext("Completed")
  def state_label("failed"), do: gettext("Failed")
  def state_label("cancelled"), do: gettext("Cancelled")
  def state_label(other), do: other

  defp state_class("queued"), do: "badge-info"
  defp state_class("running"), do: "badge-primary"
  defp state_class(state) when state in ~w(pausing paused cancelling), do: "badge-warning"
  defp state_class("completed"), do: "badge-success"
  defp state_class("failed"), do: "badge-error"
  defp state_class(_state), do: "badge-ghost"

  defp progress_class("paused"), do: "progress-warning"
  defp progress_class("failed"), do: "progress-error"
  defp progress_class("completed"), do: "progress-success"
  defp progress_class(_state), do: "progress-primary"

  defp state_hint(%{state: "pausing"}),
    do: gettext("Pause requested — the current batch is finishing")

  defp state_hint(%{state: "cancelling"}),
    do: gettext("Cancel requested — the current batch is finishing")

  defp state_hint(_run), do: nil

  defp counts(%{done: done, failed_count: failed, total: total}) do
    base = if total, do: "#{done} / #{total}", else: "#{done}"
    if failed > 0, do: base <> " · " <> gettext("%{count} failed", count: failed), else: base
  end

  defp scope_label(%{scope_type: nil}), do: gettext("Site")

  defp scope_label(%{scope_type: type, scope_uuid: uuid}),
    do: "#{type} #{String.slice(to_string(uuid), 0, 8)}"

  defp started_by(%{started_by_uuid: nil, mode: mode}, _actors), do: mode_label(mode)

  defp started_by(%{started_by_uuid: uuid}, actors),
    do: Map.get(actors, to_string(uuid), gettext("a user"))

  defp mode_label("auto"), do: gettext("automatically")
  defp mode_label("cron"), do: gettext("by schedule")
  defp mode_label("script"), do: gettext("by a script")
  defp mode_label(_manual), do: gettext("manually")

  defp entry_actor(%{actor_uuid: nil, mode: mode}, _actors), do: mode_label(mode)

  defp entry_actor(%{actor_uuid: uuid}, actors),
    do: Map.get(actors, to_string(uuid), gettext("a user"))

  defp action_label("job.started"), do: gettext("Started")
  defp action_label("job.pause_requested"), do: gettext("Pause requested")
  defp action_label("job.paused"), do: gettext("Paused")
  defp action_label("job.resumed"), do: gettext("Resumed")
  defp action_label("job.cancel_requested"), do: gettext("Cancel requested")
  defp action_label("job.cancelled"), do: gettext("Cancelled")
  defp action_label("job.completed"), do: gettext("Completed")
  defp action_label("job.failed"), do: gettext("Failed")
  defp action_label("job.restarted"), do: gettext("Started a fresh pass")
  defp action_label("job.rescued"), do: gettext("Rescued by the sweeper")
  defp action_label(other), do: other

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M:%S")
  defp format_time(%NaiveDateTime{} = time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M:%S")

  defp duration(%{started_at: nil}), do: "—"

  defp duration(%{started_at: started, finished_at: finished}) do
    seconds = DateTime.diff(finished || DateTime.utc_now(), started, :second)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

  defp json(data), do: Json.encode_pretty!(data)
end
