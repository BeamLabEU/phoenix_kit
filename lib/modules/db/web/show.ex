defmodule PhoenixKit.Modules.DB.Web.Show do
  @moduledoc """
  Table detail view with paginated row browsing.

  Supports live updates via PostgreSQL LISTEN/NOTIFY - when data in the
  viewed table changes, the view refreshes automatically.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.DB
  alias PhoenixKit.Modules.DB.Listener
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @default_per_page 20
  @allowed_per_page [10, 20, 50, 100, 200]

  @impl true
  def mount(%{"schema" => schema, "table" => table} = params, _session, socket) do
    locale = params["locale"] || Routes.get_default_admin_locale()
    page = parse_page(params["page"])
    per_page = parse_per_page(params["per_page"])

    # Set up live updates if connected
    if connected?(socket) do
      # Subscribe to changes for this table
      Listener.subscribe(schema, table)

      # Ensure the trigger is set up for this table
      DB.ensure_trigger(schema, table)
    end

    preview = DB.table_preview(schema, table, %{page: page, per_page: per_page})

    socket =
      socket
      |> assign(:page_title, "#{schema}.#{table}")
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:current_locale, locale)
      |> assign(
        :current_path,
        Routes.path("/admin/db/#{schema}/#{table}", locale: locale)
      )
      |> assign(:schema, schema)
      |> assign(:table, table)
      |> assign(:per_page, per_page)
      |> assign(:preview, preview)
      |> assign(:highlighted_rows, [])
      |> assign(:refresh_scheduled, false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])
    per_page = parse_per_page(params["per_page"])

    preview =
      DB.table_preview(
        socket.assigns.schema,
        socket.assigns.table,
        %{page: page, per_page: per_page}
      )

    {:noreply,
     socket
     |> assign(:per_page, per_page)
     |> assign(:preview, preview)}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    page = parse_page(page)
    {:noreply, push_patch(socket, to: build_path(socket, %{page: page}))}
  end

  @impl true
  def handle_event("set_per_page", %{"per_page" => per_page}, socket) do
    per_page = parse_per_page(per_page)
    # Recalculate page to keep roughly the same position
    current_row = (socket.assigns.preview.page - 1) * socket.assigns.per_page
    new_page = max(1, div(current_row, per_page) + 1)

    {:noreply, push_patch(socket, to: build_path(socket, %{per_page: per_page, page: new_page}))}
  end

  # Debounce interval for live updates (ms)
  @refresh_debounce_ms 1000

  # Handle live updates from PostgreSQL NOTIFY
  @impl true
  def handle_info({:table_changed, schema, table, _operation, _row_id}, socket) do
    # Only refresh if this is the table we're viewing
    if schema == socket.assigns.schema and table == socket.assigns.table do
      # Debounce: schedule a refresh instead of doing it immediately
      # This prevents hammering the database on very active tables
      socket = schedule_debounced_refresh(socket)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:debounced_refresh, socket) do
    # Clear the pending refresh flag and do the actual refresh
    socket = assign(socket, :refresh_scheduled, false)

    old_preview = socket.assigns.preview
    old_row_count = old_preview.row_count

    new_preview =
      DB.table_preview(socket.assigns.schema, socket.assigns.table, %{
        page: old_preview.page,
        per_page: socket.assigns.per_page
      })

    # Detect what changed
    {added_count, removed_count, changed_on_page} =
      detect_changes(old_preview.rows, new_preview.rows, old_row_count, new_preview.row_count)

    # Find which rows on current page are new/changed for highlighting
    highlighted_ids = find_new_or_changed_rows(old_preview.rows, new_preview.rows)

    # Build notification message
    socket = add_change_notification(socket, added_count, removed_count, changed_on_page)

    socket =
      socket
      |> assign(:preview, new_preview)
      |> assign(:highlighted_rows, highlighted_ids)

    # Schedule highlight removal after 3 seconds
    if highlighted_ids != [] do
      Process.send_after(self(), :clear_highlights, 3000)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:clear_highlights, socket) do
    {:noreply, assign(socket, :highlighted_rows, [])}
  end

  # Schedule a debounced refresh - only schedules if one isn't already pending
  defp schedule_debounced_refresh(socket) do
    if socket.assigns[:refresh_scheduled] do
      # Already scheduled, skip
      socket
    else
      Process.send_after(self(), :debounced_refresh, @refresh_debounce_ms)
      assign(socket, :refresh_scheduled, true)
    end
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

  # Parse and validate page number - must be positive integer
  defp parse_page(nil), do: 1
  defp parse_page(value) when is_integer(value) and value > 0, do: value

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  # Parse and validate per_page - must be one of the allowed values
  defp parse_per_page(nil), do: @default_per_page
  defp parse_per_page(value) when is_integer(value) and value in @allowed_per_page, do: value

  defp parse_per_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int in @allowed_per_page -> int
      _ -> @default_per_page
    end
  end

  defp parse_per_page(_), do: @default_per_page

  defp build_path(socket, overrides) do
    # Normalize overrides to string keys
    overrides = Map.new(overrides, fn {k, v} -> {to_string(k), v} end)

    params =
      %{
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
      Routes.path("/admin/db/#{socket.assigns.schema}/#{socket.assigns.table}",
        locale: socket.assigns.current_locale
      )

    if map_size(params) == 0 do
      base
    else
      base <> "?" <> URI.encode_query(params)
    end
  end

  # Detect overall changes between old and new data
  defp detect_changes(old_rows, new_rows, old_count, new_count) do
    added_count = max(0, new_count - old_count)
    removed_count = max(0, old_count - new_count)

    # Check if rows on current page changed
    changed_on_page = rows_changed_on_page?(old_rows, new_rows)

    {added_count, removed_count, changed_on_page}
  end

  defp rows_changed_on_page?(old_rows, new_rows) do
    # Simple comparison - if row count or content differs
    length(old_rows) != length(new_rows) or old_rows != new_rows
  end

  # Find rows that are new or changed on the current page
  # Returns list of row identifiers (using "id" column if available, or row index)
  defp find_new_or_changed_rows(old_rows, new_rows) do
    old_by_id = rows_by_identifier(old_rows)
    new_by_id = rows_by_identifier(new_rows)

    # Find new rows (in new but not in old)
    new_ids =
      new_by_id
      |> Map.keys()
      |> Enum.filter(fn id -> not Map.has_key?(old_by_id, id) end)

    # Find changed rows (same id but different content)
    changed_ids =
      new_by_id
      |> Enum.filter(fn {id, row} ->
        case Map.get(old_by_id, id) do
          nil -> false
          old_row -> old_row != row
        end
      end)
      |> Enum.map(fn {id, _} -> id end)

    new_ids ++ changed_ids
  end

  # Build a map of rows by their identifier (id column or stringified row)
  defp rows_by_identifier(rows) do
    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, idx} ->
      # Use "id" column if available, otherwise use index
      id = Map.get(row, "id") || Map.get(row, :id) || "idx_#{idx}"
      {id, row}
    end)
    |> Map.new()
  end

  # Add a flash notification about changes
  defp add_change_notification(socket, 0, 0, false), do: socket

  defp add_change_notification(socket, added, removed, changed_on_page) do
    messages = []

    messages =
      if added > 0 do
        messages ++ ["#{added} row#{if added > 1, do: "s", else: ""} added"]
      else
        messages
      end

    messages =
      if removed > 0 do
        messages ++ ["#{removed} row#{if removed > 1, do: "s", else: ""} removed"]
      else
        messages
      end

    messages =
      if changed_on_page and added == 0 and removed == 0 do
        messages ++ ["Data updated"]
      else
        messages
      end

    if messages != [] do
      put_flash(socket, :info, Enum.join(messages, ", "))
    else
      socket
    end
  end

  # Check if a row should be highlighted
  def row_highlighted?(row, highlighted_rows) do
    id = Map.get(row, "id") || Map.get(row, :id)
    id != nil and id in highlighted_rows
  end
end
