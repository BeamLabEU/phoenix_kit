defmodule PhoenixKit.Modules.Shop.Web.CartPage do
  @moduledoc """
  Public cart page LiveView for E-Commerce module.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.ShippingMethod
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, session, socket) do
    # Get session_id from session (for guest users)
    session_id = session["shop_session_id"] || generate_session_id()

    # Get current user if logged in
    user = get_current_user(socket)
    user_id = if user, do: user.id, else: nil

    # Get or create cart
    {:ok, cart} = Shop.get_or_create_cart(user_id: user_id, session_id: session_id)

    # Get available shipping methods
    shipping_methods = Shop.get_available_shipping_methods(cart)

    # Auto-select cheapest shipping method if none selected
    {:ok, cart} = Shop.auto_select_shipping_method(cart, shipping_methods)

    # Get default currency from Billing
    currency = Shop.get_default_currency()

    # Check if user is authenticated
    authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

    socket =
      socket
      |> assign(:page_title, "Shopping Cart")
      |> assign(:cart, cart)
      |> assign(:session_id, session_id)
      |> assign(:shipping_methods, shipping_methods)
      |> assign(:currency, currency)
      |> assign(:authenticated, authenticated)

    {:ok, socket}
  end

  @impl true
  def handle_event("update_quantity", %{"item_id" => item_id, "quantity" => quantity}, socket) do
    item_id = String.to_integer(item_id)
    quantity = max(1, String.to_integer(quantity))

    update_item_quantity(socket, item_id, quantity)
  end

  @impl true
  def handle_event("remove_item", %{"item_id" => item_id}, socket) do
    item_id = String.to_integer(item_id)
    item = Enum.find(socket.assigns.cart.items, &(&1.id == item_id))

    if item do
      case Shop.remove_from_cart(item) do
        {:ok, updated_cart} ->
          shipping_methods = Shop.get_available_shipping_methods(updated_cart)

          {:noreply,
           socket
           |> assign(:cart, updated_cart)
           |> assign(:shipping_methods, shipping_methods)
           |> put_flash(:info, "Item removed from cart")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to remove item")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_shipping", %{"method_id" => method_id}, socket) do
    method_id = String.to_integer(method_id)
    method = Enum.find(socket.assigns.shipping_methods, &(&1.id == method_id))
    cart = socket.assigns.cart

    if method do
      # Country will be set at checkout based on billing info
      case Shop.set_cart_shipping(cart, method, nil) do
        {:ok, updated_cart} ->
          {:noreply, assign(socket, :cart, updated_cart)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to set shipping method")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("proceed_to_checkout", _params, socket) do
    cart = socket.assigns.cart

    cond do
      cart.items == [] ->
        {:noreply, put_flash(socket, :error, "Your cart is empty")}

      is_nil(cart.shipping_method_id) ->
        {:noreply, put_flash(socket, :error, "Please select a shipping method")}

      true ->
        {:noreply, push_navigate(socket, to: Routes.path("/checkout"))}
    end
  end

  defp update_item_quantity(socket, item_id, quantity) do
    item = Enum.find(socket.assigns.cart.items, &(&1.id == item_id))

    if item do
      case Shop.update_cart_item(item, quantity) do
        {:ok, updated_cart} ->
          shipping_methods = Shop.get_available_shipping_methods(updated_cart)

          {:noreply,
           socket
           |> assign(:cart, updated_cart)
           |> assign(:shipping_methods, shipping_methods)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update quantity")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shop_layout {assigns}>
      <div class="container flex-col mx-auto px-4 py-6 max-w-6xl">
        <%!-- Header --%>
        <header class="mb-6">
          <div class="flex items-start gap-4">
            <.link
              navigate={Routes.path("/shop")}
              class="btn btn-outline btn-primary btn-sm shrink-0"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Continue Shopping
            </.link>
            <div class="flex-1 min-w-0">
              <h1 class="text-3xl font-bold text-base-content">Shopping Cart</h1>
              <p class="text-base-content/70 mt-1">Review your items before checkout</p>
            </div>
          </div>
        </header>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
          <%!-- Cart Items --%>
          <div class="lg:col-span-2">
            <%= if @cart.items == [] do %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body text-center py-16">
                  <.icon name="hero-shopping-cart" class="w-16 h-16 mx-auto mb-4 opacity-30" />
                  <h2 class="text-xl font-medium text-base-content/60">Your cart is empty</h2>
                  <p class="text-base-content/50 mb-6">Add some products to get started</p>
                  <.link navigate={Routes.path("/shop")} class="btn btn-primary">
                    Browse Products
                  </.link>
                </div>
              </div>
            <% else %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body p-0">
                  <div class="overflow-x-auto">
                    <table class="table">
                      <thead>
                        <tr>
                          <th class="w-1/2">Product</th>
                          <th class="text-center">Quantity</th>
                          <th class="text-right">Price</th>
                          <th></th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for item <- @cart.items do %>
                          <tr>
                            <td>
                              <div class="flex items-center gap-4">
                                <%= if item.product_image do %>
                                  <div class="w-16 h-16 bg-base-200 rounded-lg overflow-hidden flex-shrink-0">
                                    <img
                                      src={item.product_image}
                                      alt={item.product_title}
                                      class="w-full h-full object-cover"
                                    />
                                  </div>
                                <% else %>
                                  <div class="w-16 h-16 bg-base-200 rounded-lg flex items-center justify-center flex-shrink-0">
                                    <.icon name="hero-cube" class="w-8 h-8 opacity-30" />
                                  </div>
                                <% end %>
                                <div>
                                  <div class="font-medium">{item.product_title}</div>
                                  <%= if item.product_sku do %>
                                    <div class="text-xs text-base-content/50">
                                      SKU: {item.product_sku}
                                    </div>
                                  <% end %>
                                  <%= if item.compare_at_price && Decimal.compare(item.compare_at_price, item.unit_price) == :gt do %>
                                    <div class="text-xs">
                                      <span class="line-through text-base-content/40">
                                        {format_price(item.compare_at_price, @currency)}
                                      </span>
                                      <span class="text-success ml-1">On sale!</span>
                                    </div>
                                  <% end %>
                                </div>
                              </div>
                            </td>
                            <td class="text-center">
                              <form phx-change="update_quantity" class="inline">
                                <input type="hidden" name="item_id" value={item.id} />
                                <input
                                  type="number"
                                  name="quantity"
                                  value={item.quantity}
                                  min="1"
                                  class="input input-bordered input-sm w-20 text-center"
                                />
                              </form>
                            </td>
                            <td class="text-right">
                              <div class="font-semibold">
                                {format_price(item.line_total, @currency)}
                              </div>
                              <div class="text-xs text-base-content/50">
                                {format_price(item.unit_price, @currency)} each
                              </div>
                            </td>
                            <td>
                              <button
                                phx-click="remove_item"
                                phx-value-item_id={item.id}
                                class="btn btn-ghost btn-sm text-error"
                              >
                                <.icon name="hero-trash" class="w-4 h-4" />
                              </button>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>
            <% end %>

            <%!-- Shipping Section --%>
            <%= if @cart.items != [] do %>
              <div class="card bg-base-100 shadow-xl mt-6">
                <div class="card-body">
                  <h2 class="card-title mb-4">Shipping Method</h2>

                  <%= if @shipping_methods == [] do %>
                    <div class="alert alert-warning">
                      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                      <span>No shipping methods available for your selection</span>
                    </div>
                  <% else %>
                    <div class="space-y-3">
                      <%= for method <- @shipping_methods do %>
                        <label class={[
                          "flex items-center gap-4 p-4 border rounded-lg cursor-pointer transition-colors",
                          if(@cart.shipping_method_id == method.id,
                            do: "border-primary bg-primary/5",
                            else: "border-base-300 hover:border-primary/50"
                          )
                        ]}>
                          <input
                            type="radio"
                            name="shipping_method"
                            value={method.id}
                            checked={@cart.shipping_method_id == method.id}
                            phx-click="select_shipping"
                            phx-value-method_id={method.id}
                            class="radio radio-primary"
                          />
                          <div class="flex-1">
                            <div class="font-medium">{method.name}</div>
                            <%= if method.description do %>
                              <div class="text-sm text-base-content/60">{method.description}</div>
                            <% end %>
                            <%= if estimate = ShippingMethod.delivery_estimate(method) do %>
                              <div class="text-sm text-base-content/50">{estimate}</div>
                            <% end %>
                          </div>
                          <div class="text-right">
                            <%= if ShippingMethod.free_for?(method, @cart.subtotal || Decimal.new("0")) do %>
                              <span class="badge badge-success">FREE</span>
                            <% else %>
                              <span class="font-semibold">
                                {format_price(method.price, @currency)}
                              </span>
                            <% end %>
                          </div>
                        </label>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>

          <%!-- Order Summary --%>
          <div class="lg:col-span-1">
            <div class="card bg-base-100 shadow-xl sticky top-6">
              <div class="card-body">
                <h2 class="card-title mb-4">Order Summary</h2>

                <div class="space-y-3 text-sm">
                  <div class="flex justify-between">
                    <span class="text-base-content/70">
                      Subtotal ({@cart.items_count || 0} items)
                    </span>
                    <span>{format_price(@cart.subtotal, @currency)}</span>
                  </div>

                  <div class="flex justify-between">
                    <span class="text-base-content/70">Shipping</span>
                    <%= if is_nil(@cart.shipping_method_id) do %>
                      <span class="text-base-content/50">Select method</span>
                    <% else %>
                      <%= if Decimal.compare(@cart.shipping_amount || Decimal.new("0"), Decimal.new("0")) == :eq do %>
                        <span class="text-success">FREE</span>
                      <% else %>
                        <span>{format_price(@cart.shipping_amount, @currency)}</span>
                      <% end %>
                    <% end %>
                  </div>

                  <%= if @cart.discount_amount && Decimal.compare(@cart.discount_amount, Decimal.new("0")) == :gt do %>
                    <div class="flex justify-between text-success">
                      <span>Discount</span>
                      <span>-{format_price(@cart.discount_amount, @currency)}</span>
                    </div>
                  <% end %>

                  <%= if @cart.tax_amount && Decimal.compare(@cart.tax_amount, Decimal.new("0")) == :gt do %>
                    <div class="flex justify-between">
                      <span class="text-base-content/70">Tax</span>
                      <span>{format_price(@cart.tax_amount, @currency)}</span>
                    </div>
                  <% end %>

                  <div class="divider my-2"></div>

                  <div class="flex justify-between text-lg font-bold">
                    <span>Total</span>
                    <span>{format_price(@cart.total, @currency)}</span>
                  </div>
                </div>

                <button
                  phx-click="proceed_to_checkout"
                  class="btn btn-primary btn-block mt-6"
                  disabled={@cart.items == [] || is_nil(@cart.shipping_method_id)}
                >
                  <.icon name="hero-credit-card" class="w-5 h-5 mr-2" /> Proceed to Checkout
                </button>

                <%= if @cart.items != [] do %>
                  <p class="text-xs text-center text-base-content/50 mt-3">
                    Secure checkout powered by PhoenixKit
                  </p>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>
    </.shop_layout>
    """
  end

  # Layout wrapper - uses dashboard for authenticated, app_layout for guests
  slot :inner_block, required: true

  defp shop_layout(assigns) do
    ~H"""
    <%= if @authenticated do %>
      <PhoenixKitWeb.Layouts.dashboard {assigns}>
        {render_slot(@inner_block)}
      </PhoenixKitWeb.Layouts.dashboard>
    <% else %>
      <PhoenixKitWeb.Components.LayoutWrapper.app_layout
        flash={@flash}
        phoenix_kit_current_scope={@phoenix_kit_current_scope}
        current_path={@url_path}
        current_locale={@current_locale}
        page_title={@page_title}
      >
        {render_slot(@inner_block)}
      </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    <% end %>
    """
  end

  # Private helpers

  defp generate_session_id do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp format_price(nil, _currency), do: "-"

  defp format_price(amount, %Currency{} = currency) do
    Currency.format_amount(amount, currency)
  end

  defp format_price(amount, nil) do
    "$#{Decimal.round(amount, 2)}"
  end

  defp get_current_user(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{id: _} = user} -> user
      _ -> nil
    end
  end
end
