defmodule PhoenixKit.Modules.Shop.Web.ShopCatalog do
  @moduledoc """
  Public shop catalog main page.
  Shows categories and featured/active products.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Dashboard.{Registry, Tab}
  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Category
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    categories = Shop.list_active_categories(preload: [:parent])

    {products, _total} =
      Shop.list_products_with_count(
        status: "active",
        per_page: 12,
        exclude_hidden_categories: true
      )

    currency = Shop.get_default_currency()

    # Check if user is authenticated
    authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

    # Build dashboard tabs with shop categories for authenticated users
    dashboard_tabs =
      if authenticated do
        build_dashboard_tabs_with_shop(
          categories,
          nil,
          socket.assigns[:url_path] || "/shop",
          socket.assigns[:phoenix_kit_current_scope]
        )
      else
        nil
      end

    socket =
      socket
      |> assign(:page_title, "Shop")
      |> assign(:categories, categories)
      |> assign(:products, products)
      |> assign(:currency, currency)
      |> assign(:authenticated, authenticated)
      |> assign(:dashboard_tabs, dashboard_tabs)

    {:ok, socket}
  end

  # Build dashboard tabs including shop categories as subtabs
  defp build_dashboard_tabs_with_shop(categories, current_category, current_path, scope) do
    # Get existing dashboard tabs from registry
    base_tabs = Registry.get_tabs_with_active(current_path, scope: scope)

    # Find existing shop tab and update it, or create new one if not found
    {updated_tabs, shop_exists?} = update_existing_shop_tab(base_tabs)

    # Create category subtabs
    category_tabs = build_category_subtabs(categories, current_category)

    if shop_exists? do
      # Shop tab exists - just append category subtabs
      updated_tabs ++ category_tabs
    else
      # No shop tab in registry - create one with categories
      shop_tab = create_shop_parent_tab(current_category)
      updated_tabs ++ [shop_tab | category_tabs]
    end
  end

  # Update existing dashboard_shop tab to show subtabs always
  defp update_existing_shop_tab(tabs) do
    shop_exists? = Enum.any?(tabs, &(&1.id == :dashboard_shop))

    updated_tabs =
      Enum.map(tabs, fn tab ->
        if tab.id == :dashboard_shop do
          %{tab | subtab_display: :always}
        else
          tab
        end
      end)

    {updated_tabs, shop_exists?}
  end

  # Create shop parent tab (only if not in registry)
  defp create_shop_parent_tab(current_category) do
    tab =
      Tab.new!(
        id: :dashboard_shop,
        label: "Shop",
        icon: "hero-building-storefront",
        path: Routes.path("/shop"),
        priority: 300,
        group: :shop,
        match: :prefix,
        subtab_display: :always
      )

    Map.put(tab, :active, is_nil(current_category))
  end

  # Build category subtabs for existing dashboard_shop tab
  defp build_category_subtabs(categories, current_category) do
    categories
    |> Enum.with_index()
    |> Enum.map(fn {cat, idx} ->
      tab =
        Tab.new!(
          id: String.to_atom("shop_cat_#{cat.id}"),
          label: cat.name,
          icon: "hero-folder",
          path: Routes.path("/shop/category/#{cat.slug}"),
          priority: 301 + idx,
          parent: :dashboard_shop,
          group: :shop,
          match: :prefix
        )

      is_active = current_category && current_category.id == cat.id
      Map.put(tab, :active, is_active)
    end)
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
                    <%= if image_url = Category.get_image_url(category) do %>
                      <div class="w-16 h-16 rounded-full overflow-hidden mb-2">
                        <img
                          src={image_url}
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
      <.shop_public_layout {assigns}>
        {render_slot(@inner_block)}
      </.shop_public_layout>
    <% end %>
    """
  end

  # Public shop layout with wide container for guests
  slot :inner_block, required: true

  defp shop_public_layout(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100">
      <%!-- Simple navbar for shop --%>
      <nav class="navbar bg-base-100 shadow-sm border-b border-base-200">
        <div class="navbar-start">
          <.link navigate="/" class="btn btn-ghost text-xl">
            <.icon name="hero-home" class="w-5 h-5" />
          </.link>
        </div>
        <div class="navbar-center">
          <.link navigate={Routes.path("/shop")} class="btn btn-ghost text-xl">
            <.icon name="hero-shopping-bag" class="w-5 h-5 mr-2" /> Shop
          </.link>
        </div>
        <div class="navbar-end gap-2">
          <.link navigate={Routes.path("/cart")} class="btn btn-ghost btn-circle">
            <.icon name="hero-shopping-cart" class="w-5 h-5" />
          </.link>
          <.link navigate={Routes.path("/users/log-in")} class="btn btn-primary btn-sm">
            Sign In
          </.link>
        </div>
      </nav>

      <%!-- Flash messages --%>
      <.flash_group flash={@flash} />

      <%!-- Wide content area --%>
      <main class="py-6">
        {render_slot(@inner_block)}
      </main>
    </div>
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

  defp first_image(%{images: [%{"src" => src} | _]}), do: src
  defp first_image(%{images: [first | _]}) when is_binary(first), do: first
  defp first_image(_), do: nil

  defp format_price(nil, _currency), do: "-"

  defp format_price(price, %Currency{} = currency) do
    Currency.format_amount(price, currency)
  end

  defp format_price(price, nil) do
    "$#{Decimal.round(price, 2)}"
  end
end
