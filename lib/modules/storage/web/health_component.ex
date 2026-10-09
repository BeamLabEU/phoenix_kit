defmodule PhoenixKitWeb.Live.Modules.Storage.HealthComponent do
  @moduledoc """
  The Health tab of Settings → Media.

  Shows how many files are where, and what, their library's storage
  profile and rendition profile want (V205), and lists the ones the reconciler
  (`Storage.Workers.ReconcileJob`) has not brought up to date yet: copies
  missing or on buckets the profile no longer uses, renditions missing or made
  from an older spec. The reconciler runs by itself, a run per library
  (`Storage.Jobs.Reconcile`, watched on Admin → Jobs and on the Libraries tab);
  "Reconcile now" only starts those runs sooner.

  The report counts every file, so it is read when the tab is opened (and on
  Refresh), not when the settings page loads.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Modules.Storage.Reconciler
  alias PhoenixKit.Modules.Storage.Workers.{LocationBackfillJob, ReconcileJob}

  # The stale files listed on the page; the count covers all of them.
  @listed 200

  @impl true
  def mount(socket), do: {:ok, assign(socket, active: false, report: nil)}

  @impl true
  def update(assigns, socket) do
    was_active = socket.assigns.active
    socket = assign(socket, assigns)

    if socket.assigns.active and (not was_active or is_nil(socket.assigns.report)),
      do: {:ok, load_health_report(socket)},
      else: {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_health_report(socket)}
  end

  def handle_event("reconcile", _params, socket) do
    socket =
      case ReconcileJob.enqueue() do
        :queued ->
          flash(socket, :info, gettext("The reconciler is queued. Refresh to see its progress."))

        :unavailable ->
          flash(socket, :error, gettext("The reconciler could not be queued."))
      end

    {:noreply, socket}
  end

  # The tab has no flash of its own: the settings page puts it.
  defp flash(socket, kind, message) do
    send(self(), {__MODULE__, {:flash, kind, message}})
    socket
  end

  defp load_health_report(socket) do
    total = Reconciler.total_count()
    stale = Reconciler.stale_count()
    healthy = max(total - stale, 0)

    socket
    |> assign(:report, %{
      total: total,
      stale: stale,
      healthy: healthy,
      health_percentage: if(total > 0, do: Float.round(healthy / total * 100, 1), else: 100.0)
    })
    |> assign(:stale_files, if(stale > 0, do: Reconciler.stale_files(@listed), else: []))
    |> assign(:listed, @listed)
    # Stored objects with no location row yet (V204): the background
    # backfill is finding them; they are served meanwhile by checking the
    # buckets, and the reconciler leaves them alone until then.
    |> assign(:unlocated, LocationBackfillJob.pending_count())
  end

  defp waiting_for(%{placement: true, variants: true}), do: gettext("Copies and renditions")
  defp waiting_for(%{placement: true}), do: gettext("Copies")
  defp waiting_for(_item), do: gettext("Renditions")

  @impl true
  def render(%{report: nil} = assigns) do
    ~H"""
    <div id={@id}></div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id={@id} class="px-1 py-4">
      <div :if={@unlocated > 0} id={"#{@id}-unlocated"} class="alert alert-info mb-6">
        <.icon name="hero-map-pin" class="w-5 h-5" />
        <span>
          {ngettext(
            "%{count} stored object has no recorded location yet. It is being found in the background, and is served meanwhile.",
            "%{count} stored objects have no recorded location yet. They are being found in the background, and are served meanwhile.",
            @unlocated
          )}
        </span>
      </div>
      <%!-- Stats --%>
      <div class="stats stats-vertical lg:stats-horizontal shadow w-full mb-6">
        <div class="stat">
          <div class="stat-figure text-primary">
            <.icon name="hero-document-duplicate" class="w-8 h-8" />
          </div>
          <div class="stat-title">{gettext("Total Files")}</div>
          <div class="stat-value text-2xl">{@report.total}</div>
          <div class="stat-desc">{gettext("Active and in the trash")}</div>
        </div>

        <div class="stat">
          <div class="stat-figure text-success">
            <.icon name="hero-check-circle" class="w-8 h-8" />
          </div>
          <div class="stat-title">{gettext("Up to date")}</div>
          <div class="stat-value text-2xl text-success">{@report.healthy}</div>
          <div class="stat-desc">{gettext("Stored as their library wants, with its renditions")}</div>
        </div>

        <div class="stat">
          <div class="stat-figure text-warning">
            <.icon name="hero-arrow-path" class="w-8 h-8" />
          </div>
          <div class="stat-title">{gettext("Waiting")}</div>
          <div class="stat-value text-2xl text-warning">{@report.stale}</div>
          <div class="stat-desc">{gettext("For the reconciler")}</div>
        </div>

        <div class="stat">
          <div class={"stat-figure #{if @report.health_percentage == 100.0, do: "text-success", else: "text-warning"}"}>
            <.icon name="hero-heart" class="w-8 h-8" />
          </div>
          <div class="stat-title">{gettext("Health")}</div>
          <div class={"stat-value text-2xl #{if @report.health_percentage == 100.0, do: "text-success", else: "text-warning"}"}>
            {@report.health_percentage}%
          </div>
        </div>
      </div>

      <p id={"#{@id}-privacy"} class="text-sm text-base-content/60 mb-4">
        {gettext("Personal-library files are counted but not listed here.")}
      </p>

      <%!-- Actions --%>
      <div class="flex justify-end gap-2 mb-4">
        <.pk_link
          id={"#{@id}-runs"}
          navigate="/admin/jobs?run_module=storage"
          class="btn btn-outline btn-sm"
        >
          <.icon name="hero-queue-list" class="w-4 h-4" /> {gettext("Storage runs")}
        </.pk_link>
        <button
          :if={@report.stale > 0}
          id={"#{@id}-reconcile"}
          phx-click="reconcile"
          phx-target={@myself}
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-arrow-path-rounded-square" class="w-4 h-4" />
          {gettext("Reconcile now")}
        </button>
        <button phx-click="refresh" phx-target={@myself} class="btn btn-outline btn-sm">
          <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext("Refresh")}
        </button>
      </div>

      <%!-- Results --%>
      <%= if @report.stale == 0 do %>
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body items-center text-center py-12">
            <.icon name="hero-check-circle" class="w-16 h-16 text-success mb-4" />
            <h3 class="text-xl font-bold text-success">{gettext("All Healthy")}</h3>
            <p class="text-base-content/60">
              {gettext(
                "Every file is stored where its library's storage profile wants it, with the renditions of its rendition profile."
              )}
            </p>
          </div>
        </div>
      <% else %>
        <p class="text-sm text-base-content/60 mb-2">
          {gettext(
            "The reconciler copies files to the buckets their library's storage profile uses, removes copies it no longer uses, and makes the renditions its rendition profile lists. It runs by itself; a file stays here while something could not be done yet, and is tried again."
          )}
        </p>
        <p :if={@report.stale > @listed} class="text-sm text-base-content/60 mb-2">
          {gettext("Showing the first %{count} of %{total}.", count: @listed, total: @report.stale)}
        </p>
        <.table_default
          :if={@stale_files != []}
          id={"#{@id}-table"}
          variant="zebra"
          toggleable={true}
          items={@stale_files}
          card_title={fn item -> item.original_file_name end}
          card_fields={
            fn item ->
              [
                %{label: gettext("Library"), value: item.library_name},
                %{label: gettext("Type"), value: item.file_type},
                %{label: gettext("Waiting for"), value: waiting_for(item)}
              ]
            end
          }
        >
          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell>{gettext("File")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Library")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Type")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Waiting for")}</.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>
          <.table_default_body>
            <%= for item <- @stale_files do %>
              <.table_default_row>
                <.table_default_cell>
                  <.link
                    navigate={PhoenixKit.Utils.Routes.path("/admin/media/#{item.file_uuid}/storage")}
                    class="font-bold link link-hover link-primary"
                  >
                    {item.original_file_name}
                  </.link>
                </.table_default_cell>
                <.table_default_cell>{item.library_name}</.table_default_cell>
                <.table_default_cell>
                  <span class="badge badge-ghost badge-sm h-auto">{item.file_type}</span>
                </.table_default_cell>
                <.table_default_cell>
                  <span class="badge badge-warning badge-sm h-auto">{waiting_for(item)}</span>
                </.table_default_cell>
              </.table_default_row>
            <% end %>
          </.table_default_body>
        </.table_default>
      <% end %>
    </div>
    """
  end
end
