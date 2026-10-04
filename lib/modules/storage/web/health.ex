defmodule PhoenixKitWeb.Live.Modules.Storage.Health do
  @moduledoc """
  Media health LiveView.

  Shows how many files are where, and what, their library's storage
  profile and variant set want (V205), and lists the ones the reconciler
  (`Storage.Workers.ReconcileJob`) has not brought up to date yet: copies
  missing or on buckets the profile no longer uses, sizes missing or made
  from an older spec. The reconciler runs by itself, a run per library
  (`Storage.Jobs.Reconcile`, watched on Admin → Jobs and on the Libraries tab);
  "Reconcile now" only starts those runs sooner.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Storage.Reconciler
  alias PhoenixKit.Modules.Storage.Workers.{LocationBackfillJob, ReconcileJob}
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # The stale files listed on the page; the count covers all of them.
  @listed 200

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale]

    socket =
      socket
      |> assign(:current_path, Routes.path("/admin/settings/media/health"))
      |> assign(:page_title, gettext("Health"))
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:current_locale, locale)
      |> assign(:url_path, Routes.path("/admin/settings/media/health"))
      |> load_health_report()

    {:ok, socket}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_health_report(socket)}
  end

  def handle_event("reconcile", _params, socket) do
    socket =
      case ReconcileJob.enqueue() do
        :queued ->
          put_flash(
            socket,
            :info,
            gettext("The reconciler is queued. Refresh to see its progress.")
          )

        :unavailable ->
          put_flash(socket, :error, gettext("The reconciler could not be queued."))
      end

    {:noreply, socket}
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

  defp waiting_for(%{placement: true, variants: true}), do: gettext("Copies and sizes")
  defp waiting_for(%{placement: true}), do: gettext("Copies")
  defp waiting_for(_item), do: gettext("Sizes")
end
