defmodule PhoenixKit.Modules.DB.Web.Index do
  @moduledoc """
  Admin DB index - lists all tables with stats.

  Supports live updates - when any table changes, the stats and
  table list are refreshed automatically.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.DB
  alias PhoenixKit.Modules.DB.Listener
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    locale = params["locale"] || Routes.get_default_admin_locale()
    page = parse_int(params["page"], 1)
    search = params["search"] || ""

    # Subscribe to all table changes for live updates
    if connected?(socket) do
      Listener.subscribe_all()
    end

    tables = DB.list_tables(%{page: page, search: search})

    socket =
      socket
      |> assign(:page_title, "DB")
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/db", locale: locale))
      |> assign(:search, search)
      |> assign(:tables, tables)
      |> assign(:stats, DB.database_stats())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_int(params["page"], 1)
    search = params["search"] || ""

    tables = DB.list_tables(%{page: page, search: search})

    {:noreply,
     socket
     |> assign(:search, search)
     |> assign(:tables, tables)}
  end

  @impl true
  def handle_event("search", %{"search" => value}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, %{search: value, page: 1}))}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, %{page: page}))}
  end

  # Debounce interval for live updates (ms)
  @refresh_debounce_ms 2000

  # Handle live updates from PostgreSQL NOTIFY
  @impl true
  def handle_info({:table_changed, _schema, _table, _operation, _row_id}, socket) do
    # Debounce: schedule a refresh instead of doing it immediately
    socket = schedule_debounced_refresh(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:debounced_refresh, socket) do
    # Clear the pending refresh flag and do the actual refresh
    socket = assign(socket, :refresh_scheduled, false)

    # Refresh tables list and stats
    tables =
      DB.list_tables(%{
        page: socket.assigns.tables.page,
        search: socket.assigns.search
      })

    socket =
      socket
      |> assign(:tables, tables)
      |> assign(:stats, DB.database_stats())

    {:noreply, socket}
  end

  # Schedule a debounced refresh - only schedules if one isn't already pending
  defp schedule_debounced_refresh(socket) do
    if socket.assigns[:refresh_scheduled] do
      socket
    else
      Process.send_after(self(), :debounced_refresh, @refresh_debounce_ms)
      assign(socket, :refresh_scheduled, true)
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_int(_, default), do: default

  defp build_path(socket, overrides) do
    # Normalize overrides to string keys
    overrides = Map.new(overrides, fn {k, v} -> {to_string(k), v} end)

    params =
      %{
        "search" => socket.assigns.search,
        "page" => socket.assigns.tables.page
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {_k, v} -> v in [nil, "", 1, "1"] end)
      |> Map.new()

    base = Routes.path("/admin/db", locale: socket.assigns.current_locale)

    if map_size(params) == 0 do
      base
    else
      base <> "?" <> URI.encode_query(params)
    end
  end
end
