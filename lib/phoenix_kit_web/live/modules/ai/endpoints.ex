defmodule PhoenixKitWeb.Live.Modules.AI.Endpoints do
  @moduledoc """
  LiveView for AI endpoints management.

  This module provides a comprehensive interface for managing AI endpoints
  in PhoenixKit. Each endpoint is a unified configuration containing
  provider credentials, model selection, and generation parameters.

  ## Features

  - **Endpoint Management**: Add, edit, delete, enable/disable AI endpoints
  - **Usage Statistics**: View request history and token usage

  ## Route

  This LiveView is mounted at `{prefix}/admin/ai` and requires
  appropriate admin permissions.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.AI
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @sort_options [
    {:id, "ID"},
    {:name, "Name"},
    {:enabled, "Status"},
    {:model, "Model"},
    {:usage, "Requests"},
    {:tokens, "Tokens"},
    {:cost, "Cost"},
    {:last_used, "Last Used"}
  ]

  @page_size 20

  @impl true
  def mount(_params, session, socket) do
    current_path = get_current_path(socket, session)
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Subscribe to real-time updates
    if connected?(socket) do
      AI.subscribe_endpoints()
      AI.subscribe_requests()
    end

    # Check if we have any endpoints for initial tab selection
    {_endpoints, total} = AI.list_endpoints()
    has_endpoints = total > 0

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "AI Endpoints")
      |> assign(:project_title, project_title)
      |> assign(:endpoints, [])
      |> assign(:endpoint_stats, %{})
      |> assign(:has_endpoints, has_endpoints)
      |> assign(:sort_by, :id)
      |> assign(:sort_dir, :asc)
      |> assign(:sort_options, @sort_options)
      |> assign(:page, 1)
      |> assign(:page_size, @page_size)
      |> assign(:total_endpoints, 0)
      |> assign(:active_tab, if(has_endpoints, do: "endpoints", else: "setup"))
      |> assign(:usage_loaded, false)
      |> assign(:usage_stats, nil)
      |> assign(:usage_requests, [])
      |> assign(:usage_page, 1)
      |> assign(:usage_total_requests, 0)
      |> assign(:selected_request, nil)
      # Usage tab filters and sorting
      |> assign(:usage_sort_by, :inserted_at)
      |> assign(:usage_sort_dir, :desc)
      |> assign(:usage_filter_endpoint, nil)
      |> assign(:usage_filter_model, nil)
      |> assign(:usage_filter_status, nil)
      |> assign(:usage_filter_source, nil)
      |> assign(:usage_filter_date, "7d")
      |> assign(:usage_filter_options, %{endpoints: [], models: [], statuses: [], sources: []})

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    # Redirect /admin/ai to /admin/ai/endpoints
    if socket.assigns.live_action == :index do
      {:noreply,
       push_navigate(socket, to: Routes.ai_path() <> "/endpoints?sort=id&dir=asc", replace: true)}
    else
      # Determine active tab from live_action
      tab =
        case socket.assigns.live_action do
          :usage -> "usage"
          :endpoints -> "endpoints"
          _ -> "endpoints"
        end

      # Update current_path based on actual URI for proper nav highlighting
      current_path = URI.parse(uri).path

      socket =
        socket
        |> assign(:active_tab, tab)
        |> assign(:current_path, current_path)

      # Apply tab-specific params
      socket =
        case tab do
          "endpoints" ->
            {sort_by, sort_dir, page} = parse_sort_params(params)

            socket
            |> assign(:sort_by, sort_by)
            |> assign(:sort_dir, sort_dir)
            |> assign(:page, page)
            |> maybe_reload_endpoints(tab)

          "usage" ->
            {sort_by, sort_dir, filters} = parse_usage_params(params)

            socket
            |> assign(:usage_sort_by, sort_by)
            |> assign(:usage_sort_dir, sort_dir)
            |> assign(:usage_filter_endpoint, filters.endpoint)
            |> assign(:usage_filter_model, filters.model)
            |> assign(:usage_filter_status, filters.status)
            |> assign(:usage_filter_source, filters.source)
            |> assign(:usage_filter_date, filters.date)
            |> load_usage_data()

          _ ->
            socket
        end

      {:noreply, socket}
    end
  end

  @valid_sort_fields Enum.map(@sort_options, fn {field, _} -> Atom.to_string(field) end)

  defp parse_sort_params(params) do
    {
      parse_sort_field(params["sort"], @valid_sort_fields, :id),
      parse_sort_dir(params["dir"]),
      parse_page(params["page"])
    }
  end

  defp parse_sort_field(field, valid_fields, default) when is_binary(field) do
    if field in valid_fields, do: String.to_existing_atom(field), else: default
  end

  defp parse_sort_field(_, _valid_fields, default), do: default

  defp parse_sort_dir("asc"), do: :asc
  defp parse_sort_dir("desc"), do: :desc
  defp parse_sort_dir(_), do: :asc

  defp parse_page(nil), do: 1
  defp parse_page(""), do: 1

  defp parse_page(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  @valid_usage_sort_fields ~w(inserted_at endpoint_name model total_tokens latency_ms cost_cents status)

  defp parse_usage_params(params) do
    sort_by =
      case params["sort"] do
        field when is_binary(field) and field in @valid_usage_sort_fields ->
          String.to_existing_atom(field)

        _ ->
          :inserted_at
      end

    sort_dir =
      case params["dir"] do
        "asc" -> :asc
        "desc" -> :desc
        _ -> :desc
      end

    filters = %{
      endpoint: parse_integer_param(params["endpoint"]),
      model: parse_string_param(params["model"]),
      status: parse_string_param(params["status"]),
      source: parse_string_param(params["source"]),
      date: parse_date_filter(params["date"])
    }

    {sort_by, sort_dir, filters}
  end

  @valid_date_filters ~w(today 7d 30d all)

  defp parse_date_filter(nil), do: "7d"
  defp parse_date_filter(""), do: "7d"
  defp parse_date_filter(value) when value in @valid_date_filters, do: value
  defp parse_date_filter(_), do: "7d"

  defp parse_integer_param(nil), do: nil
  defp parse_integer_param(""), do: nil

  defp parse_integer_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_string_param(nil), do: nil
  defp parse_string_param(""), do: nil
  defp parse_string_param(value), do: value

  defp build_usage_url(sort_by, sort_dir, assigns) do
    # Only include date in URL if it's not the default
    date_param =
      if assigns[:usage_filter_date] != "7d", do: assigns[:usage_filter_date], else: nil

    params =
      [
        {"sort", Atom.to_string(sort_by)},
        {"dir", Atom.to_string(sort_dir)}
      ]
      |> maybe_add_url_param("endpoint", assigns[:usage_filter_endpoint])
      |> maybe_add_url_param("model", assigns[:usage_filter_model])
      |> maybe_add_url_param("status", assigns[:usage_filter_status])
      |> maybe_add_url_param("source", assigns[:usage_filter_source])
      |> maybe_add_url_param("date", date_param)

    query = URI.encode_query(params)
    Routes.ai_path() <> "/usage?#{query}"
  end

  defp maybe_add_url_param(params, _key, nil), do: params
  defp maybe_add_url_param(params, key, value), do: params ++ [{key, to_string(value)}]

  defp maybe_reload_endpoints(socket, "endpoints") do
    reload_endpoints(socket)
  end

  defp maybe_reload_endpoints(socket, _tab), do: socket

  # ===========================================
  # ENDPOINT ACTIONS
  # ===========================================

  @impl true
  def handle_event("toggle_endpoint", %{"id" => id}, socket) do
    endpoint = AI.get_endpoint!(String.to_integer(id))

    case AI.update_endpoint(endpoint, %{enabled: !endpoint.enabled}) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> reload_endpoints()
         |> put_flash(:info, "Endpoint #{if endpoint.enabled, do: "disabled", else: "enabled"}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update endpoint")}
    end
  end

  @impl true
  def handle_event("delete_endpoint", %{"id" => id}, socket) do
    endpoint = AI.get_endpoint!(String.to_integer(id))

    case AI.delete_endpoint(endpoint) do
      {:ok, _} ->
        socket = reload_endpoints(socket)

        {:noreply,
         socket
         |> assign(:has_endpoints, not Enum.empty?(socket.assigns.endpoints))
         |> put_flash(:info, "Endpoint deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete endpoint")}
    end
  end

  @impl true
  def handle_event("sort", %{"by" => field}, socket) do
    field = String.to_existing_atom(field)
    current_sort_by = socket.assigns.sort_by
    current_sort_dir = socket.assigns.sort_dir

    # Toggle direction if same field, otherwise default to desc
    sort_dir =
      if field == current_sort_by do
        if current_sort_dir == :asc, do: :desc, else: :asc
      else
        :desc
      end

    # Reset to page 1 when sorting changes, update URL with sort params
    path = Routes.ai_path() <> "/endpoints?sort=#{field}&dir=#{sort_dir}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("goto_page", %{"page" => page_str}, socket) do
    case Integer.parse(page_str) do
      {page, ""} when page > 0 ->
        sort_by = socket.assigns.sort_by
        sort_dir = socket.assigns.sort_dir

        path = build_endpoints_url(sort_by, sort_dir, page)
        {:noreply, push_patch(socket, to: path)}

      _ ->
        {:noreply, socket}
    end
  end

  # ===========================================
  # USAGE TAB
  # ===========================================

  @impl true
  def handle_event("load_more_requests", _params, socket) do
    page = socket.assigns.usage_page + 1

    opts =
      [
        page: page,
        page_size: 20,
        sort_by: socket.assigns.usage_sort_by,
        sort_dir: socket.assigns.usage_sort_dir
      ]
      |> maybe_add_filter(:endpoint_id, socket.assigns.usage_filter_endpoint)
      |> maybe_add_filter(:model, socket.assigns.usage_filter_model)
      |> maybe_add_filter(:status, socket.assigns.usage_filter_status)
      |> maybe_add_filter(:source, socket.assigns.usage_filter_source)
      |> maybe_add_filter(:since, date_filter_to_datetime(socket.assigns.usage_filter_date))

    {new_requests, _total} = AI.list_requests(opts)

    socket =
      socket
      |> assign(:usage_page, page)
      |> assign(:usage_requests, socket.assigns.usage_requests ++ new_requests)

    {:noreply, socket}
  end

  @impl true
  def handle_event("usage_sort", %{"by" => field}, socket) do
    field = String.to_existing_atom(field)
    current_sort_by = socket.assigns.usage_sort_by
    current_sort_dir = socket.assigns.usage_sort_dir

    sort_dir =
      if field == current_sort_by do
        if current_sort_dir == :asc, do: :desc, else: :asc
      else
        :desc
      end

    path = build_usage_url(field, sort_dir, socket.assigns)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("usage_filter", params, socket) do
    # Extract values with defaults (some fields may be hidden when < 2 options)
    endpoint = Map.get(params, "endpoint", "")
    model = Map.get(params, "model", "")
    status = Map.get(params, "status", "")
    source = Map.get(params, "source", "")
    date = Map.get(params, "date", "7d")

    # Build new assigns for URL generation
    new_assigns = %{
      usage_sort_by: socket.assigns.usage_sort_by,
      usage_sort_dir: socket.assigns.usage_sort_dir,
      usage_filter_endpoint: if(endpoint == "", do: nil, else: String.to_integer(endpoint)),
      usage_filter_model: if(model == "", do: nil, else: model),
      usage_filter_status: if(status == "", do: nil, else: status),
      usage_filter_source: if(source == "", do: nil, else: source),
      usage_filter_date: if(date == "", do: "7d", else: date)
    }

    path = build_usage_url(new_assigns.usage_sort_by, new_assigns.usage_sort_dir, new_assigns)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("clear_usage_filters", _params, socket) do
    path =
      build_usage_url(socket.assigns.usage_sort_by, socket.assigns.usage_sort_dir, %{
        usage_filter_endpoint: nil,
        usage_filter_model: nil,
        usage_filter_status: nil,
        usage_filter_source: nil,
        usage_filter_date: "7d"
      })

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("show_request_details", %{"id" => id}, socket) do
    request_id = String.to_integer(id)
    request = Enum.find(socket.assigns.usage_requests, fn r -> r.id == request_id end)

    {:noreply, assign(socket, :selected_request, request)}
  end

  @impl true
  def handle_event("close_request_details", _params, socket) do
    {:noreply, assign(socket, :selected_request, nil)}
  end

  # ===========================================
  # PUBSUB HANDLERS - Real-time updates
  # ===========================================

  @impl true
  def handle_info({event, _endpoint}, socket)
      when event in [:endpoint_created, :endpoint_updated, :endpoint_deleted] do
    # Reload endpoints list when any endpoint changes
    {:noreply, reload_endpoints(socket)}
  end

  @impl true
  def handle_info({:request_created, _request}, socket) do
    # Reload usage data if on usage tab
    socket =
      if socket.assigns.active_tab == "usage" do
        socket
        |> reload_usage_requests()
        |> update_usage_stats()
      else
        socket
      end

    {:noreply, socket}
  end

  # Catch-all for other PubSub messages
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ===========================================
  # PRIVATE HELPERS
  # ===========================================

  defp reload_endpoints(socket) do
    sort_by = socket.assigns.sort_by
    sort_dir = socket.assigns.sort_dir
    page = socket.assigns.page
    page_size = socket.assigns.page_size

    {endpoints, total} =
      AI.list_endpoints(
        sort_by: sort_by,
        sort_dir: sort_dir,
        page: page,
        page_size: page_size
      )

    endpoint_stats = AI.get_endpoint_usage_stats()

    socket
    |> assign(:endpoints, endpoints)
    |> assign(:endpoint_stats, endpoint_stats)
    |> assign(:total_endpoints, total)
    |> assign(:has_endpoints, total > 0)
  end

  defp build_endpoints_url(sort_by, sort_dir, page) do
    base = Routes.ai_path() <> "/endpoints?sort=#{sort_by}&dir=#{sort_dir}"

    if page > 1 do
      base <> "&page=#{page}"
    else
      base
    end
  end

  defp load_usage_data(socket) do
    # Only load stats and filter options on first load
    socket =
      if socket.assigns.usage_loaded do
        socket
      else
        stats = AI.get_dashboard_stats()
        filter_options = AI.get_request_filter_options()

        socket
        |> assign(:usage_loaded, true)
        |> assign(:usage_stats, stats)
        |> assign(:usage_filter_options, filter_options)
      end

    # Always reload requests with current filters/sort
    reload_usage_requests(socket)
  end

  defp reload_usage_requests(socket) do
    opts =
      [
        page: 1,
        page_size: 20,
        sort_by: socket.assigns.usage_sort_by,
        sort_dir: socket.assigns.usage_sort_dir
      ]
      |> maybe_add_filter(:endpoint_id, socket.assigns.usage_filter_endpoint)
      |> maybe_add_filter(:model, socket.assigns.usage_filter_model)
      |> maybe_add_filter(:status, socket.assigns.usage_filter_status)
      |> maybe_add_filter(:source, socket.assigns.usage_filter_source)
      |> maybe_add_filter(:since, date_filter_to_datetime(socket.assigns.usage_filter_date))

    {requests, total} = AI.list_requests(opts)

    socket
    |> assign(:usage_requests, requests)
    |> assign(:usage_total_requests, total)
    |> assign(:usage_page, 1)
  end

  defp update_usage_stats(socket) do
    stats = AI.get_dashboard_stats()
    filter_options = AI.get_request_filter_options()

    socket
    |> assign(:usage_stats, stats)
    |> assign(:usage_filter_options, filter_options)
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  # Convert date filter string to DateTime for the :since filter
  defp date_filter_to_datetime("today") do
    Date.utc_today()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp date_filter_to_datetime("7d") do
    DateTime.utc_now()
    |> DateTime.add(-7, :day)
  end

  defp date_filter_to_datetime("30d") do
    DateTime.utc_now()
    |> DateTime.add(-30, :day)
  end

  defp date_filter_to_datetime("all"), do: nil
  defp date_filter_to_datetime(_), do: nil

  defp get_current_path(socket, session) do
    case socket.assigns do
      %{__changed__: _, current_path: path} when is_binary(path) -> path
      _ -> session["current_path"] || Routes.ai_path()
    end
  end

  # Format bytes for display (used in request details modal)
  defp format_bytes(nil), do: "-"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(bytes) when bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"
end
