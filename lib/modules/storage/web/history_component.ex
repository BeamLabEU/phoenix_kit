defmodule PhoenixKitWeb.Live.Modules.Storage.HistoryComponent do
  @moduledoc """
  The History tab of Settings → Media: the Activity log, filtered to the storage
  module and global storage-setting entries, newest first — who changed which
  bucket, profile, library or size
  (`PhoenixKit.Modules.Storage.Audit`) and what the storage job runs did
  (`PhoenixKit.Jobs`). The full feed stays at `/admin/activity`; each row links to its
  entry there when the viewer has dashboard access.

  Loaded when the tab is opened, not with the page, and refreshed as storage entries
  arrive, and periodically while visible. Configuration entries are permanent;
  run entries follow `activity_retention_days`.
  """
  use PhoenixKitWeb, :live_component

  import Ecto.Query
  import PhoenixKitWeb.Components.Core.ActivityList, only: [activity_list: 1]

  alias PhoenixKit.Activity
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Modules.Storage.Audit
  alias PhoenixKit.Users.Auth.Scope

  @per_page 25
  @filters ~w(all changes runs)

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       active: false,
       loaded?: false,
       filter: "all",
       page: 1,
       result: nil,
       scope: nil
     )}
  end

  @impl true
  def update(%{reload: true}, socket),
    do: {:ok, if(socket.assigns.loaded?, do: load(socket), else: socket)}

  def update(assigns, socket) do
    was_active? = socket.assigns.active
    socket = assign(socket, assigns)

    # Nothing is read until the tab is first opened, and it is read afresh each time
    # it is opened again: entries made meanwhile were not announced to a closed tab.
    opened? = socket.assigns.active and not was_active?
    {:ok, if(opened?, do: load(socket), else: socket)}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) when filter in @filters do
    {:noreply, socket |> assign(filter: filter, page: 1) |> load()}
  end

  def handle_event("page", %{"page" => page}, socket) do
    case parse_page(page) do
      page when is_integer(page) and page > 0 ->
        last = if socket.assigns.result, do: max(1, socket.assigns.result.total_pages), else: 1
        {:noreply, socket |> assign(:page, min(page, last)) |> load()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} -> page
      _ -> nil
    end
  end

  defp parse_page(_value), do: nil

  defp load(socket) do
    result =
      Activity.list(
        query: history_query(socket.assigns.filter),
        page: socket.assigns.page,
        per_page: @per_page,
        preload: [:actor]
      )

    socket
    |> assign(:loaded?, true)
    |> assign(:result, result)
    |> clamp_page()
  end

  # Pruning can remove the last page while it is open.
  defp clamp_page(socket) do
    last = max(1, socket.assigns.result.total_pages)
    if socket.assigns.page > last, do: socket |> assign(:page, last) |> load(), else: socket
  end

  # Global storage settings already have permanent setting.changed entries; reuse
  # them rather than writing a second entry for the same change.
  defp history_query(filter) do
    query =
      from(e in Entry,
        where:
          e.module == ^Audit.module_key() or
            (e.action == "setting.changed" and
               fragment("left(?->>'key', 8) = 'storage_'", e.metadata))
      )

    case filter do
      "changes" ->
        from(e in query, where: like(e.action, "storage.%") or e.action == "setting.changed")

      "runs" ->
        from(e in query, where: e.resource_type == "job_run")

      _ ->
        query
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div class="card bg-base-100 shadow-xl mb-6 mt-6">
        <div class="card-body">
          <div class="flex flex-wrap justify-between items-center gap-2 mb-2">
            <h2 class="card-title text-lg">
              <.icon name="hero-clock" class="w-6 h-6 mr-2" /> {gettext("History")}
            </h2>
            <form id={"#{@id}-filter"} phx-change="filter" phx-target={@myself}>
              <.select
                id={"#{@id}-filter-select"}
                name="filter"
                value={@filter}
                class="select-sm"
                options={[
                  {gettext("Everything"), "all"},
                  {gettext("Settings changes"), "changes"},
                  {gettext("Job runs"), "runs"}
                ]}
              />
            </form>
          </div>

          <p class="text-sm text-base-content/70 mb-4">
            {gettext(
              "Who changed the storage settings, and what the background jobs did. Changes to buckets, profiles, libraries and sizes are kept permanently; job entries follow the activity retention."
            )}
          </p>

          <.activity_list
            :if={@result}
            id={"#{@id}-list"}
            entries={@result.entries}
            detail_links={not is_nil(@scope) and Scope.has_module_access?(@scope, "dashboard")}
            empty={gettext("Nothing recorded yet.")}
          />

          <div :if={@result && @result.total_pages > 1} class="flex justify-center gap-2 mt-4">
            <button
              type="button"
              class="btn btn-sm btn-outline"
              phx-click="page"
              phx-value-page={max(1, @page - 1)}
              phx-target={@myself}
              disabled={@page <= 1}
            >
              {gettext("Previous")}
            </button>
            <span class="btn btn-sm btn-ghost no-animation">
              {gettext("Page %{page} of %{pages}", page: @page, pages: @result.total_pages)}
            </span>
            <button
              type="button"
              class="btn btn-sm btn-outline"
              phx-click="page"
              phx-value-page={min(@result.total_pages, @page + 1)}
              phx-target={@myself}
              disabled={@page >= @result.total_pages}
            >
              {gettext("Next")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
