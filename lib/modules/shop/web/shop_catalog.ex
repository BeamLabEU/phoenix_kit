defmodule PhoenixKit.Modules.Shop.Web.ShopCatalog do
  @moduledoc """
  Public shop catalog main page.
  Shows categories and featured/active products.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Modules.Shop.Web.Components.CatalogSidebar
  alias PhoenixKit.Modules.Shop.Web.Components.FilterHelpers
  alias PhoenixKit.Modules.Shop.Web.Components.ShopLayouts
  alias PhoenixKit.Modules.Shop.Web.Helpers

  @impl true
  def mount(params, _session, socket) do
    # Determine language: use URL locale param if present, otherwise default
    # This ensures /shop always uses default language, not session
    current_language = Helpers.get_language_from_params_or_default(params)

    categories = Shop.list_active_categories(preload: [:parent, :featured_product])

    per_page = 24
    page = Helpers.parse_page(params["page"])

    # Load storefront filters
    {enabled_filters, filter_values} = FilterHelpers.load_filter_data()
    active_filters = FilterHelpers.parse_filter_params(params, enabled_filters)
    filter_opts = FilterHelpers.build_query_opts(active_filters, enabled_filters)

    {products, total} =
      Shop.list_products_with_count(
        [
          status: "active",
          page: 1,
          per_page: page * per_page,
          exclude_hidden_categories: true
        ] ++ filter_opts
      )

    total_pages = max(1, ceil(total / per_page))
    page = min(page, total_pages)

    currency = Shop.get_default_currency()

    # Check if user is authenticated
    authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

    # Get current path for language switcher
    current_path = socket.assigns[:url_path] || "/shop"

    socket =
      socket
      |> assign(:page_title, "Shop")
      |> assign(:categories, categories)
      |> assign(:products, products)
      |> assign(:total_products, total)
      |> assign(:page, page)
      |> assign(:per_page, per_page)
      |> assign(:total_pages, total_pages)
      |> assign(:currency, currency)
      |> assign(:current_language, current_language)
      |> assign(:authenticated, authenticated)
      |> assign(:current_path, current_path)
      |> assign(:enabled_filters, enabled_filters)
      |> assign(:filter_values, filter_values)
      |> assign(:active_filters, active_filters)
      |> assign(:filter_qs, FilterHelpers.build_query_string(active_filters, enabled_filters))
      |> assign(:show_mobile_filters, false)
      |> assign(
        :category_name_wrap,
        PhoenixKit.Settings.get_setting_cached("shop_category_name_display", "truncate") == "wrap"
      )
      |> assign(
        :category_icon_mode,
        PhoenixKit.Settings.get_setting_cached("shop_category_icon_mode", "none")
      )
      |> assign(
        :show_categories_grid,
        PhoenixKit.Settings.get_setting_cached("shop_sidebar_show_categories", "true") == "true"
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = Helpers.parse_page(params["page"])
    active_filters = FilterHelpers.parse_filter_params(params, socket.assigns.enabled_filters)
    filter_opts = FilterHelpers.build_query_opts(active_filters, socket.assigns.enabled_filters)

    filters_changed = active_filters != socket.assigns.active_filters
    page = min(page, max(1, socket.assigns.total_pages))

    if filters_changed || page != socket.assigns.page do
      effective_page = if filters_changed, do: 1, else: page

      {products, total} =
        Shop.list_products_with_count(
          [
            status: "active",
            page: 1,
            per_page: effective_page * socket.assigns.per_page,
            exclude_hidden_categories: true
          ] ++ filter_opts
        )

      total_pages = max(1, ceil(total / socket.assigns.per_page))

      {:noreply,
       socket
       |> assign(:page, min(effective_page, total_pages))
       |> assign(:products, products)
       |> assign(:total_products, total)
       |> assign(:total_pages, total_pages)
       |> assign(:active_filters, active_filters)
       |> assign(
         :filter_qs,
         FilterHelpers.build_query_string(active_filters, socket.assigns.enabled_filters)
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter_price", params, socket) do
    filter_key = params["filter_key"] || "price"

    active_filters =
      FilterHelpers.update_price_filter(
        socket.assigns.active_filters,
        filter_key,
        params["price_min"],
        params["price_max"]
      )

    path = build_filter_path(socket.assigns, active_filters)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("toggle_filter", %{"key" => key, "val" => value}, socket) do
    active_filters = FilterHelpers.toggle_filter_value(socket.assigns.active_filters, key, value)
    path = build_filter_path(socket.assigns, active_filters)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    base_path = Shop.catalog_url(socket.assigns.current_language)
    {:noreply, push_patch(socket, to: base_path)}
  end

  @impl true
  def handle_event("toggle_mobile_filters", _params, socket) do
    {:noreply, assign(socket, :show_mobile_filters, !socket.assigns.show_mobile_filters)}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    next_page = socket.assigns.page + 1
    path = build_filter_path(socket.assigns, socket.assigns.active_filters, page: next_page)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def render(assigns) do
    assigns =
      if assigns.authenticated do
        assign(assigns, :sidebar_after_shop, shop_sidebar(assigns))
      else
        assigns
      end

    ~H"""
    <ShopLayouts.shop_layout {assigns} show_sidebar={true}>
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

        <%!-- Mobile filter toggle --%>
        <div class="lg:hidden mb-4">
          <button phx-click="toggle_mobile_filters" class="btn btn-outline btn-sm gap-2">
            <.icon name="hero-funnel" class="w-4 h-4" />
            Filters <% filter_count = FilterHelpers.active_filter_count(@active_filters) %>
            <%= if filter_count > 0 do %>
              <span class="badge badge-primary badge-xs">{filter_count}</span>
            <% end %>
          </button>
        </div>

        <%!-- Mobile filter drawer (filters only, no categories) --%>
        <%= if @show_mobile_filters do %>
          <div class="lg:hidden mb-6">
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body p-4">
                <CatalogSidebar.catalog_sidebar
                  filters={@enabled_filters}
                  filter_values={@filter_values}
                  active_filters={@active_filters}
                  categories={@categories}
                  current_category={nil}
                  current_language={@current_language}
                  category_icon_mode={@category_icon_mode}
                  category_name_wrap={@category_name_wrap}
                  show_categories={false}
                  filter_qs={@filter_qs}
                />
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Main layout: sidebar + content --%>
        <div class="grid grid-cols-1 lg:grid-cols-4 gap-8">
          <%!-- Sidebar: filters + optional categories --%>
          <%= if !@authenticated do %>
            <aside class="lg:col-span-1 hidden lg:block">
              <div class="card bg-base-100 shadow-lg sticky top-6 max-h-[calc(100vh-3rem)] overflow-y-auto">
                <div class="card-body p-4">
                  <CatalogSidebar.catalog_sidebar
                    filters={@enabled_filters}
                    filter_values={@filter_values}
                    active_filters={@active_filters}
                    categories={@categories}
                    current_category={nil}
                    current_language={@current_language}
                    category_icon_mode={@category_icon_mode}
                    category_name_wrap={@category_name_wrap}
                    filter_qs={@filter_qs}
                  />
                </div>
              </div>
            </aside>
          <% end %>

          <div class={if @authenticated, do: "lg:col-span-4", else: "lg:col-span-3"}>
            <%!-- Category Grid (controlled by setting) --%>
            <%= if @show_categories_grid && @categories != [] do %>
              <div class="mb-8">
                <h2 class="text-2xl font-bold mb-4">Categories</h2>
                <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
                  <%= for cat <- @categories do %>
                    <.link
                      navigate={Shop.category_url(cat, @current_language) <> @filter_qs}
                      class="card bg-base-100 shadow-md hover:shadow-lg transition-all hover:-translate-y-1"
                    >
                      <figure class="h-28 bg-base-200">
                        <% cat_image = category_image(cat) %>
                        <%= if cat_image do %>
                          <img
                            src={cat_image}
                            alt={Translations.get(cat, :name, @current_language)}
                            class="w-full h-full object-cover"
                          />
                        <% else %>
                          <div class="w-full h-full flex items-center justify-center">
                            <.icon name="hero-folder" class="w-10 h-10 opacity-30" />
                          </div>
                        <% end %>
                      </figure>
                      <div class="card-body p-3 text-center">
                        <h3 class="text-sm font-semibold line-clamp-2">
                          {Translations.get(cat, :name, @current_language)}
                        </h3>
                      </div>
                    </.link>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%!-- Products Section --%>
            <div class="flex items-center justify-between mb-6">
              <h2 class="text-2xl font-bold">Products</h2>
              <.link navigate={Shop.cart_url(@current_language)} class="btn btn-outline btn-sm gap-2">
                <.icon name="hero-shopping-cart" class="w-4 h-4" /> View Cart
              </.link>
            </div>

            <%= if @products == [] do %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body text-center py-16">
                  <.icon name="hero-cube" class="w-16 h-16 mx-auto mb-4 opacity-30" />
                  <h3 class="text-xl font-medium text-base-content/60">No products available</h3>
                  <p class="text-base-content/50">
                    <%= if FilterHelpers.has_active_filters?(@active_filters) do %>
                      No products match your filters.
                      <button phx-click="clear_filters" class="link link-primary">
                        Clear filters
                      </button>
                    <% else %>
                      Check back soon for new arrivals
                    <% end %>
                  </p>
                </div>
              </div>
            <% else %>
              <div class={[
                "grid gap-6",
                if(@authenticated,
                  do: "grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4",
                  else: "grid-cols-1 sm:grid-cols-2 xl:grid-cols-3"
                )
              ]}>
                <%= for product <- @products do %>
                  <.product_card
                    product={product}
                    currency={@currency}
                    language={@current_language}
                    filter_qs={@filter_qs}
                  />
                <% end %>
              </div>

              <.shop_pagination
                page={@page}
                total_pages={@total_pages}
                total_products={@total_products}
                per_page={@per_page}
                current_language={@current_language}
                active_filters={@active_filters}
                enabled_filters={@enabled_filters}
              />
            <% end %>
          </div>
        </div>
      </div>
    </ShopLayouts.shop_layout>
    """
  end

  defp shop_sidebar(assigns) do
    ~H"""
    <CatalogSidebar.catalog_sidebar
      filters={@enabled_filters}
      filter_values={@filter_values}
      active_filters={@active_filters}
      categories={@categories}
      current_category={nil}
      current_language={@current_language}
      category_icon_mode={@category_icon_mode}
      category_name_wrap={@category_name_wrap}
      filter_qs={@filter_qs}
    />
    """
  end

  attr :product, :map, required: true
  attr :currency, :any, required: true
  attr :language, :string, default: "en"
  attr :filter_qs, :string, default: ""

  defp product_card(assigns) do
    # Get localized values
    assigns =
      assigns
      |> assign(:product_title, Translations.get(assigns.product, :title, assigns.language))
      |> assign(:product_url, Shop.product_url(assigns.product, assigns.language))
      |> assign(
        :category_name,
        if(assigns.product.category,
          do: Translations.get(assigns.product.category, :name, assigns.language),
          else: nil
        )
      )

    ~H"""
    <.link
      navigate={@product_url <> @filter_qs}
      class="card bg-base-100 shadow-md hover:shadow-xl transition-all hover:-translate-y-1"
    >
      <figure class="h-48 bg-base-200">
        <%= if Helpers.first_image(@product) do %>
          <img
            src={Helpers.first_image(@product)}
            alt={@product_title}
            class="w-full h-full object-cover"
          />
        <% else %>
          <div class="w-full h-full flex items-center justify-center">
            <.icon name="hero-cube" class="w-16 h-16 opacity-30" />
          </div>
        <% end %>
      </figure>
      <div class="card-body p-4">
        <h3 class="card-title text-base line-clamp-2">{@product_title}</h3>

        <div class="flex items-center gap-2">
          <span class="text-lg font-bold text-primary">
            {Helpers.format_price(@product.price, @currency)}
          </span>
          <%= if @product.compare_at_price && Decimal.compare(@product.compare_at_price, @product.price) == :gt do %>
            <span class="text-sm text-base-content/40 line-through">
              {Helpers.format_price(@product.compare_at_price, @currency)}
            </span>
          <% end %>
        </div>

        <%= if @category_name do %>
          <div class="mt-2">
            <span class="badge badge-ghost badge-sm">{@category_name}</span>
          </div>
        <% end %>
      </div>
    </.link>
    """
  end

  defp category_image(category) do
    Shop.Category.get_image_url(category, size: "small")
  end

  # Pagination UI component
  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :total_products, :integer, required: true
  attr :per_page, :integer, required: true
  attr :current_language, :string, required: true
  attr :active_filters, :map, default: %{}
  attr :enabled_filters, :list, default: []

  defp shop_pagination(assigns) do
    remaining = assigns.total_products - assigns.page * assigns.per_page
    base_path = Shop.catalog_url(assigns.current_language)

    assigns =
      assigns
      |> assign(:remaining, max(0, remaining))
      |> assign(:has_more, assigns.page < assigns.total_pages)
      |> assign(:base_path, base_path)

    ~H"""
    <%= if @total_pages > 1 do %>
      <div class="mt-8 space-y-4">
        <%!-- Load More Button --%>
        <%= if @has_more do %>
          <div class="flex justify-center">
            <button phx-click="load_more" class="btn btn-primary btn-lg gap-2">
              <.icon name="hero-arrow-down" class="w-5 h-5" /> Show More
              <span class="badge badge-ghost">{@remaining}</span>
            </button>
          </div>
        <% end %>

        <%!-- Page Links for SEO and direct access --%>
        <nav class="flex flex-wrap justify-center gap-2 text-sm">
          <%= for p <- 1..@total_pages do %>
            <.link
              patch={
                FilterHelpers.build_filter_url(@base_path, @active_filters, @enabled_filters, page: p)
              }
              class={[
                "px-3 py-1 rounded transition-colors",
                if(p <= @page,
                  do: "bg-primary text-primary-content",
                  else: "bg-base-200 hover:bg-base-300 text-base-content/70"
                )
              ]}
            >
              {p}
            </.link>
          <% end %>
        </nav>

        <%!-- Status text --%>
        <p class="text-center text-sm text-base-content/50">
          Showing {min(@page * @per_page, @total_products)} of {@total_products} products
        </p>
      </div>
    <% end %>
    """
  end

  # Build catalog path with filter params and optional page
  defp build_filter_path(assigns, active_filters, opts \\ []) do
    base_path = Shop.catalog_url(assigns.current_language)
    page = Keyword.get(opts, :page)

    FilterHelpers.build_filter_url(base_path, active_filters, assigns.enabled_filters, page: page)
  end
end
