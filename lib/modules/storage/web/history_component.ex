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
  import PhoenixKitWeb.Components.Core.RepairLog, only: [repair_log: 1]

  alias PhoenixKit.Activity
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Audit
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.RepairLog
  alias PhoenixKit.Users.Auth.Scope

  @per_page 25
  @filters ~w(all changes runs repairs)
  @repair_kinds ~w(damaged repaired)

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       active: false,
       loaded?: false,
       filter: "all",
       page: 1,
       result: nil,
       repairs: nil,
       repair_filter: %{library: "", bucket: "", kind: ""},
       library_options: [],
       bucket_options: [],
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
  def handle_event("filter", %{"filter" => filter} = params, socket) when filter in @filters do
    {:noreply,
     socket
     |> assign(filter: filter, page: 1, repair_filter: repair_filter(params))
     |> load()}
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

  # The library, bucket and kind selects of the damage-and-repairs view. They arrive
  # from the client: a uuid is cast, a kind is one of two.
  defp repair_filter(params) do
    %{
      library: cast_uuid(params["library"]),
      bucket: cast_uuid(params["bucket"]),
      kind: if(params["kind"] in @repair_kinds, do: params["kind"], else: "")
    }
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value || "") do
      {:ok, uuid} -> uuid
      :error -> ""
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp load(%{assigns: %{filter: "repairs"}} = socket) do
    f = socket.assigns.repair_filter

    repairs =
      RepairLog.list(
        page: socket.assigns.page,
        per_page: @per_page,
        library_uuid: blank_to_nil(f.library),
        bucket_uuid: blank_to_nil(f.bucket),
        kind: if(f.kind == "", do: nil, else: String.to_existing_atom(f.kind))
      )

    socket
    |> assign(:loaded?, true)
    |> assign(:repairs, repairs)
    |> assign(:result, %{entries: [], total_pages: repairs.total_pages})
    |> assign(:library_options, library_options())
    |> assign(:bucket_options, bucket_options())
    |> clamp_page()
  end

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

  defp library_options,
    do: [
      {gettext("All libraries"), ""}
      | Enum.map(Libraries.list_system_libraries(), &{&1.name, &1.uuid})
    ]

  defp bucket_options,
    do: [{gettext("All buckets"), ""} | Enum.map(Storage.list_buckets(), &{&1.name, &1.uuid})]

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
            <form
              id={"#{@id}-filter"}
              phx-change="filter"
              phx-target={@myself}
              class="flex flex-wrap items-center gap-2"
            >
              <.select
                :if={@filter == "repairs"}
                id={"#{@id}-filter-kind"}
                name="kind"
                value={@repair_filter.kind}
                class="select-sm"
                options={[
                  {gettext("Damaged and repaired"), ""},
                  {gettext("Damaged copies"), "damaged"},
                  {gettext("Repairs"), "repaired"}
                ]}
              />
              <.select
                :if={@filter == "repairs"}
                id={"#{@id}-filter-library"}
                name="library"
                value={@repair_filter.library}
                class="select-sm"
                options={@library_options}
              />
              <.select
                :if={@filter == "repairs"}
                id={"#{@id}-filter-bucket"}
                name="bucket"
                value={@repair_filter.bucket}
                class="select-sm"
                options={@bucket_options}
              />
              <.select
                id={"#{@id}-filter-select"}
                name="filter"
                value={@filter}
                class="select-sm"
                options={[
                  {gettext("Everything"), "all"},
                  {gettext("Settings changes"), "changes"},
                  {gettext("Job runs"), "runs"},
                  {gettext("Damage and repairs"), "repairs"}
                ]}
              />
            </form>
          </div>

          <p class="text-sm text-base-content/70 mb-4">
            {gettext(
              "Who changed the storage settings, and what the background jobs did. Changes to buckets, profiles, libraries and sizes are kept permanently; job entries follow the activity retention."
            )}
          </p>

          <.repair_log
            :if={@filter == "repairs" and @repairs}
            id={"#{@id}-repairs"}
            rows={@repairs.rows}
          />

          <.activity_list
            :if={@result && @filter != "repairs"}
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
