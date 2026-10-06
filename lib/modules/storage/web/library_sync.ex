defmodule PhoenixKitWeb.Live.Modules.Storage.LibrarySync do
  @moduledoc """
  A library's sync state in the admin: the badge, how many files are left, and
  the Check now / Pause / Resume controls, shared by the Libraries tab and the
  library page. The state itself is `Storage.LibraryState`.

  `run/4` does what a button asks; the permission check is the Jobs context's
  (`jobs.manage` and `media.manage`, against the active role), so a hand-made
  event is refused all the same, whoever the buttons were shown to.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Jobs
  alias PhoenixKit.Modules.Storage.Jobs.Reconcile
  alias PhoenixKit.Utils.Routes

  attr :state, :map, default: nil
  attr :uuid, :any, required: true
  attr :scope, :any, default: nil
  attr :target, :any, required: true

  def sync_cell(%{state: nil} = assigns), do: ~H""

  def sync_cell(assigns) do
    assigns =
      assigns
      |> assign(:controls, run_controls(assigns))
      |> assign(:can_check?, Jobs.can_start?(assigns.scope, Reconcile))

    ~H"""
    <div class="flex flex-col gap-1">
      <div class="flex items-center gap-2">
        <span class={["badge badge-sm", sync_badge(@state.state)]} data-sync-state={@state.state}>
          {sync_label(@state.state)}
        </span>
        <span :if={@state.state in [:syncing, :paused, :waiting]} class="text-xs text-base-content/60">
          {ngettext("%{count} file left", "%{count} files left", @state.out_of_date)}
        </span>
        <span :if={@state.state == :attention and @state.failing > 0} class="text-xs text-warning">
          {ngettext(
            "%{count} file could not be finished",
            "%{count} files could not be finished",
            @state.failing
          )}
        </span>
      </div>
      <div class="flex flex-wrap items-center gap-1">
        <button
          :if={:pause in @controls and @state.state == :syncing}
          type="button"
          class="btn btn-xs"
          phx-click="sync"
          phx-value-action="pause"
          phx-value-uuid={@uuid}
          phx-target={@target}
        >
          <.icon name="hero-pause" class="w-3 h-3" /> {gettext("Pause")}
        </button>
        <button
          :if={:resume in @controls and @state.state == :paused}
          type="button"
          class="btn btn-xs btn-primary"
          phx-click="sync"
          phx-value-action="resume"
          phx-value-uuid={@uuid}
          phx-target={@target}
        >
          <.icon name="hero-play" class="w-3 h-3" /> {gettext("Resume")}
        </button>
        <button
          :if={@can_check? and @state.state in [:up_to_date, :waiting, :attention]}
          type="button"
          class="btn btn-xs btn-ghost"
          phx-click="sync"
          phx-value-action="check"
          phx-value-uuid={@uuid}
          phx-target={@target}
        >
          <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Check now")}
        </button>
        <.link
          :if={@state.run}
          navigate={Routes.path("/admin/jobs") <> "?run=" <> to_string(@state.run.uuid)}
          class="link link-hover text-xs"
        >
          {gettext("Details")}
        </.link>
      </div>
    </div>
    """
  end

  defp run_controls(%{state: %{run: %{state: state} = run}, scope: scope})
       when state in ~w(queued running pausing paused cancelling),
       do: Jobs.controls_for(scope, run)

  defp run_controls(_assigns), do: []

  defp sync_badge(:up_to_date), do: "badge-success"
  defp sync_badge(:syncing), do: "badge-info"
  defp sync_badge(:paused), do: "badge-warning"
  defp sync_badge(:waiting), do: "badge-warning"
  defp sync_badge(:attention), do: "badge-error"

  # "Up to date" says the files carry their library's current revisions; it does not
  # verify that every object is still on its bucket (LibraryState).
  defp sync_label(:up_to_date), do: gettext("Up to date")
  defp sync_label(:syncing), do: gettext("Syncing")
  defp sync_label(:paused), do: gettext("Paused")
  defp sync_label(:waiting), do: gettext("Waiting")
  defp sync_label(:attention), do: gettext("Needs attention")

  @doc """
  Check now, Pause or Resume for the library `library_uuid`, whose current state
  is `state` (`LibraryState`). `{:ok, run}` or `{:error, reason}`.
  """
  @spec run(String.t(), term(), map() | nil, term()) :: {:ok, term()} | {:error, term()}
  def run("check", library_uuid, _state, scope) do
    case Jobs.start(scope, Reconcile, {"library", to_string(library_uuid)}) do
      {:ok, run, _how} -> {:ok, run}
      error -> error
    end
  end

  def run("pause", _library_uuid, state, scope), do: control(&Jobs.pause/2, state, scope)
  def run("resume", _library_uuid, state, scope), do: control(&Jobs.resume/2, state, scope)
  def run(_action, _library_uuid, _state, _scope), do: {:error, :unknown_action}

  defp control(fun, %{run: %{} = run}, scope), do: fun.(scope, run)
  defp control(_fun, _state, _scope), do: {:error, :not_found}

  @doc "A flash for a refused `run/4`."
  @spec error_message(term()) :: String.t()
  def error_message(:unauthorized), do: gettext("You may not do that.")

  def error_message(:draining),
    do: gettext("The current batch is still finishing; try again in a moment.")

  def error_message(_reason), do: gettext("That did not work.")
end
