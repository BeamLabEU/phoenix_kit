defmodule PhoenixKit.Modules.Shop.Web.CatalogCategory do
  @moduledoc """
  Public shop category page.
  Shows products filtered by category.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Shop.get_category_by_slug(slug, preload: [:parent]) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Category not found")
         |> push_navigate(to: Routes.path("/shop"))}

      category ->
        {products, total} =
          Shop.list_products_with_count(
            status: "active",
            category_id: category.id,
            per_page: 24,
            preload: [:category]
          )

        currency = Shop.get_default_currency()
        all_categories = Shop.list_categories()

        # Check if user is authenticated
        authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

        socket =
          socket
          |> assign(:page_title, category.name)
          |> assign(:category, category)
          |> assign(:products, products)
          |> assign(:total_products, total)
          |> assign(:categories, all_categories)
          |> assign(:currency, currency)
          |> assign(:authenticated, authenticated)

        {:ok, socket}
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
            <%= if @category.parent do %>
              <li>
                <.link navigate={Routes.path("/shop/category/#{@category.parent.slug}")}>
                  {@category.parent.name}
                </.link>
              </li>
            <% end %>
            <li class="font-medium">{@category.name}</li>
          </ul>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-4 gap-8">
          <%!-- Sidebar - Categories --%>
          <aside class="lg:col-span-1">
            <div class="card bg-base-100 shadow-lg sticky top-6">
              <div class="card-body">
                <h2 class="card-title mb-4">Categories</h2>
                <ul class="menu menu-compact p-0">
                  <li>
                    <.link
                      navigate={Routes.path("/shop")}
                      class="font-medium"
                    >
                      <.icon name="hero-home" class="w-4 h-4" /> All Products
                    </.link>
                  </li>
                  <%= for cat <- @categories do %>
                    <li>
                      <.link
                        navigate={Routes.path("/shop/category/#{cat.slug}")}
                        class={if cat.id == @category.id, do: "active", else: ""}
                      >
                        {cat.name}
                      </.link>
                    </li>
                  <% end %>
                </ul>
              </div>
            </div>
          </aside>

          <%!-- Main Content --%>
          <div class="lg:col-span-3">
            <%!-- Category Header --%>
            <div class="mb-8">
              <h1 class="text-3xl font-bold">{@category.name}</h1>
              <%= if @category.description do %>
                <p class="text-base-content/70 mt-2">{@category.description}</p>
              <% end %>
              <p class="text-sm text-base-content/50 mt-2">
                {@total_products} product(s) found
              </p>
            </div>

            <%!-- Products Grid --%>
            <%= if @products == [] do %>
              <div class="card bg-base-100 shadow-lg">
                <div class="card-body text-center py-16">
                  <.icon name="hero-cube" class="w-16 h-16 mx-auto mb-4 opacity-30" />
                  <h3 class="text-xl font-medium text-base-content/60">
                    No products in this category
                  </h3>
                  <p class="text-base-content/50 mb-4">
                    Check back soon or browse other categories
                  </p>
                  <.link navigate={Routes.path("/shop")} class="btn btn-primary">
                    Browse All Products
                  </.link>
                </div>
              </div>
            <% else %>
              <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-6">
                <%= for product <- @products do %>
                  <.product_card product={product} currency={@currency} />
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

  attr :product, :map, required: true
  attr :currency, :any, required: true

  defp product_card(assigns) do
    ~H"""
    <.link
      navigate={Routes.path("/shop/product/#{@product.slug}")}
      class="card bg-base-100 shadow-md hover:shadow-lg transition-all hover:-translate-y-1"
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

        <%= if @product.product_type == "digital" do %>
          <div class="mt-2">
            <span class="badge badge-info badge-sm">Digital</span>
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
