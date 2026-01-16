defmodule PhoenixKit.Modules.Shop.Web.UserOrders do
  @moduledoc """
  LiveView for displaying user's shop orders.

  Users can view only their own orders with status filtering and pagination.
  This is the user-facing order portal, using the dashboard layout.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      current_user = socket.assigns[:phoenix_kit_current_user]

      socket =
        socket
        |> assign(:page_title, gettext("My Orders"))
        |> assign(:current_user, current_user)
        |> assign(:orders, [])
        |> assign(:total_count, 0)
        |> assign(:loading, true)
        |> assign_filter_defaults()
        |> assign_pagination_defaults()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/dashboard"))}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> assign(:url_path, URI.parse(uri).path)
      |> apply_params(params)
      |> load_user_orders()

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
     push_patch(socket, to: Routes.path("/dashboard/orders", map_to_keyword(filter_params)))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: Routes.path("/dashboard/orders"))}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    page = String.to_integer(page)
    current_params = build_current_params(socket)
    params = Map.put(current_params, "page", page)

    {:noreply, push_patch(socket, to: Routes.path("/dashboard/orders", map_to_keyword(params)))}
  end

  # Private functions

  defp assign_filter_defaults(socket) do
    assign(socket, :status_filter, nil)
  end

  defp assign_pagination_defaults(socket) do
    socket
    |> assign(:page, 1)
    |> assign(:per_page, 20)
    |> assign(:total_pages, 1)
  end

  defp apply_params(socket, params) do
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    status = Map.get(params, "status")

    socket
    |> assign(:page, page)
    |> assign(:status_filter, status)
  end

  defp load_user_orders(socket) do
    user_id = socket.assigns.current_user.id
    currency = Shop.get_default_currency()

    # Build filters for Billing.list_user_orders
    filters = build_query_filters(socket)
    all_orders = Billing.list_user_orders(user_id, filters)
    total_count = length(all_orders)

    # Apply pagination manually
    per_page = socket.assigns.per_page
    page = socket.assigns.page
    orders = all_orders |> Enum.drop((page - 1) * per_page) |> Enum.take(per_page)
    total_pages = max(1, ceil(total_count / per_page))

    socket
    |> assign(:orders, orders)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:currency, currency)
  end

  defp build_query_filters(socket) do
    filters = %{}

    case socket.assigns.status_filter do
      nil -> filters
      status -> Map.put(filters, :status, status)
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

  # View helpers

  defp status_badge_class("pending"), do: "badge-warning"
  defp status_badge_class("processing"), do: "badge-info"
  defp status_badge_class("completed"), do: "badge-success"
  defp status_badge_class("shipped"), do: "badge-info"
  defp status_badge_class("delivered"), do: "badge-success"
  defp status_badge_class("cancelled"), do: "badge-error"
  defp status_badge_class("refunded"), do: "badge-neutral"
  defp status_badge_class(_), do: "badge-ghost"

  defp format_date(nil), do: "-"

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%B %d, %Y")
  end

  defp format_date(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%B %d, %Y")
  end

  defp format_price(nil, _currency), do: "-"

  defp format_price(amount, %Currency{} = currency) do
    Currency.format_amount(amount, currency)
  end

  defp format_price(amount, nil) do
    "$#{Decimal.round(amount, 2)}"
  end

  defp items_count(nil), do: 0
  defp items_count([]), do: 0

  defp items_count(items) do
    items
    |> Enum.filter(&(&1["type"] != "shipping"))
    |> length()
  end
end
