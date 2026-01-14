defmodule PhoenixKit.Modules.Shop.Web.CatalogProduct do
  @moduledoc """
  Public product detail page with add-to-cart functionality.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"slug" => slug}, session, socket) do
    case Shop.get_product_by_slug(slug, preload: [:category]) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Product not found")
         |> push_navigate(to: Routes.path("/shop"))}

      product ->
        # Get session_id for guest cart
        session_id = session["shop_session_id"] || generate_session_id()
        user = socket.assigns[:current_user]
        user_id = if user, do: user.id, else: nil

        currency = Shop.get_default_currency()

        # Check if user is authenticated
        authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

        # Check if product is already in cart
        cart_item = get_cart_item(user_id, session_id, product.id)

        socket =
          socket
          |> assign(:page_title, product.title)
          |> assign(:product, product)
          |> assign(:currency, currency)
          |> assign(:quantity, 1)
          |> assign(:session_id, session_id)
          |> assign(:user_id, user_id)
          |> assign(:selected_image, first_image(product))
          |> assign(:adding_to_cart, false)
          |> assign(:authenticated, authenticated)
          |> assign(:cart_item, cart_item)

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("set_quantity", %{"quantity" => quantity}, socket) do
    quantity = String.to_integer(quantity) |> max(1)
    {:noreply, assign(socket, :quantity, quantity)}
  end

  @impl true
  def handle_event("increment", _params, socket) do
    {:noreply, assign(socket, :quantity, socket.assigns.quantity + 1)}
  end

  @impl true
  def handle_event("decrement", _params, socket) do
    quantity = max(socket.assigns.quantity - 1, 1)
    {:noreply, assign(socket, :quantity, quantity)}
  end

  @impl true
  def handle_event("select_image", %{"url" => url}, socket) do
    {:noreply, assign(socket, :selected_image, url)}
  end

  @impl true
  def handle_event("add_to_cart", _params, socket) do
    socket = assign(socket, :adding_to_cart, true)

    # Get or create cart
    {:ok, cart} =
      Shop.get_or_create_cart(
        user_id: socket.assigns.user_id,
        session_id: socket.assigns.session_id
      )

    case Shop.add_to_cart(cart, socket.assigns.product, socket.assigns.quantity) do
      {:ok, updated_cart} ->
        product = socket.assigns.product
        quantity = socket.assigns.quantity
        currency = socket.assigns.currency
        line_total = Decimal.mult(product.price, quantity)
        line_str = format_price(line_total, currency)
        cart_total_str = format_price(updated_cart.total, currency)

        unit_price_str = format_price(product.price, currency)

        message =
          "#{product.title} (#{quantity} × #{unit_price_str} = #{line_str}) added to cart.\nCart total: #{cart_total_str}"

        # Find updated cart item
        updated_cart_item =
          Enum.find(updated_cart.items, &(&1.product_id == socket.assigns.product.id))

        {:noreply,
         socket
         |> assign(:adding_to_cart, false)
         |> assign(:quantity, 1)
         |> assign(:cart_item, updated_cart_item)
         |> put_flash(:info, message)
         |> push_event("cart_updated", %{})}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:adding_to_cart, false)
         |> put_flash(:error, "Failed to add to cart")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shop_layout {assigns}>
      <div class="p-6 max-w-7xl mx-auto">
        <%!-- Breadcrumbs --%>
        <div class="breadcrumbs text-sm mb-6">
          <ul>
            <li><.link navigate={Routes.path("/shop")}>Shop</.link></li>
            <%= if @product.category do %>
              <li>
                <.link navigate={Routes.path("/shop/category/#{@product.category.slug}")}>
                  {@product.category.name}
                </.link>
              </li>
            <% end %>
            <li class="font-medium truncate max-w-xs">{@product.title}</li>
          </ul>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-12">
          <%!-- Product Images --%>
          <div class="space-y-4">
            <%!-- Main Image --%>
            <div class="aspect-square bg-base-200 rounded-lg overflow-hidden">
              <%= if @selected_image do %>
                <img
                  src={@selected_image}
                  alt={@product.title}
                  class="w-full h-full object-cover"
                />
              <% else %>
                <div class="w-full h-full flex items-center justify-center">
                  <.icon name="hero-cube" class="w-32 h-32 opacity-30" />
                </div>
              <% end %>
            </div>

            <%!-- Thumbnails --%>
            <%= if has_multiple_images?(@product) do %>
              <div class="flex gap-2 overflow-x-auto py-2">
                <%= for {image, _idx} <- Enum.with_index(@product.images || []) do %>
                  <button
                    phx-click="select_image"
                    phx-value-url={image}
                    class={[
                      "w-16 h-16 rounded-lg overflow-hidden flex-shrink-0 border-2 transition-colors",
                      if(@selected_image == image,
                        do: "border-primary",
                        else: "border-transparent hover:border-base-300"
                      )
                    ]}
                  >
                    <img
                      src={image}
                      alt="Thumbnail"
                      class="w-full h-full object-cover"
                    />
                  </button>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Product Info --%>
          <div class="space-y-6">
            <div>
              <h1 class="text-3xl font-bold mb-2">{@product.title}</h1>

              <%= if @product.vendor do %>
                <p class="text-base-content/60">by {@product.vendor}</p>
              <% end %>
            </div>

            <%!-- Price --%>
            <div class="flex items-baseline gap-3">
              <span class="text-3xl font-bold text-primary">
                {format_price(@product.price, @currency)}
              </span>
              <%= if @product.compare_at_price && Decimal.compare(@product.compare_at_price, @product.price) == :gt do %>
                <span class="text-xl text-base-content/40 line-through">
                  {format_price(@product.compare_at_price, @currency)}
                </span>
                <span class="badge badge-success">
                  {discount_percentage(@product)}% OFF
                </span>
              <% end %>
            </div>

            <%!-- Description --%>
            <%= if @product.description do %>
              <div class="prose prose-sm max-w-none">
                <p>{@product.description}</p>
              </div>
            <% end %>

            <%!-- Product Details --%>
            <div class="divider"></div>

            <div class="grid grid-cols-2 gap-4 text-sm">
              <div>
                <span class="text-base-content/60">Type:</span>
                <span class="ml-2 font-medium capitalize">{@product.product_type}</span>
              </div>

              <%= if @product.weight_grams && @product.weight_grams > 0 do %>
                <div>
                  <span class="text-base-content/60">Weight:</span>
                  <span class="ml-2 font-medium">{@product.weight_grams}g</span>
                </div>
              <% end %>

              <%= if @product.category do %>
                <div>
                  <span class="text-base-content/60">Category:</span>
                  <.link
                    navigate={Routes.path("/shop/category/#{@product.category.slug}")}
                    class="ml-2 link link-primary"
                  >
                    {@product.category.name}
                  </.link>
                </div>
              <% end %>
            </div>

            <div class="divider"></div>

            <%!-- Add to Cart Section --%>
            <%= if @product.status == "active" do %>
              <div class="space-y-4">
                <%!-- Quantity Selector --%>
                <div class="form-control">
                  <label class="label"><span class="label-text">Quantity</span></label>
                  <div class="flex items-center gap-3">
                    <div class="flex items-center gap-1">
                      <button
                        type="button"
                        phx-click="decrement"
                        class="btn btn-square btn-outline btn-sm"
                        disabled={@quantity <= 1}
                      >
                        <.icon name="hero-minus" class="w-4 h-4" />
                      </button>
                      <form phx-change="set_quantity" class="inline">
                        <input
                          type="number"
                          value={@quantity}
                          name="quantity"
                          min="1"
                          class="input input-bordered w-20 text-center"
                        />
                      </form>
                      <button
                        type="button"
                        phx-click="increment"
                        class="btn btn-square btn-outline btn-sm"
                      >
                        <.icon name="hero-plus" class="w-4 h-4" />
                      </button>
                    </div>
                    <span class="text-base-content/60">×</span>
                    <span class="text-base-content/60">
                      {format_price(@product.price, @currency)}
                    </span>
                    <span class="text-base-content/60">=</span>
                    <span class="text-xl font-bold text-primary">
                      {format_price(line_total(@product.price, @quantity), @currency)}
                    </span>
                  </div>
                </div>

                <%!-- Already in Cart Notice --%>
                <%= if @cart_item do %>
                  <div class="alert alert-info">
                    <.icon name="hero-shopping-cart" class="w-5 h-5" />
                    <div>
                      <span class="font-medium">Already in cart:</span>
                      <span>
                        {@cart_item.quantity} × {format_price(@cart_item.unit_price, @currency)} = {format_price(
                          @cart_item.line_total,
                          @currency
                        )}
                      </span>
                    </div>
                  </div>
                <% end %>

                <%!-- Add to Cart Button --%>
                <button
                  phx-click="add_to_cart"
                  class={["btn btn-primary btn-lg w-full gap-2", @adding_to_cart && "loading"]}
                  disabled={@adding_to_cart}
                >
                  <%= if @adding_to_cart do %>
                    Adding...
                  <% else %>
                    <.icon name="hero-shopping-cart" class="w-5 h-5" />
                    <%= if @cart_item do %>
                      Add More to Cart
                    <% else %>
                      Add to Cart
                    <% end %>
                  <% end %>
                </button>

                <%!-- View Cart Link --%>
                <.link navigate={Routes.path("/cart")} class="btn btn-ghost w-full gap-2">
                  <.icon name="hero-eye" class="w-5 h-5" /> View Cart
                </.link>
              </div>
            <% else %>
              <div class="alert alert-warning">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                <span>This product is currently unavailable</span>
              </div>
            <% end %>

            <%!-- Tags --%>
            <%= if @product.tags && @product.tags != [] do %>
              <div class="flex flex-wrap gap-2 mt-4">
                <%= for tag <- @product.tags do %>
                  <span class="badge badge-ghost">{tag}</span>
                <% end %>
              </div>
            <% end %>
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

  defp first_image(%{images: [first | _]}), do: first
  defp first_image(_), do: nil

  defp has_multiple_images?(%{images: [_, _ | _]}), do: true
  defp has_multiple_images?(_), do: false

  defp format_price(nil, _currency), do: "-"

  defp format_price(price, %Currency{} = currency) do
    Currency.format_amount(price, currency)
  end

  defp format_price(price, nil) do
    "$#{Decimal.round(price, 2)}"
  end

  defp discount_percentage(%{price: price, compare_at_price: compare}) when not is_nil(compare) do
    diff = Decimal.sub(compare, price)
    percent = Decimal.div(diff, compare) |> Decimal.mult(100) |> Decimal.round(0)
    Decimal.to_integer(percent)
  end

  defp discount_percentage(_), do: 0

  defp line_total(price, quantity) when not is_nil(price) do
    Decimal.mult(price, quantity)
  end

  defp line_total(_, _), do: Decimal.new("0")

  defp get_cart_item(user_id, session_id, product_id) do
    case Shop.find_active_cart(user_id: user_id, session_id: session_id) do
      %{items: items} when is_list(items) ->
        Enum.find(items, &(&1.product_id == product_id))

      _ ->
        nil
    end
  end
end
