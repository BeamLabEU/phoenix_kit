defmodule PhoenixKit.Modules.Shop.Web.MyOrderDetail do
  @moduledoc """
  User's order detail page.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
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
      case Billing.get_order_by_uuid(uuid) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "Order not found")
           |> push_navigate(to: Routes.path("/my-orders"))}

        order ->
          if order.user_id == user.id do
            currency = Shop.get_default_currency()

            billing_profile =
              if order.billing_profile_id,
                do: Billing.get_billing_profile(order.billing_profile_id)

            socket =
              socket
              |> assign(:page_title, "Order #{order.order_number}")
              |> assign(:order, order)
              |> assign(:currency, currency)
              |> assign(:billing_profile, billing_profile)

            {:ok, socket}
          else
            {:ok,
             socket
             |> put_flash(:error, "You don't have access to this order")
             |> push_navigate(to: Routes.path("/my-orders"))}
          end
      end
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
      <div class="p-6 max-w-3xl mx-auto">
        <%!-- Back Link --%>
        <.link navigate={Routes.path("/my-orders")} class="btn btn-ghost btn-sm mb-6">
          <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back to Orders
        </.link>

        <%!-- Order Header --%>
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-8">
          <div>
            <h1 class="text-3xl font-bold font-mono">{@order.order_number}</h1>
            <div class="text-sm text-base-content/60 mt-1">
              Placed on {format_date(@order.inserted_at)}
            </div>
          </div>
          <div class={"badge #{status_badge_class(@order.status)} badge-lg capitalize"}>
            {@order.status}
          </div>
        </div>

        <%!-- Billing Info --%>
        <div class="card bg-base-100 shadow-lg mb-6">
          <div class="card-body">
            <h2 class="card-title mb-4">Billing Information</h2>
            <%= if @billing_profile do %>
              <div class="text-sm">
                <div class="font-medium">{profile_display_name(@billing_profile)}</div>
                <div class="text-base-content/60">{profile_address(@billing_profile)}</div>
                <%= if @billing_profile.email do %>
                  <div class="text-base-content/60">{@billing_profile.email}</div>
                <% end %>
              </div>
            <% else %>
              <%= if @order.billing_snapshot && map_size(@order.billing_snapshot) > 0 do %>
                <div class="text-sm">
                  <div class="font-medium">
                    {@order.billing_snapshot["first_name"]} {@order.billing_snapshot["last_name"]}
                  </div>
                  <div class="text-base-content/60">
                    {[
                      @order.billing_snapshot["address_line1"],
                      @order.billing_snapshot["city"],
                      @order.billing_snapshot["postal_code"],
                      @order.billing_snapshot["country"]
                    ]
                    |> Enum.filter(&(&1 && &1 != ""))
                    |> Enum.join(", ")}
                  </div>
                  <%= if @order.billing_snapshot["email"] do %>
                    <div class="text-base-content/60">{@order.billing_snapshot["email"]}</div>
                  <% end %>
                </div>
              <% else %>
                <div class="text-sm text-base-content/60">No billing information</div>
              <% end %>
            <% end %>
          </div>
        </div>

        <%!-- Order Items --%>
        <div class="card bg-base-100 shadow-lg mb-6">
          <div class="card-body">
            <h2 class="card-title mb-4">Order Items</h2>
            <div class="space-y-4">
              <%= for item <- @order.line_items || [] do %>
                <div class="flex justify-between items-center py-2 border-b last:border-0">
                  <div>
                    <span class="font-medium">{item["name"]}</span>
                    <%= if item["type"] != "shipping" do %>
                      <span class="text-base-content/60 ml-2">× {item["quantity"]}</span>
                    <% end %>
                    <%= if item["description"] && item["description"] != "" do %>
                      <div class="text-sm text-base-content/50">{item["description"]}</div>
                    <% end %>
                  </div>
                  <div class="font-medium">
                    {format_price_string(item["total"])}
                  </div>
                </div>
              <% end %>
            </div>

            <%!-- Totals --%>
            <div class="border-t pt-4 mt-4 space-y-2">
              <div class="flex justify-between text-sm">
                <span class="text-base-content/70">Subtotal</span>
                <span>{format_price(@order.subtotal, @currency)}</span>
              </div>

              <%= if @order.tax_amount && Decimal.compare(@order.tax_amount, Decimal.new("0")) == :gt do %>
                <div class="flex justify-between text-sm">
                  <span class="text-base-content/70">Tax</span>
                  <span>{format_price(@order.tax_amount, @currency)}</span>
                </div>
              <% end %>

              <%= if @order.discount_amount && Decimal.compare(@order.discount_amount, Decimal.new("0")) == :gt do %>
                <div class="flex justify-between text-sm text-success">
                  <span>Discount</span>
                  <span>-{format_price(@order.discount_amount, @currency)}</span>
                </div>
              <% end %>

              <div class="flex justify-between text-lg font-bold pt-2 border-t">
                <span>Total</span>
                <span>{format_price(@order.total, @currency)}</span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Actions --%>
        <div class="flex justify-center">
          <.link navigate={Routes.path("/shop")} class="btn btn-primary">
            <.icon name="hero-shopping-bag" class="w-5 h-5 mr-2" /> Continue Shopping
          </.link>
        </div>
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

  defp format_price_string(nil), do: "-"
  defp format_price_string(amount) when is_binary(amount), do: "$#{amount}"
  defp format_price_string(amount), do: "$#{amount}"

  defp profile_display_name(%{type: "company"} = profile) do
    profile.company_name || "#{profile.first_name} #{profile.last_name}"
  end

  defp profile_display_name(profile) do
    "#{profile.first_name} #{profile.last_name}"
  end

  defp profile_address(profile) do
    [profile.address_line1, profile.city, profile.postal_code, profile.country]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end
end
