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
    user = socket.assigns[:current_user]
    user_id = if user, do: user.id, else: nil

    # Get or create cart
    {:ok, cart} = Shop.get_or_create_cart(user_id: user_id, session_id: session_id)

    # Get available shipping methods
    shipping_methods = Shop.get_available_shipping_methods(cart)

    # Get default currency from Billing
    currency = Shop.get_default_currency()

    socket =
      socket
      |> assign(:page_title, "Shopping Cart")
      |> assign(:cart, cart)
      |> assign(:session_id, session_id)
      |> assign(:shipping_methods, shipping_methods)
      |> assign(:selected_country, cart.shipping_country || "US")
      |> assign(:countries, country_options())
      |> assign(:currency, currency)

    {:ok, socket}
  end

  @impl true
  def handle_event("update_quantity", %{"item_id" => item_id, "quantity" => quantity}, socket) do
    item_id = String.to_integer(item_id)
    quantity = String.to_integer(quantity)

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
  def handle_event("select_country", %{"country" => country}, socket) do
    cart = socket.assigns.cart

    case Shop.set_cart_shipping_country(cart, country) do
      {:ok, updated_cart} ->
        shipping_methods = Shop.get_available_shipping_methods(updated_cart)

        {:noreply,
         socket
         |> assign(:cart, updated_cart)
         |> assign(:selected_country, country)
         |> assign(:shipping_methods, shipping_methods)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_shipping", %{"method_id" => method_id}, socket) do
    method_id = String.to_integer(method_id)
    method = Enum.find(socket.assigns.shipping_methods, &(&1.id == method_id))
    cart = socket.assigns.cart

    if method do
      case Shop.set_cart_shipping(cart, method, socket.assigns.selected_country) do
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
        # Checkout flow will be implemented in Phase 3
        {:noreply, put_flash(socket, :info, "Checkout coming soon!")}
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
      <div class="p-6 max-w-6xl mx-auto">
        <h1 class="text-3xl font-bold mb-8">Shopping Cart</h1>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
          <%!-- Cart Items --%>
          <div class="lg:col-span-2">
            <%= if @cart.items == [] do %>
              <div class="card bg-base-100 shadow-lg">
                <div class="card-body text-center py-16">
                  <.icon name="hero-shopping-cart" class="w-16 h-16 mx-auto mb-4 opacity-30" />
                  <h2 class="text-xl font-medium text-base-content/60">Your cart is empty</h2>
                  <p class="text-base-content/50 mb-6">Add some products to get started</p>
                  <.link navigate={Routes.path("/admin/shop/products")} class="btn btn-primary">
                    Browse Products
                  </.link>
                </div>
              </div>
            <% else %>
              <div class="card bg-base-100 shadow-lg">
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
                              <select
                                class="select select-bordered select-sm w-20"
                                phx-change="update_quantity"
                                phx-value-item_id={item.id}
                                name="quantity"
                              >
                                <%= for qty <- 1..10 do %>
                                  <option value={qty} selected={item.quantity == qty}>{qty}</option>
                                <% end %>
                              </select>
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
              <div class="card bg-base-100 shadow-lg mt-6">
                <div class="card-body">
                  <h2 class="card-title mb-4">Shipping</h2>

                  <div class="form-control mb-4">
                    <label class="label"><span class="label-text">Country</span></label>
                    <select
                      class="select select-bordered"
                      phx-change="select_country"
                      name="country"
                    >
                      <%= for {name, code} <- @countries do %>
                        <option value={code} selected={@selected_country == code}>{name}</option>
                      <% end %>
                    </select>
                  </div>

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
            <div class="card bg-base-100 shadow-lg sticky top-6">
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
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
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

  defp country_options do
    [
      {"United States", "US"},
      {"Canada", "CA"},
      {"United Kingdom", "GB"},
      {"Germany", "DE"},
      {"France", "FR"},
      {"Netherlands", "NL"},
      {"Belgium", "BE"},
      {"Austria", "AT"},
      {"Switzerland", "CH"},
      {"Italy", "IT"},
      {"Spain", "ES"},
      {"Portugal", "PT"},
      {"Poland", "PL"},
      {"Sweden", "SE"},
      {"Norway", "NO"},
      {"Denmark", "DK"},
      {"Finland", "FI"},
      {"Estonia", "EE"},
      {"Latvia", "LV"},
      {"Lithuania", "LT"},
      {"Australia", "AU"},
      {"New Zealand", "NZ"},
      {"Japan", "JP"},
      {"South Korea", "KR"},
      {"Singapore", "SG"}
    ]
  end
end
