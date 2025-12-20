defmodule PhoenixKitWeb.Live.Tickets.Tickets do
  @moduledoc """
  LiveView for displaying user's support tickets.

  Users can view only their own tickets with status filtering and pagination.
  This is the user-facing ticket portal, separate from admin ticket management.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKit.Tickets
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Tickets.enabled?() do
      current_user = socket.assigns[:phoenix_kit_current_user]

      socket =
        socket
        |> assign(:page_title, gettext("My Tickets"))
        |> assign(:current_user, current_user)
        |> assign(:tickets, [])
        |> assign(:total_count, 0)
        |> assign(:loading, true)
        |> assign_filter_defaults()
        |> assign_pagination_defaults()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Tickets module is not enabled"))
       |> push_navigate(to: Routes.path("/dashboard"))}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> assign(:url_path, URI.parse(uri).path)
      |> apply_params(params)
      |> load_user_tickets()

    {:noreply, assign(socket, :loading, false)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filter_params = %{}

    filter_params =
      case Map.get(params, "filters") do
        %{"status" => status} when status != "" ->
          Map.put(filter_params, "status", status)

        _ ->
          filter_params
      end

    {:noreply,
     push_patch(socket, to: Routes.path("/dashboard/tickets", map_to_keyword(filter_params)))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: Routes.path("/dashboard/tickets"))}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    page = String.to_integer(page)
    current_params = build_current_params(socket)
    params = Map.put(current_params, "page", page)

    {:noreply, push_patch(socket, to: Routes.path("/dashboard/tickets", map_to_keyword(params)))}
  end

  # Private functions

  defp assign_filter_defaults(socket) do
    assign(socket, :status_filter, nil)
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

    socket
    |> assign(:page, page)
    |> assign(:status_filter, status)
  end

  defp load_user_tickets(socket) do
    user_id = socket.assigns.current_user.id
    opts = build_query_opts(socket, user_id)

    # Get all tickets for counting, then paginate
    all_opts = Keyword.drop(opts, [:page, :per_page])
    all_tickets = Tickets.list_tickets(all_opts)
    total_count = length(all_tickets)

    # Apply pagination manually
    per_page = socket.assigns.per_page
    page = socket.assigns.page
    tickets = all_tickets |> Enum.drop((page - 1) * per_page) |> Enum.take(per_page)
    total_pages = max(1, ceil(total_count / per_page))

    socket
    |> assign(:tickets, tickets)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
  end

  defp build_query_opts(socket, user_id) do
    opts = [
      page: socket.assigns.page,
      per_page: socket.assigns.per_page,
      user_id: user_id,
      preload: [:assigned_to]
    ]

    case socket.assigns.status_filter do
      nil -> opts
      status -> Keyword.put(opts, :status, status)
    end
  end

  defp build_current_params(socket) do
    params = %{}

    if socket.assigns.status_filter,
      do: Map.put(params, "status", socket.assigns.status_filter),
      else: params
  end

  defp map_to_keyword(map) when is_map(map) do
    Enum.map(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end
end
