defmodule PhoenixKit.Modules.Shop.Web.MyOrders do
  @moduledoc """
  User's orders page - view order history.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    # Get user from current scope
    user =
      case socket.assigns[:phoenix_kit_current_scope] do
        %{user: %{id: _} = u} -> u
        _ -> nil
      end

    if is_nil(user) do
      {:ok,
       socket
       |> put_flash(:error, "Please log in to view your orders")
       |> push_navigate(to: Routes.path("/phoenix_kit/users/log-in"))}
    else
      orders = Billing.list_user_orders(user.id)
      currency = Shop.get_default_currency()

      socket =
        socket
        |> assign(:page_title, "My Orders")
        |> assign(:orders, orders)
        |> assign(:currency, currency)

      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      current_path={@url_path}
      current_locale={@current_locale}
      page_title={@page_title}
    >
      <div class="p-6 max-w-4xl mx-auto">
        <h1 class="text-3xl font-bold mb-8">My Orders</h1>

        <%= if Enum.empty?(@orders) do %>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body text-center py-16">
              <.icon name="hero-shopping-bag" class="w-16 h-16 mx-auto mb-4 opacity-30" />
              <h2 class="text-xl font-medium text-base-content/60">No orders yet</h2>
              <p class="text-base-content/50 mb-6">Start shopping to see your orders here</p>
              <.link navigate={Routes.path("/shop")} class="btn btn-primary">
                Browse Products
              </.link>
            </div>
          </div>
        <% else %>
          <div class="space-y-4">
            <%= for order <- @orders do %>
              <div class="card bg-base-100 shadow-lg">
                <div class="card-body">
                  <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
                    <div>
                      <div class="flex items-center gap-3">
                        <span class="font-mono font-bold text-lg">{order.order_number}</span>
                        <span class={"badge #{status_badge_class(order.status)} capitalize"}>
                          {order.status}
                        </span>
                      </div>
                      <div class="text-sm text-base-content/60 mt-1">
                        {format_date(order.inserted_at)}
                      </div>
                    </div>

                    <div class="flex items-center gap-4">
                      <div class="text-right">
                        <div class="text-sm text-base-content/60">Total</div>
                        <div class="text-xl font-bold">{format_price(order.total, @currency)}</div>
                      </div>
                      <.link
                        navigate={Routes.path("/my-orders/#{order.uuid}")}
                        class="btn btn-outline btn-sm"
                      >
                        View Details
                      </.link>
                    </div>
                  </div>

                  <%!-- Order items preview --%>
                  <div class="mt-4 pt-4 border-t">
                    <div class="text-sm text-base-content/60">
                      {items_summary(order.line_items)}
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  # Helpers

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
    Calendar.strftime(dt, "%B %d, %Y at %H:%M")
  end

  defp format_date(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%B %d, %Y at %H:%M")
  end

  defp format_price(nil, _currency), do: "-"

  defp format_price(amount, %Currency{} = currency) do
    Currency.format_amount(amount, currency)
  end

  defp format_price(amount, nil) do
    "$#{Decimal.round(amount, 2)}"
  end

  defp items_summary(nil), do: "No items"
  defp items_summary([]), do: "No items"

  defp items_summary(items) do
    product_items = Enum.filter(items, &(&1["type"] != "shipping"))
    count = length(product_items)

    if count == 1 do
      "1 item"
    else
      "#{count} items"
    end
  end
end
