defmodule PhoenixKit.Modules.Tickets.Web.List do
  @moduledoc """
  LiveView for displaying and managing support tickets in PhoenixKit admin panel.

  Provides comprehensive ticket management interface with filtering, searching,
  and quick actions for the support ticketing system.

  ## Features

  - **Real-time Ticket List**: Live updates of tickets
  - **Status Filtering**: By open, in_progress, resolved, closed
  - **Assignment Filtering**: By handler, unassigned
  - **Search Functionality**: Search across titles and descriptions
  - **Pagination**: Handle large volumes of tickets
  - **Quick Actions**: View, assign, change status
  - **Statistics Summary**: Key metrics (open, in_progress, resolved, closed)

  ## Route

  This LiveView is mounted at `{prefix}/admin/tickets` and requires
  appropriate admin or SupportAgent permissions.

  ## Permissions

  Access is restricted to users with admin, owner, or SupportAgent roles.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Tickets
  alias PhoenixKit.Modules.Tickets.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if tickets_enabled?() do
      current_user = socket.assigns[:phoenix_kit_current_user]

      if can_access_tickets?(current_user) do
        # Subscribe to ticket events for real-time updates
        Events.subscribe_to_all()

        project_title = Settings.get_project_title()

        socket =
          socket
          |> assign(:page_title, "Support Tickets")
          |> assign(:project_title, project_title)
          |> assign(:current_user, current_user)
          |> assign(:tickets, [])
          |> assign(:total_count, 0)
          |> assign(:stats, Tickets.get_stats())
          |> assign(:loading, true)
          |> assign_filter_defaults()
          |> assign_pagination_defaults()

        {:ok, socket}
      else
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to the ticketing system")
         |> push_navigate(to: Routes.path("/admin"))}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Tickets module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> assign(:url_path, URI.parse(uri).path)
      |> apply_params(params)
      |> load_tickets()

    {:noreply, assign(socket, :loading, false)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filter_params = %{}

    filter_params =
      case Map.get(params, "search") do
        %{"query" => query} -> Map.put(filter_params, "search", String.trim(query || ""))
        _ -> filter_params
      end

    filter_params =
      case Map.get(params, "filters") do
        %{"status" => status} when status != "" ->
          Map.put(filter_params, "status", status)

        _ ->
          filter_params
      end

    filter_params =
      case Map.get(params, "filters") do
        %{"assigned_to" => assigned} when assigned != "" ->
          Map.put(filter_params, "assigned_to", assigned)

        _ ->
          filter_params
      end

    {:noreply,
     push_patch(socket, to: Routes.path("/admin/tickets", map_to_keyword(filter_params)))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: Routes.path("/admin/tickets"))}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    page = String.to_integer(page)
    current_params = build_current_params(socket)
    params = Map.put(current_params, "page", page)

    {:noreply, push_patch(socket, to: Routes.path("/admin/tickets", map_to_keyword(params)))}
  end

  @impl true
  def handle_info({:ticket_created, ticket}, socket) do
    # Prepend new ticket to list if it matches current filters
    socket =
      if ticket_matches_filters?(ticket, socket) do
        tickets = [ticket | socket.assigns.tickets]
        total_count = socket.assigns.total_count + 1

        socket
        |> assign(:tickets, tickets)
        |> assign(:total_count, total_count)
        |> assign(:stats, Tickets.get_stats())
      else
        # Just update stats if ticket doesn't match current filters
        assign(socket, :stats, Tickets.get_stats())
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:ticket_updated, ticket}, socket) do
    # Update ticket in list if present
    tickets =
      Enum.map(socket.assigns.tickets, fn t ->
        if t.id == ticket.id, do: ticket, else: t
      end)

    {:noreply, assign(socket, :tickets, tickets)}
  end

  @impl true
  def handle_info({:ticket_status_changed, ticket, _old_status, _new_status}, socket) do
    # Update ticket and stats
    tickets =
      Enum.map(socket.assigns.tickets, fn t ->
        if t.id == ticket.id, do: ticket, else: t
      end)

    socket =
      socket
      |> assign(:tickets, tickets)
      |> assign(:stats, Tickets.get_stats())

    {:noreply, socket}
  end

  @impl true
  def handle_info({:ticket_assigned, ticket, _old_assignee, _new_assignee}, socket) do
    # Update ticket in list
    tickets =
      Enum.map(socket.assigns.tickets, fn t ->
        if t.id == ticket.id, do: ticket, else: t
      end)

    {:noreply, assign(socket, :tickets, tickets)}
  end

  @impl true
  def handle_info({:tickets_bulk_updated, _tickets, _changes}, socket) do
    # Reload tickets and stats on bulk update
    socket =
      socket
      |> load_tickets()
      |> assign(:stats, Tickets.get_stats())

    {:noreply, socket}
  end

  # Private functions

  defp tickets_enabled? do
    Tickets.enabled?()
  end

  defp can_access_tickets?(nil), do: false

  defp can_access_tickets?(user) do
    Roles.user_has_role_owner?(user) or
      Roles.user_has_role_admin?(user) or
      Roles.user_has_role?(user, "SupportAgent")
  end

  defp assign_filter_defaults(socket) do
    socket
    |> assign(:status_filter, nil)
    |> assign(:assigned_to_filter, nil)
    |> assign(:search_query, nil)
  end

  defp assign_pagination_defaults(socket) do
    per_page = Settings.get_setting("tickets_per_page", "20") |> String.to_integer()

    socket
    |> assign(:page, 1)
    |> assign(:per_page, per_page)
    |> assign(:total_pages, 1)
  end

  defp apply_params(socket, params) do
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    status = Map.get(params, "status")
    assigned_to = Map.get(params, "assigned_to")
    search = Map.get(params, "search")

    socket
    |> assign(:page, page)
    |> assign(:status_filter, status)
    |> assign(:assigned_to_filter, assigned_to)
    |> assign(:search_query, search)
  end

  defp load_tickets(socket) do
    opts = build_query_opts(socket)
    tickets = Tickets.list_tickets(opts)

    total_count = count_filtered_tickets(socket)
    total_pages = max(1, ceil(total_count / socket.assigns.per_page))

    socket
    |> assign(:tickets, tickets)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
  end

  defp build_query_opts(socket) do
    opts = [
      page: socket.assigns.page,
      per_page: socket.assigns.per_page,
      preload: [:user, :assigned_to]
    ]

    opts =
      case socket.assigns.status_filter do
        nil -> opts
        status -> Keyword.put(opts, :status, status)
      end

    opts =
      case socket.assigns.assigned_to_filter do
        nil ->
          opts

        "unassigned" ->
          Keyword.put(opts, :assigned_to_id, nil)

        handler_id ->
          Keyword.put(opts, :assigned_to_id, String.to_integer(handler_id))
      end

    case socket.assigns.search_query do
      nil -> opts
      "" -> opts
      search -> Keyword.put(opts, :search, search)
    end
  end

  defp count_filtered_tickets(socket) do
    # For simplicity, count based on status filter only
    case socket.assigns.status_filter do
      nil -> Tickets.get_stats().total
      status -> Map.get(Tickets.get_stats(), String.to_atom(status), 0)
    end
  end

  defp build_current_params(socket) do
    params = %{}

    params =
      if socket.assigns.status_filter,
        do: Map.put(params, "status", socket.assigns.status_filter),
        else: params

    params =
      if socket.assigns.assigned_to_filter,
        do: Map.put(params, "assigned_to", socket.assigns.assigned_to_filter),
        else: params

    if socket.assigns.search_query,
      do: Map.put(params, "search", socket.assigns.search_query),
      else: params
  end

  defp map_to_keyword(map) when is_map(map) do
    Enum.map(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  defp ticket_matches_filters?(ticket, socket) do
    status_filter = socket.assigns.status_filter
    assigned_to_filter = socket.assigns.assigned_to_filter
    search_query = socket.assigns.search_query

    matches_status?(ticket, status_filter) and
      matches_assigned?(ticket, assigned_to_filter) and
      matches_search?(ticket, search_query)
  end

  defp matches_status?(_ticket, nil), do: true
  defp matches_status?(ticket, status), do: ticket.status == status

  defp matches_assigned?(_ticket, nil), do: true
  defp matches_assigned?(ticket, "unassigned"), do: is_nil(ticket.assigned_to_id)

  defp matches_assigned?(ticket, handler_id),
    do: ticket.assigned_to_id == String.to_integer(handler_id)

  defp matches_search?(_ticket, nil), do: true
  defp matches_search?(_ticket, ""), do: true

  defp matches_search?(ticket, query) do
    query = String.downcase(query)

    String.contains?(String.downcase(ticket.title || ""), query) or
      String.contains?(String.downcase(ticket.description || ""), query)
  end
end
