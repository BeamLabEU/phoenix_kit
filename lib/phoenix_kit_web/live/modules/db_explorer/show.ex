defmodule PhoenixKitWeb.Live.Modules.DBExplorer.Show do
  @moduledoc """
  Table detail view with paginated row browsing.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.DBExplorer
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @default_per_page 50

  @impl true
  def mount(%{"schema" => schema, "table" => table} = params, _session, socket) do
    locale = params["locale"] || Routes.get_default_admin_locale()
    page = parse_int(params["page"], 1)
    per_page = parse_int(params["per_page"], @default_per_page)
    search = params["search"] || ""

    preview =
      DBExplorer.table_preview(schema, table, %{page: page, per_page: per_page, search: search})

    socket =
      socket
      |> assign(:page_title, "#{schema}.#{table}")
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:current_locale, locale)
      |> assign(
        :current_path,
        Routes.path("/admin/db-explorer/#{schema}/#{table}", locale: locale)
      )
      |> assign(:schema, schema)
      |> assign(:table, table)
      |> assign(:search, search)
      |> assign(:per_page, per_page)
      |> assign(:preview, preview)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_int(params["page"], 1)
    per_page = parse_int(params["per_page"], socket.assigns[:per_page] || @default_per_page)
    search = params["search"] || ""

    preview =
      DBExplorer.table_preview(
        socket.assigns.schema,
        socket.assigns.table,
        %{page: page, per_page: per_page, search: search}
      )

    {:noreply,
     socket
     |> assign(:search, search)
     |> assign(:per_page, per_page)
     |> assign(:preview, preview)}
  end

  @impl true
  def handle_event("search", %{"search" => value}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, %{search: value, page: 1}))}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, %{page: page}))}
  end

  @impl true
  def handle_event("set_per_page", %{"per_page" => per_page}, socket) do
    per_page = parse_int(per_page, @default_per_page)
    # Recalculate page to keep roughly the same position
    current_row = (socket.assigns.preview.page - 1) * socket.assigns.per_page
    new_page = max(1, div(current_row, per_page) + 1)

    {:noreply, push_patch(socket, to: build_path(socket, %{per_page: per_page, page: new_page}))}
  end

  def format_bytes(nil), do: "0 B"
  def format_bytes(0), do: "0 B"
  def format_bytes(%Decimal{} = bytes), do: bytes |> Decimal.to_integer() |> format_bytes()
  def format_bytes(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1_048_576,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  def format_bytes(bytes) when is_integer(bytes),
    do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"

  def format_bytes(_), do: "0 B"

  def format_cell(value) when is_map(value), do: Jason.encode!(value)
  def format_cell(value) when is_list(value), do: inspect(value)
  def format_cell(value) when is_binary(value), do: value
  def format_cell(value), do: to_string(value || "")

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
        "page" => socket.assigns.preview.page,
        "per_page" => socket.assigns.per_page
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {k, v} ->
        v in [nil, ""] or
          (k == "page" and v in [1, "1"]) or
          (k == "per_page" and v in [@default_per_page, to_string(@default_per_page)])
      end)
      |> Map.new()

    base =
      Routes.path("/admin/db-explorer/#{socket.assigns.schema}/#{socket.assigns.table}",
        locale: socket.assigns.current_locale
      )

    if map_size(params) == 0 do
      base
    else
      base <> "?" <> URI.encode_query(params)
    end
  end
end
