defmodule PhoenixKit.Modules.Shop.Web.ShopCatalog do
  @moduledoc """
  Public shop catalog main page.
  Shows categories and featured/active products.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    categories = Shop.list_categories(preload: [:parent])
    {products, _total} = Shop.list_products_with_count(status: "active", per_page: 12)
    currency = Shop.get_default_currency()

    # Check if user is authenticated
    authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

    socket =
      socket
      |> assign(:page_title, "Shop")
      |> assign(:categories, categories)
      |> assign(:products, products)
      |> assign(:currency, currency)
      |> assign(:authenticated, authenticated)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shop_layout {assigns}>
      <div class="container flex-col mx-auto px-4 py-6 max-w-7xl">
        <%!-- Hero Section --%>
        <header class="w-full relative mb-6">
          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">Welcome to Our Shop</h1>
            <p class="text-lg text-base-content/70">
              Browse our collection of products across various categories
            </p>
          </div>
        </header>

        <%!-- Categories Section --%>
        <div class="mb-12">
          <h2 class="text-2xl font-bold mb-6">Browse by Category</h2>
          <%= if @categories == [] do %>
            <p class="text-base-content/60">No categories available yet.</p>
          <% else %>
            <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
              <%= for category <- @categories do %>
                <.link
                  navigate={Routes.path("/shop/category/#{category.slug}")}
                  class="card bg-base-100 shadow-md hover:shadow-xl transition-shadow"
                >
                  <div class="card-body items-center text-center p-4">
                    <%= if category.image_url do %>
                      <div class="w-16 h-16 rounded-full overflow-hidden mb-2">
                        <img
                          src={category.image_url}
                          alt={category.name}
                          class="w-full h-full object-cover"
                        />
                      </div>
                    <% else %>
                      <div class="w-16 h-16 rounded-full bg-primary/10 flex items-center justify-center mb-2">
                        <.icon name="hero-folder" class="w-8 h-8 text-primary" />
                      </div>
                    <% end %>
                    <h3 class="font-semibold">{category.name}</h3>
                    <%= if category.description do %>
                      <p class="text-xs text-base-content/60 line-clamp-2">
                        {category.description}
                      </p>
                    <% end %>
                  </div>
                </.link>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- Products Section --%>
        <div>
          <div class="flex items-center justify-between mb-6">
            <h2 class="text-2xl font-bold">Products</h2>
            <.link navigate={Routes.path("/cart")} class="btn btn-outline btn-sm gap-2">
              <.icon name="hero-shopping-cart" class="w-4 h-4" /> View Cart
            </.link>
          </div>

          <%= if @products == [] do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body text-center py-16">
                <.icon name="hero-cube" class="w-16 h-16 mx-auto mb-4 opacity-30" />
                <h3 class="text-xl font-medium text-base-content/60">No products available</h3>
                <p class="text-base-content/50">Check back soon for new arrivals</p>
              </div>
            </div>
          <% else %>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
              <%= for product <- @products do %>
                <.product_card product={product} currency={@currency} />
              <% end %>
            </div>
          <% end %>
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

  attr :product, :map, required: true
  attr :currency, :any, required: true

  defp product_card(assigns) do
    ~H"""
    <.link
      navigate={Routes.path("/shop/product/#{@product.slug}")}
      class="card bg-base-100 shadow-md hover:shadow-xl transition-all hover:-translate-y-1"
    >
      <figure class="h-48 bg-base-200">
        <%= if first_image(@product) do %>
          <img
            src={first_image(@product)}
            alt={@product.title}
            class="w-full h-full object-cover"
          />
        <% else %>
          <div class="w-full h-full flex items-center justify-center">
            <.icon name="hero-cube" class="w-16 h-16 opacity-30" />
          </div>
        <% end %>
      </figure>
      <div class="card-body p-4">
        <h3 class="card-title text-base line-clamp-2">{@product.title}</h3>

        <div class="flex items-center gap-2">
          <span class="text-lg font-bold text-primary">
            {format_price(@product.price, @currency)}
          </span>
          <%= if @product.compare_at_price && Decimal.compare(@product.compare_at_price, @product.price) == :gt do %>
            <span class="text-sm text-base-content/40 line-through">
              {format_price(@product.compare_at_price, @currency)}
            </span>
          <% end %>
        </div>

        <%= if @product.category do %>
          <div class="mt-2">
            <span class="badge badge-ghost badge-sm">{@product.category.name}</span>
          </div>
        <% end %>
      </div>
    </.link>
    """
  end

  defp first_image(%{images: [first | _]}), do: first
  defp first_image(_), do: nil

  defp format_price(nil, _currency), do: "-"

  defp format_price(price, %Currency{} = currency) do
    Currency.format_amount(price, currency)
  end

  defp format_price(price, nil) do
    "$#{Decimal.round(price, 2)}"
  end
end
